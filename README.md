# TalkIA — Walkie-Talkie Digital

App Android tipo walkie-talkie. Presiona y mantén el botón para hablar; todos los dispositivos en el mismo canal escuchan al instante, incluso con la app en segundo plano.

## Arquitectura

```
Flutter App  ←—WebSocket—→  FastAPI Server (Docker)
                                  ↑ retransmite audio PCM a todos en la sala
OTA Server (nginx:3021)  ←— scripts/release.sh
```

## Levantar el servidor WebSocket

```bash
cd server/
docker compose up -d --build
```

El servidor queda accesible en la red interna. Configurar Nginx Proxy Manager para exponer `talkia.laravas.com → talkia-server:8081`.

## Levantar el servidor OTA

```bash
cd ota/
docker compose up -d
```

Sirve APKs en el puerto 3021. Nginx Proxy Manager: `ota.laravas.com/talkia-*`.

## Build y deploy

```bash
# Primera vez (sin bump de versión)
bash scripts/release.sh

# Nuevas versiones
bash scripts/release.sh --bump "Descripción del cambio"

# Rollback
bash scripts/rollback.sh
```

## Keystore (firma de APK)

Crear `android/key.properties`:
```
STORE_FILE=/ruta/al/keystore.jks
KEYSTORE_PASSWORD=tu_password
KEY_ALIAS=tu_alias
KEY_PASSWORD=tu_password
```

## Versioning

`pubspec.yaml` → `version: 1.0.N+N`

El script `release.sh --bump` incrementa automáticamente el build number.
