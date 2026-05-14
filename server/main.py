"""
TalkIA — WebSocket relay server
Retransmite audio PCM entre todos los clientes de una misma sala.
"""

import json
import logging
import os
from collections import defaultdict
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("talkia")

app = FastAPI(title="TalkIA Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Contraseña de admin para crear nuevas salas (no aplica a salas ya existentes)
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "talkia2026")

# Salas que siempre se pueden crear sin contraseña de admin
OPEN_ROOMS = {"76961"}

# room_code -> set of WebSocket clients
rooms: dict[str, set[WebSocket]] = defaultdict(set)

# room_code -> WebSocket of current speaker (None = free)
room_speaker: dict[str, WebSocket | None] = defaultdict(lambda: None)

# ws -> display name
client_names: dict[WebSocket, str] = {}


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


async def broadcast_bytes(room: str, data: bytes, exclude: WebSocket | None = None):
    dead = set()
    for ws in list(rooms[room]):
        if ws == exclude:
            continue
        try:
            await ws.send_bytes(data)
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
):
    room_code = room_code.upper().strip()
    display_name = name.strip()[:32] or "Usuario"

    await ws.accept()

    # Sala nueva: exigir contraseña de admin para crearla
    is_new_room = room_code not in rooms or len(rooms[room_code]) == 0
    if is_new_room and room_code not in OPEN_ROOMS:
        if password != ADMIN_PASSWORD:
            log.warning(f"[{room_code}] Creación rechazada — contraseña de admin incorrecta")
            await ws.send_text(json.dumps({"type": "error", "code": "admin_password_required"}))
            await ws.close()
            return
        log.info(f"[{room_code}] Sala creada por admin")

    rooms[room_code].add(ws)
    client_names[ws] = display_name
    user_count = len(rooms[room_code])

    log.info(f"[{room_code}] '{display_name}' conectado. Total: {user_count}")

    # Notificar a los demás que alguien entró
    await broadcast_json(room_code, {
        "type": "user_joined",
        "count": user_count,
        "name": display_name,
    }, exclude=ws)

    # Decirle al nuevo cliente cuántos hay y quiénes están
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
                await broadcast_bytes(room_code, message["bytes"], exclude=ws)

            elif "text" in message and message["text"]:
                try:
                    ctrl = json.loads(message["text"])
                    msg_type = ctrl.get("type", "")

                    if msg_type == "ptt_start":
                        room_speaker[room_code] = ws
                        await broadcast_json(room_code, {
                            "type": "ptt_start",
                            "name": display_name,
                        }, exclude=ws)
                        log.info(f"[{room_code}] PTT start — '{display_name}'")

                    elif msg_type == "ptt_end":
                        if room_speaker[room_code] == ws:
                            room_speaker[room_code] = None
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
