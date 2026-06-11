#!/bin/bash
# release.sh — Compilar y desplegar TalkIA al servidor OTA
# Ejecutar desde la raíz del proyecto:
#   bash scripts/release.sh
#   bash scripts/release.sh --bump              # incrementa build number
#   bash scripts/release.sh --bump "Changelog"  # con mensaje de cambio

set -euo pipefail

export ANDROID_HOME=/opt/android-sdk
export PATH="$PATH:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/flutter/bin"

OTA_RELEASES="/root/apps/talkia/ota/releases"
APK_LOCAL="build/app/outputs/flutter-apk/app-release.apk"
APK_NAME="talkia-latest.apk"
PUBSPEC="pubspec.yaml"
CONSTANTS="lib/core/constants.dart"
WIKI_DIR="/root/apps/wiki"

# ── Bump build number ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "--bump" ]]; then
  CURRENT_BUILD=$(grep "^version:" "$PUBSPEC" | grep -oP '\+\K[0-9]+')
  NEW_BUILD=$((CURRENT_BUILD + 1))
  MAJOR_MINOR=$(grep "^version:" "$PUBSPEC" | grep -oP '[\d]+\.[\d]+(?=\.)')
  sed -i "s/^version: .*/version: ${MAJOR_MINOR}.${NEW_BUILD}+${NEW_BUILD}/" "$PUBSPEC"
  sed -i "s/const int kAppBuild = [0-9]\+;/const int kAppBuild = ${NEW_BUILD};/" "$CONSTANTS"
  echo "▶ Build bump: $CURRENT_BUILD → $NEW_BUILD"
fi

# ── Leer versión actual ────────────────────────────────────────────────────────
VERSION=$(grep "^version:" "$PUBSPEC" | grep -oP '[\d.]+(?=\+)')
BUILD=$(grep "^version:" "$PUBSPEC" | grep -oP '\+\K[0-9]+')
echo "▶ Versión: $VERSION+$BUILD"

# ── Verificar memoria antes de compilar ───────────────────────────────────────
# Gradle necesita ~2GB de heap. Si el servidor está bajo carga, esperar.
esperar_memoria_disponible() {
    local MIN_RAM_MB=3000 MAX_SWAP_MB=1500 POLL_SECS=30 TIMEOUT_SECS=600 elapsed=0
    while true; do
        local ram swap
        ram=$(free -m | awk 'NR==2{print $7}')
        swap=$(free -m | awk 'NR==3{print $3}')
        if [[ $ram -ge $MIN_RAM_MB && $swap -le $MAX_SWAP_MB ]]; then
            echo "▶ Memoria OK — RAM disponible: ${ram}MB, swap: ${swap}MB"
            return 0
        fi
        echo "⏳ Servidor bajo carga (RAM: ${ram}MB libre, swap: ${swap}MB usado). Esperando ${POLL_SECS}s..."
        sleep $POLL_SECS
        elapsed=$((elapsed + POLL_SECS))
        if [[ $elapsed -ge $TIMEOUT_SECS ]]; then
            echo "⚠️  Timeout tras $((TIMEOUT_SECS/60)) min. Compilando de todas formas."
            return 0
        fi
    done
}
esperar_memoria_disponible

# ── Build APK release ──────────────────────────────────────────────────────────
echo "▶ Compilando APK release (puede tardar 3-5 min)..."
flutter --suppress-analytics build apk --release 2>&1 | grep -v "Woah\|root\|superuser"
echo "✅ APK generado"

# ── Copiar APK al servidor OTA ────────────────────────────────────────────────
echo "▶ Publicando en OTA..."
if [[ -f "$OTA_RELEASES/$APK_NAME" ]]; then
  cp "$OTA_RELEASES/$APK_NAME" "$OTA_RELEASES/talkia-prev.apk"
  cp "$OTA_RELEASES/version.json" "$OTA_RELEASES/version-prev.json"
fi
cp "$APK_LOCAL" "$OTA_RELEASES/$APK_NAME"

# ── Actualizar version.json ───────────────────────────────────────────────────
CHANGELOG="${2:-Versión $VERSION}"
cat > "$OTA_RELEASES/version.json" <<EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "min_build": $BUILD,
  "url": "https://ota.laravas.com/talkia-latest.apk?v=$BUILD",
  "changelog": "$CHANGELOG"
}
EOF

echo ""
echo "🚀 Deploy completo:"
echo "   Versión:  $VERSION (build $BUILD)"
echo "   APK:      https://ota.laravas.com/talkia/$APK_NAME"
echo "   Tamaño:   $(du -sh "$OTA_RELEASES/$APK_NAME" | cut -f1)"
echo "   Changelog: $CHANGELOG"

# ── Rebuild servidor web (Docker) ────────────────────────────────────────────
echo ""
echo "▶ Rebuildeando servidor web..."
docker compose -f server/docker-compose.yml up -d --build 2>&1 | grep -E "Built|Started|Error" || true
echo "✅ Servidor web actualizado"

# ── Git commit y push ─────────────────────────────────────────────────────────
echo ""
echo "▶ Commiteando cambios..."
git add -A
git reset -- "*.apk" talkia-latest.apk 2>/dev/null || true
git commit -m "release: v${VERSION} (build ${BUILD}) — ${CHANGELOG}"
git push origin main
echo "✅ Git actualizado → v${VERSION} (build ${BUILD})"

# ── Actualizar wiki ───────────────────────────────────────────────────────────
echo ""
echo "▶ Actualizando wiki..."
TODAY=$(date '+%Y-%m-%d')
cat >> "$WIKI_DIR/log.md" <<EOF

## [$TODAY] update | TalkIA v${VERSION} (build ${BUILD}) — ${CHANGELOG}
- APK publicado en OTA: https://ota.laravas.com/talkia/talkia-latest.apk
- Tamaño: $(du -sh "$OTA_RELEASES/$APK_NAME" | cut -f1)
EOF
bash "$WIKI_DIR/wiki-push.sh" "update: TalkIA v${VERSION} — ${CHANGELOG}" 2>/dev/null || echo "⚠ Wiki push falló (continúa igualmente)."

echo ""
echo "✅ Wiki actualizada"
