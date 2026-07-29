"""
TalkIA — WebSocket relay server
Soporta codec Opus (app Android) y PCM (web/iOS).
Transcoding bidireccional: Opus→PCM para web, PCM→Opus para Android.

Presencia: la identidad es `client_id` (estable por instalación), no el nombre.
Cada cambio de roster viaja como foto completa; ver
wiki/projects/talkia/decisions/protocolo-presencia.md
"""

import asyncio
import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
import opuslib

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("talkia")

ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "talkia2026")
MIN_BUILD = int(os.environ.get("MIN_BUILD", "0"))
OPEN_ROOMS = {"76961"}

SPEAKER_TIMEOUT_SECONDS = 30

# El cliente pinguea cada 10s. 45s tolera 3 pings perdidos + margen para que
# Doze/App Standby difieran el timer en Android.
CLIENT_TIMEOUT_SECONDS = int(os.environ.get("CLIENT_TIMEOUT_SECONDS", "45"))
REAPER_INTERVAL_SECONDS = int(os.environ.get("REAPER_INTERVAL_SECONDS", "10"))
CLOSE_TIMEOUT_SECONDS = 2

# Parámetros Opus — deben coincidir con el cliente Android
OPUS_SAMPLE_RATE = 16000
OPUS_CHANNELS = 1
OPUS_FRAME_SAMPLES = 320        # 20ms a 16kHz
OPUS_FRAME_BYTES = OPUS_FRAME_SAMPLES * 2  # s16le: 2 bytes por muestra


@dataclass
class Session:
    ws: WebSocket
    client_id: str
    name: str
    codec: str
    build: int
    room: str
    last_seen: float
    # Elegibilidad para el reaper por tipo de cliente, no por haber pingueado ya:
    # exigir el primer ping dejaba fantasmas inmortales si la conexión moría en
    # la ventana de 10s antes de que llegara. codec == "opus" es la app Android,
    # que siempre pinguea; el único exento real es un navegador con index.html
    # cacheado viejo (pcm sin client_id) — ver bugs/usuarios-fantasma.md.
    heartbeat: bool = False
    gone: bool = False
    decoder: opuslib.Decoder | None = None
    encoder: opuslib.Encoder | None = None
    buffer: bytearray | None = None


# room_code -> {client_id: Session}  (el orden de inserción define el orden del roster)
rooms: dict[str, dict[str, Session]] = {}

# room_code -> Session del hablante activo
room_speaker: dict[str, Session | None] = {}

# room_code -> Task del timeout del hablante activo
room_speaker_timeout: dict[str, asyncio.Task] = {}


@asynccontextmanager
async def lifespan(_app: FastAPI):
    reaper = asyncio.create_task(_reaper_loop())
    try:
        yield
    finally:
        reaper.cancel()


app = FastAPI(title="TalkIA Server", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def _sessions(room: str) -> list[Session]:
    return list(rooms.get(room, {}).values())


def roster_payload(room: str) -> dict:
    sessions = _sessions(room)
    return {
        "count": len(sessions),
        # `users` (strings) es el formato legacy: lo consumen index.html y los APK build<=28
        "users": [s.name for s in sessions],
        "roster": [
            {"id": s.client_id, "name": s.name, "build": s.build}
            for s in sessions
        ],
    }


def _cancel_speaker_timeout(room: str):
    task = room_speaker_timeout.pop(room, None)
    if task and not task.done():
        task.cancel()


async def _force_release_speaker(room: str, session: Session):
    await asyncio.sleep(SPEAKER_TIMEOUT_SECONDS)
    if room_speaker.get(room) is session:
        room_speaker[room] = None
        room_speaker_timeout.pop(room, None)
        log.warning(f"[{room}] PTT timeout — forzando ptt_end de '{session.name}'")
        await broadcast_json(room, {"type": "ptt_end"})


async def _close_quietly(ws: WebSocket):
    try:
        await asyncio.wait_for(ws.close(), timeout=CLOSE_TIMEOUT_SECONDS)
    except Exception:
        pass


def _gc_room(room: str):
    if not rooms.get(room):
        rooms.pop(room, None)
        room_speaker.pop(room, None)
        _cancel_speaker_timeout(room)


async def _drop(session: Session, reason: str, announce: bool = True, close: bool = True):
    """Saca una sesión de la sala. Idempotente."""
    if session.gone:
        return
    session.gone = True

    room = session.room
    bucket = rooms.get(room)
    was_attached = bucket is not None and bucket.get(session.client_id) is session
    if was_attached:
        del bucket[session.client_id]

    session.decoder = None
    session.encoder = None
    session.buffer = None

    freed_mic = room_speaker.get(room) is session
    if freed_mic:
        room_speaker[room] = None
        _cancel_speaker_timeout(room)

    if close:
        await _close_quietly(session.ws)

    if not was_attached:
        _gc_room(room)
        return

    remaining = len(rooms.get(room, {}))
    log.info(f"[{room}] '{session.name}' ({session.client_id}) fuera — {reason}. Restantes: {remaining}")

    if freed_mic:
        await broadcast_json(room, {"type": "ptt_end"})
    if announce and remaining > 0:
        await broadcast_json(room, {
            "type": "user_left",
            "name": session.name,
            "id": session.client_id,
            **roster_payload(room),
        })

    _gc_room(room)


async def broadcast_json(room: str, data: dict, exclude: Session | None = None):
    msg = json.dumps(data)
    dead: list[Session] = []
    for session in _sessions(room):
        if session is exclude:
            continue
        try:
            await session.ws.send_text(msg)
        except Exception:
            dead.append(session)
    for session in dead:
        await _drop(session, reason="envío falló")


async def broadcast_bytes(room: str, chunk: bytes, sender: Session):
    # Preparar Opus frames si el emisor es PCM (para receptores Android)
    opus_frames: list[bytes] = []
    if sender.codec == "pcm" and sender.buffer is not None and sender.encoder is not None:
        buf = sender.buffer
        buf.extend(chunk)
        while len(buf) >= OPUS_FRAME_BYTES:
            frame = bytes(buf[:OPUS_FRAME_BYTES])
            del buf[:OPUS_FRAME_BYTES]
            try:
                opus_frames.append(sender.encoder.encode(frame, OPUS_FRAME_SAMPLES))
            except Exception as e:
                log.error(f"PCM→Opus encode error: {e}")

    # Preparar PCM si el emisor es Opus (para receptores web)
    pcm_transcoded: bytes | None = None
    if sender.codec == "opus" and sender.decoder is not None:
        try:
            pcm_transcoded = sender.decoder.decode(chunk, OPUS_FRAME_SAMPLES)
        except Exception as e:
            log.error(f"Opus→PCM decode error: {e}")

    dead: list[Session] = []
    for session in _sessions(room):
        if session is sender:
            continue
        try:
            if session.codec == sender.codec:
                await session.ws.send_bytes(chunk)
            elif sender.codec == "opus" and session.codec == "pcm":
                if pcm_transcoded:
                    await session.ws.send_bytes(pcm_transcoded)
            elif sender.codec == "pcm" and session.codec == "opus":
                for frame in opus_frames:
                    await session.ws.send_bytes(frame)
        except Exception:
            dead.append(session)

    for session in dead:
        await _drop(session, reason="envío de audio falló")


async def _reaper_loop():
    while True:
        await asyncio.sleep(REAPER_INTERVAL_SECONDS)
        try:
            now = time.monotonic()
            for room in list(rooms.keys()):
                for session in _sessions(room):
                    if not session.heartbeat:
                        continue
                    idle = now - session.last_seen
                    if idle > CLIENT_TIMEOUT_SECONDS:
                        log.warning(
                            f"[{room}] '{session.name}' sin señales hace {idle:.0f}s — expulsado (conexión fantasma)"
                        )
                        await _drop(session, reason=f"sin ping hace {idle:.0f}s")
        except Exception as e:
            log.error(f"Reaper error: {e}")


@app.get("/")
async def index():
    return FileResponse(os.path.join(os.path.dirname(__file__), "static", "index.html"))


@app.get("/health")
async def health():
    now = time.monotonic()
    return {
        "status": "ok",
        "client_timeout": CLIENT_TIMEOUT_SECONDS,
        "rooms": {
            room: [
                {
                    "id": s.client_id,
                    "name": s.name,
                    "build": s.build,
                    "codec": s.codec,
                    "heartbeat": s.heartbeat,
                    "idle": round(now - s.last_seen, 1),
                }
                for s in sessions.values()
            ]
            for room, sessions in rooms.items()
            if sessions
        },
    }


@app.websocket("/ws/{room_code}")
async def websocket_endpoint(
    ws: WebSocket,
    room_code: str,
    password: str = Query(default=""),
    name: str = Query(default="Usuario"),
    codec: str = Query(default="pcm"),
    build: int = Query(default=0),
    client_id: str = Query(default=""),
):
    room_code = room_code.upper().strip()
    display_name = name.strip()[:32] or "Usuario"
    codec_val = codec if codec in ("opus", "pcm") else "pcm"
    stable_id = client_id.strip()[:64]

    await ws.accept()

    if MIN_BUILD > 0 and build < MIN_BUILD:
        log.warning(f"[{room_code}] '{display_name}' rechazado — build {build} < min {MIN_BUILD}")
        await ws.send_text(json.dumps({"type": "error", "code": "update_required"}))
        await ws.close()
        return

    if not rooms.get(room_code) and room_code not in OPEN_ROOMS:
        if password != ADMIN_PASSWORD:
            log.warning(f"[{room_code}] Creación rechazada — contraseña incorrecta")
            await ws.send_text(json.dumps({"type": "error", "code": "admin_password_required"}))
            await ws.close()
            return
        log.info(f"[{room_code}] Sala creada por admin")

    # Sin client_id (cliente antiguo) cada conexión es una identidad distinta:
    # se conserva el comportamiento previo en vez de fusionar usuarios por nombre.
    cid = stable_id or f"anon-{uuid.uuid4().hex[:12]}"

    previous = rooms.get(room_code, {}).get(cid)
    if previous is not None:
        log.info(f"[{room_code}] '{display_name}' reconectó con client_id {cid} — reemplazando sesión anterior")
        await _drop(previous, reason="sesión reemplazada", announce=False)

    # Reapable desde el connect si el cliente es de un tipo que pinguea.
    reapable = codec_val == "opus" or bool(stable_id)

    session = Session(
        ws=ws,
        client_id=cid,
        name=display_name,
        codec=codec_val,
        build=build,
        room=room_code,
        last_seen=time.monotonic(),
        heartbeat=reapable,
    )

    if not reapable:
        log.info(
            f"[{room_code}] '{display_name}' ({codec_val}, sin client_id) conectado exento del reaper — "
            f"navegador con index.html cacheado viejo, no pinguea"
        )

    if codec_val == "opus":
        session.decoder = opuslib.Decoder(OPUS_SAMPLE_RATE, OPUS_CHANNELS)
    else:
        session.encoder = opuslib.Encoder(OPUS_SAMPLE_RATE, OPUS_CHANNELS, "voip")
        session.buffer = bytearray()

    rooms.setdefault(room_code, {})[cid] = session

    log.info(f"[{room_code}] '{display_name}' ({codec_val}, build {build}) conectado. Total: {len(rooms[room_code])}")

    await broadcast_json(room_code, {
        "type": "user_joined",
        "name": display_name,
        "id": cid,
        **roster_payload(room_code),
    }, exclude=session)

    await ws.send_text(json.dumps({
        "type": "welcome",
        "room": room_code,
        "you": cid,
        **roster_payload(room_code),
    }))

    try:
        while True:
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
            session.last_seen = time.monotonic()

            if "bytes" in message and message["bytes"]:
                chunk = message["bytes"]
                log.info(f"[{room_code}] audio {len(chunk)}b ({codec_val}) de '{display_name}'")
                await broadcast_bytes(room_code, chunk, sender=session)

            elif "text" in message and message["text"]:
                try:
                    ctrl = json.loads(message["text"])
                    msg_type = ctrl.get("type", "")

                    if msg_type == "ptt_start":
                        current = room_speaker.get(room_code)
                        if current is not None and current is not session:
                            await ws.send_text(json.dumps({
                                "type": "channel_busy",
                                "name": current.name,
                            }))
                            log.info(f"[{room_code}] Canal ocupado — '{display_name}' rechazado (habla '{current.name}')")
                        else:
                            room_speaker[room_code] = session
                            if session.buffer is not None:
                                session.buffer.clear()
                            _cancel_speaker_timeout(room_code)
                            room_speaker_timeout[room_code] = asyncio.create_task(
                                _force_release_speaker(room_code, session)
                            )
                            await broadcast_json(room_code, {
                                "type": "ptt_start",
                                "name": display_name,
                                "id": cid,
                            }, exclude=session)
                            log.info(f"[{room_code}] PTT start — '{display_name}'")

                    elif msg_type == "ptt_end":
                        if room_speaker.get(room_code) is session:
                            room_speaker[room_code] = None
                            _cancel_speaker_timeout(room_code)
                        if session.buffer is not None:
                            session.buffer.clear()
                        await broadcast_json(room_code, {"type": "ptt_end"}, exclude=session)
                        log.info(f"[{room_code}] PTT end — '{display_name}'")

                    elif msg_type == "ping":
                        session.heartbeat = True
                        await ws.send_text(json.dumps({"type": "pong"}))

                except json.JSONDecodeError:
                    pass

    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.error(f"[{room_code}] Error: {e}")
    finally:
        await _drop(session, reason="desconectado")
