#!/usr/bin/env bash
# Fetch the WebAssembly sharp packages that the Linux Desktop build needs.
#
# pnpm never resolves them for a linux-x64 install (they are optional deps for other
# ABIs), so they are vendored into apps/desktop/vendor/sharp-wasm32/ and copied into the
# prepared runtime by prepare-dsh.ts's `runtime:materialize-linux-shims` step.
#
# Reason: sharp's native binary segfaults under Electron on Linux (electron#46323).
set -euo pipefail

SHARP_VERSION="${SHARP_VERSION:-0.35.5}"
EMNAPI_VERSION="${EMNAPI_VERSION:-1.11.3}"
TSLIB_VERSION="${TSLIB_VERSION:-2.8.1}"

REPO="${1:-$HOME/build/deepseek-harness}"
DEST="$REPO/apps/desktop/vendor/sharp-wasm32"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # <url> <outfile>
  # The registry 302s to cdn.npmmirror.com; without -L you get a 101-byte "Redirecting to ..." file.
  curl -fsSL --retry 3 -o "$2" "$1"
  tar tzf "$2" >/dev/null
}

echo "fetching @img/sharp-wasm32@$SHARP_VERSION"
fetch "https://registry.npmmirror.com/@img/sharp-wasm32/-/sharp-wasm32-$SHARP_VERSION.tgz" "$WORK/sharp.tgz"
echo "fetching @emnapi/runtime@$EMNAPI_VERSION"
fetch "https://registry.npmmirror.com/@emnapi/runtime/-/runtime-$EMNAPI_VERSION.tgz" "$WORK/emnapi.tgz"
echo "fetching tslib@$TSLIB_VERSION"
fetch "https://registry.npmmirror.com/tslib/-/tslib-$TSLIB_VERSION.tgz" "$WORK/tslib.tgz"

rm -rf "$DEST"
mkdir -p "$DEST/@img" "$DEST/@emnapi"
tar xzf "$WORK/sharp.tgz"  -C "$WORK" --one-top-level=sharp
tar xzf "$WORK/emnapi.tgz" -C "$WORK" --one-top-level=emnapi
tar xzf "$WORK/tslib.tgz"  -C "$WORK" --one-top-level=tslib

cp -a "$WORK/sharp/package"  "$DEST/@img/sharp-wasm32"
cp -a "$WORK/emnapi/package" "$DEST/@emnapi/runtime"
cp -a "$WORK/tslib/package"  "$DEST/tslib"

echo
echo "vendored into $DEST:"
du -sh "$DEST"
find "$DEST" -maxdepth 2 -name package.json -exec sh -c \
  'printf "  %-40s %s\n" "$(basename "$(dirname "$1")")" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[\"version\"])" "$1")"' _ {} \;
