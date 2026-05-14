"""
TalkIA — WebSocket relay server
Soporta codec Opus (app Android) y PCM (web/iOS).
Transcoding bidireccional: Opus→PCM para web, PCM→Opus para Android.
"""

import json
import logging
import os
from collections import defaultdict
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
import opuslib

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("talkia")

app = FastAPI(title="TalkIA Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "talkia2026")
MIN_BUILD = int(os.environ.get("MIN_BUILD", "0"))
OPEN_ROOMS = {"76961"}

# Parámetros Opus — deben coincidir con el cliente Android
OPUS_SAMPLE_RATE = 16000
OPUS_CHANNELS = 1
OPUS_FRAME_SAMPLES = 320        # 20ms a 16kHz
OPUS_FRAME_BYTES = OPUS_FRAME_SAMPLES * 2  # s16le: 2 bytes por muestra

# room_code -> set of WebSocket clients
rooms: dict[str, set[WebSocket]] = defaultdict(set)

# room_code -> WebSocket del hablante activo
room_speaker: dict[str, WebSocket | None] = defaultdict(lambda: None)

# ws -> nombre visible
client_names: dict[WebSocket, str] = {}

# ws -> codec ('opus' | 'pcm')
client_codec: dict[WebSocket, str] = {}

# Para clientes Opus: decoder para transcodificar Opus→PCM hacia receptores web
opus_decoders: dict[WebSocket, opuslib.Decoder] = {}

# Para clientes PCM: encoder + buffer para transcodificar PCM→Opus hacia receptores Android
pcm_encoders: dict[WebSocket, opuslib.Encoder] = {}
pcm_buffers: dict[WebSocket, bytearray] = {}


async def broadcast_json(room: str, data: dict, exclude: WebSocket | None = None):
    msg = json.dumps(data)
    dead = set()
    for ws in list(rooms[room]):
        if ws == exclude:
            continue
        try:
            await ws.send_text(msg)
        except Exception:
            dead.add(ws)
    for ws in dead:
        rooms[room].discard(ws)


async def broadcast_bytes(
    room: str,
    chunk: bytes,
    sender_ws: WebSocket,
    exclude: WebSocket | None = None,
):
    sender_codec = client_codec.get(sender_ws, "pcm")

    # Preparar Opus frames si el emisor es PCM (para receptores Android)
    opus_frames: list[bytes] = []
    if sender_codec == "pcm":
        buf = pcm_buffers.get(sender_ws)
        enc = pcm_encoders.get(sender_ws)
        if buf is not None and enc is not None:
            buf.extend(chunk)
            while len(buf) >= OPUS_FRAME_BYTES:
                frame = bytes(buf[:OPUS_FRAME_BYTES])
                del buf[:OPUS_FRAME_BYTES]
                try:
                    opus_frames.append(enc.encode(frame, OPUS_FRAME_SAMPLES))
                except Exception as e:
                    log.error(f"PCM→Opus encode error: {e}")

    # Preparar PCM si el emisor es Opus (para receptores web)
    pcm_transcoded: bytes | None = None
    if sender_codec == "opus":
        decoder = opus_decoders.get(sender_ws)
        if decoder is not None:
            try:
                pcm_transcoded = decoder.decode(chunk, OPUS_FRAME_SAMPLES)
            except Exception as e:
                log.error(f"Opus→PCM decode error: {e}")

    dead = set()
    for ws in list(rooms[room]):
        if ws == exclude:
            continue
        receiver_codec = client_codec.get(ws, "pcm")
        try:
            if receiver_codec == sender_codec:
                await ws.send_bytes(chunk)
            elif sender_codec == "opus" and receiver_codec == "pcm":
                if pcm_transcoded:
                    await ws.send_bytes(pcm_transcoded)
            elif sender_codec == "pcm" and receiver_codec == "opus":
                for frame in opus_frames:
                    await ws.send_bytes(frame)
        except Exception:
            dead.add(ws)

    for ws in dead:
        rooms[room].discard(ws)


def room_user_names(room: str) -> list[str]:
    return [client_names[ws] for ws in rooms[room] if ws in client_names]


@app.get("/")
async def index():
    return FileResponse(os.path.join(os.path.dirname(__file__), "static", "index.html"))


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "rooms": {r: len(c) for r, c in rooms.items() if c},
    }


@app.websocket("/ws/{room_code}")
async def websocket_endpoint(
    ws: WebSocket,
    room_code: str,
    password: str = Query(default=""),
    name: str = Query(default="Usuario"),
    codec: str = Query(default="pcm"),
    build: int = Query(default=0),
):
    room_code = room_code.upper().strip()
    display_name = name.strip()[:32] or "Usuario"
    client_codec_val = codec if codec in ("opus", "pcm") else "pcm"

    await ws.accept()

    if MIN_BUILD > 0 and build < MIN_BUILD:
        log.warning(f"[{room_code}] '{display_name}' rechazado — build {build} < min {MIN_BUILD}")
        await ws.send_text(json.dumps({"type": "error", "code": "update_required"}))
        await ws.close()
        return

    is_new_room = room_code not in rooms or len(rooms[room_code]) == 0
    if is_new_room and room_code not in OPEN_ROOMS:
        if password != ADMIN_PASSWORD:
            log.warning(f"[{room_code}] Creación rechazada — contraseña incorrecta")
            await ws.send_text(json.dumps({"type": "error", "code": "admin_password_required"}))
            await ws.close()
            return
        log.info(f"[{room_code}] Sala creada por admin")

    rooms[room_code].add(ws)
    client_names[ws] = display_name
    client_codec[ws] = client_codec_val

    if client_codec_val == "opus":
        opus_decoders[ws] = opuslib.Decoder(OPUS_SAMPLE_RATE, OPUS_CHANNELS)
    else:
        pcm_encoders[ws] = opuslib.Encoder(OPUS_SAMPLE_RATE, OPUS_CHANNELS, "voip")
        pcm_buffers[ws] = bytearray()

    user_count = len(rooms[room_code])
    log.info(f"[{room_code}] '{display_name}' ({client_codec_val}) conectado. Total: {user_count}")

    await broadcast_json(room_code, {
        "type": "user_joined",
        "count": user_count,
        "name": display_name,
    }, exclude=ws)

    await ws.send_text(json.dumps({
        "type": "welcome",
        "count": user_count,
        "room": room_code,
        "users": room_user_names(room_code),
    }))

    try:
        while True:
            message = await ws.receive()

            if "bytes" in message and message["bytes"]:
                chunk = message["bytes"]
                log.info(f"[{room_code}] audio {len(chunk)}b ({client_codec_val}) de '{display_name}'")
                await broadcast_bytes(room_code, chunk, sender_ws=ws, exclude=ws)

            elif "text" in message and message["text"]:
                try:
                    ctrl = json.loads(message["text"])
                    msg_type = ctrl.get("type", "")

                    if msg_type == "ptt_start":
                        room_speaker[room_code] = ws
                        # Limpiar buffer al iniciar transmisión para evitar datos residuales
                        if ws in pcm_buffers:
                            pcm_buffers[ws].clear()
                        await broadcast_json(room_code, {
                            "type": "ptt_start",
                            "name": display_name,
                        }, exclude=ws)
                        log.info(f"[{room_code}] PTT start — '{display_name}'")

                    elif msg_type == "ptt_end":
                        if room_speaker[room_code] == ws:
                            room_speaker[room_code] = None
                        # Descartar bytes incompletos (< un frame Opus)
                        if ws in pcm_buffers:
                            pcm_buffers[ws].clear()
                        await broadcast_json(room_code, {"type": "ptt_end"}, exclude=ws)
                        log.info(f"[{room_code}] PTT end — '{display_name}'")

                    elif msg_type == "ping":
                        await ws.send_text(json.dumps({"type": "pong"}))

                except json.JSONDecodeError:
                    pass

    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.error(f"[{room_code}] Error: {e}")
    finally:
        rooms[room_code].discard(ws)
        client_names.pop(ws, None)
        client_codec.pop(ws, None)
        opus_decoders.pop(ws, None)
        pcm_encoders.pop(ws, None)
        pcm_buffers.pop(ws, None)
        if room_speaker[room_code] == ws:
            room_speaker[room_code] = None

        remaining = len(rooms[room_code])
        log.info(f"[{room_code}] '{display_name}' desconectado. Restantes: {remaining}")

        if remaining > 0:
            await broadcast_json(room_code, {
                "type": "user_left",
                "count": remaining,
                "name": display_name,
            })

        if not rooms[room_code]:
            del rooms[room_code]
            room_speaker.pop(room_code, None)
