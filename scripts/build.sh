#!/usr/bin/env bash
# Build the DeepSeek Harness Desktop Linux package with the official pipeline.
#
#   ./scripts/build.sh [source-dir]
#
# Runs upstream's own `pnpm run package:desktop:dir`, which builds, prepares the
# runtime, runs electron-builder and then runs BOTH smoke gates. It must exit 0.
#
# Output: <src>/apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$HOME/build/deepseek-harness}"

[ -d "$SRC/apps/desktop" ] || { echo "error: $SRC is not a deepseek-harness tree" >&2; exit 1; }
cd "$SRC"

# --- toolchain -----------------------------------------------------------------
# Arch's nodejs has no corepack; install pnpm to a private prefix if you need to:
#   npm i -g --prefix ~/.local/share/pnpm-self pnpm@11.7.0
export PATH="$HOME/.local/share/pnpm-self/bin:$PATH"
command -v pnpm >/dev/null || { echo "error: pnpm not found on PATH" >&2; exit 1; }

# npmmirror is CN-local and faster DIRECT than through a local HTTP proxy, so make
# sure no proxy is exported for the package manager. (GitHub/curl still needs the
# proxy on a restricted network — see docs/pitfalls.md.)
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

export NPM_CONFIG_REGISTRY="${NPM_CONFIG_REGISTRY:-https://registry.npmmirror.com}"
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://registry.npmmirror.com/-/binary/electron/}"
export ELECTRON_BUILDER_BINARIES_MIRROR="${ELECTRON_BUILDER_BINARIES_MIRROR:-https://registry.npmmirror.com/-/binary/electron-builder-binaries/}"
export ELECTRON_CUSTOM_DIR='{{ version }}'

# --- install -------------------------------------------------------------------
echo "==> pnpm install"
pnpm install

echo "==> pnpm run build"
pnpm run build

# electron's postinstall does not run under the workspace install, so fetch the
# binary by hand. It reuses ~/.cache/electron when present.
if [ ! -x "$(echo node_modules/.pnpm/electron@*/node_modules/electron/dist/electron 2>/dev/null | awk '{print $1}')" ]; then
  echo "==> fetching electron binary"
  ( cd "$(echo node_modules/.pnpm/electron@*/node_modules/electron | awk '{print $1}')" && node install.js )
fi
echo -n "    electron version: "
"$(echo node_modules/.pnpm/electron@*/node_modules/electron/dist/electron | awk '{print $1}')" --version || true

# --- package -------------------------------------------------------------------
echo "==> pnpm run package:desktop:dir  (build:official + prepare:runtime + prepare:dsh"
echo "                                   + electron-builder + both smokes)"
pnpm run package:desktop:dir

OUT="apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked"
[ -x "$OUT/deepseek-harness" ] || { echo "error: no packaged app at $OUT" >&2; exit 1; }

echo
echo "==> packaged: $SRC/$OUT"
echo
echo "Next:"
echo "  DSH_DESKTOP_PAYLOAD=$SRC/$OUT bash $HERE/install/install.sh"
