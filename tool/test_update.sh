#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE="build/linux/x64/release/bundle"
INSTALL_DIR="build/update-test/toshiba_flashair_wifi_viewer"
HELPER="toshiba_flashair_wifi_viewer_updater"

flutter build linux --release \
  --dart-define=GITHUB_REPO=diogosperandio/camera_cam
dart pub get --directory tool/updater
dart compile exe tool/updater/bin/updater.dart -o "$BUNDLE/$HELPER"
chmod 755 "$BUNDLE/$HELPER"
printf '%s\n' \
  'Instalação portátil do Toshiba FlashAir WiFi Viewer. Não apague: permite a atualização automática.' \
  > "$BUNDLE/portable.txt"

if [[ "$INSTALL_DIR" != build/update-test/* ]]; then
  echo "Destino de teste inseguro: $INSTALL_DIR" >&2
  exit 1
fi
rm -rf -- "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$BUNDLE/." "$INSTALL_DIR/"

TOSHIBA_FLASHAIR_WIFI_VIEWER_PRETEND_VERSION=0.0.0 \
  "$INSTALL_DIR/toshiba_flashair_wifi_viewer"
