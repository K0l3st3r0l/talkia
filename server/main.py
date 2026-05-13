"""
TalkIA — WebSocket relay server
Retransmite audio PCM entre todos los clientes de una misma sala.
"""

import asyncio
import json
import logging
from collections import defaultdict
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("talkia")

app = FastAPI(title="TalkIA Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# room_code -> set of WebSocket clients
rooms: dict[str, set[WebSocket]] = defaultdict(set)

# room_code -> WebSocket of current speaker (None = free)
room_speaker: dict[str, WebSocket | None] = defaultdict(lambda: None)

# room_code -> client display name
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


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "rooms": {r: len(c) for r, c in rooms.items() if c},
    }


@app.websocket("/ws/{room_code}")
async def websocket_endpoint(ws: WebSocket, room_code: str):
    room_code = room_code.upper().strip()
    await ws.accept()
    rooms[room_code].add(ws)
    client_names[ws] = "Usuario"
    user_count = len(rooms[room_code])

    log.info(f"[{room_code}] Cliente conectado. Total: {user_count}")

    # Notificar a todos que alguien entró
    await broadcast_json(room_code, {"type": "user_joined", "count": user_count}, exclude=ws)
    # Decirle al nuevo cliente cuántos hay
    await ws.send_text(json.dumps({"type": "welcome", "count": user_count, "room": room_code}))

    try:
        while True:
            message = await ws.receive()

            if "bytes" in message and message["bytes"]:
                # Audio chunk — retransmitir a todos menos al emisor
                await broadcast_bytes(room_code, message["bytes"], exclude=ws)

            elif "text" in message and message["text"]:
                try:
                    ctrl = json.loads(message["text"])
                    msg_type = ctrl.get("type", "")

                    if msg_type == "ptt_start":
                        # Si la sala está libre o es el mismo hablante, conceder el piso
                        if room_speaker[room_code] is None or room_speaker[room_code] == ws:
                            room_speaker[room_code] = ws
                            await broadcast_json(room_code, {"type": "ptt_start"}, exclude=ws)
                            log.info(f"[{room_code}] PTT start")
                        else:
                            # Sala ocupada — último gana (override)
                            room_speaker[room_code] = ws
                            await broadcast_json(room_code, {"type": "ptt_start"}, exclude=ws)

                    elif msg_type == "ptt_end":
                        if room_speaker[room_code] == ws:
                            room_speaker[room_code] = None
                        await broadcast_json(room_code, {"type": "ptt_end"}, exclude=ws)
                        log.info(f"[{room_code}] PTT end")

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
        log.info(f"[{room_code}] Cliente desconectado. Restantes: {remaining}")

        if remaining > 0:
            await broadcast_json(room_code, {"type": "user_left", "count": remaining})

        # Limpiar sala vacía
        if not rooms[room_code]:
            del rooms[room_code]
            room_speaker.pop(room_code, None)
