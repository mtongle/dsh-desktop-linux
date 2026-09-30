#!/usr/bin/env bash
# Install the locally built DeepSeek Harness Desktop (official Electron shell, linux-x64)
# into the user's ~/.local tree. No sudo required.
#
# The payload is produced by the OFFICIAL packaging pipeline
#   cd apps/desktop && pnpm run package:desktop:dir
# with (a) the Linux port patches and (b) the sharp WebAssembly fix applied, so the
# pipeline's runtime-payload smoke passes instead of being bypassed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Payload: either a linux-unpacked directory staged next to this script, or point
# DSH_DESKTOP_PAYLOAD at the pipeline output directly:
#   DSH_DESKTOP_PAYLOAD=~/build/deepseek-harness/apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked
SRC="${DSH_DESKTOP_PAYLOAD:-$HERE/linux-unpacked}"
DEST="${DSH_DESKTOP_INSTALL_DIR:-$HOME/.local/opt/deepseek-harness-desktop}"
LAUNCHER="$HOME/.local/bin/deepseek-harness-desktop"
ENTRY="$HOME/.local/share/applications/deepseek-harness.desktop"

if [ ! -x "$SRC/deepseek-harness" ]; then
  echo "error: packaged application not found at $SRC/deepseek-harness" >&2
  exit 1
fi

if [ -e "$DEST" ]; then
  BACKUP="$DEST.bak-$(date +%Y%m%d-%H%M%S)"
  echo "existing install found; moving it to $BACKUP"
  mv "$DEST" "$BACKUP"
  echo "  (roll back with: rm -rf '$DEST' && mv '$BACKUP' '$DEST')"
fi

mkdir -p "$(dirname "$DEST")" "$HOME/.local/bin" "$HOME/.local/share/applications"
cp -a "$SRC" "$DEST"

install -m 0755 "$HERE/deepseek-harness-desktop" "$LAUNCHER"

sed "s|@LAUNCHER@|$LAUNCHER|g" "$HERE/deepseek-harness.desktop.in" > "$ENTRY"
chmod 0644 "$ENTRY"

if [ -f "$DEST/resources/icon.png" ]; then
  for size in 32x32 64x64 128x128 256x256 512x512; do
    dir="$HOME/.local/share/icons/hicolor/$size/apps"
    mkdir -p "$dir"
    install -m 0644 "$DEST/resources/icon.png" "$dir/deepseek-harness.png"
  done
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo
echo "installed:  $DEST"
echo "launcher:   $LAUNCHER"
echo "entry:      $ENTRY"
echo "harness data: ${DSH_HOME:-$HOME/.dsh} (profile: profiles/desktop) — untouched by this script"
