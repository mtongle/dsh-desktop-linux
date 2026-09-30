#!/usr/bin/env bash
# Assert that a packaged linux-unpacked payload really carries the Linux fixes.
#
#   ./scripts/verify-payload.sh [payload-dir]
#
# Default: ~/build/deepseek-harness/apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked
#
# This is the cheap, structural counterpart to the pipeline's own smoke gates: it
# reads app.asar's header directly (no @electron/asar, no network) and fails loudly
# if the wasm sharp fallback is missing or the segfaulting native binding is back.
set -euo pipefail

DEFAULT_PAYLOAD="$HOME/build/deepseek-harness/apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked"
PAYLOAD="${1:-${DSH_DESKTOP_PAYLOAD:-$DEFAULT_PAYLOAD}}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$PAYLOAD" ] || fail "payload directory not found: $PAYLOAD"
[ -x "$PAYLOAD/deepseek-harness" ] || fail "no executable at $PAYLOAD/deepseek-harness"
[ -f "$PAYLOAD/resources/app.asar" ] || fail "no resources/app.asar"

echo "payload:  $PAYLOAD"
echo "size:     $(du -sh "$PAYLOAD" | cut -f1)"
echo "electron: $(cat "$PAYLOAD/version" 2>/dev/null || echo '(no version file)')"
echo "sha256:   $(sha256sum "$PAYLOAD/resources/app.asar" | cut -d' ' -f1)  app.asar"
echo

ENTRIES="$(python3 - "$PAYLOAD/resources/app.asar" <<'PY'
import json, struct, sys

path = sys.argv[1]
with open(path, "rb") as fh:
    head = fh.read(16)
    # asar header is a Chromium Pickle:
    #   [0:4]  uint32 = 4 (size of the size field itself)
    #   [4:8]  uint32 = payload size (json size + 4)
    #   [8:12] uint32 = string size (json length + 4)
    #   [12:16] uint32 = json length
    #   [16:…] the JSON directory, padded to a 4-byte boundary
    json_size = struct.unpack("<I", head[12:16])[0]
    raw = fh.read(json_size)
    header = json.loads(raw.decode("utf-8"))

out = []


def walk(node, prefix):
    for name, child in node.get("files", {}).items():
        full = f"{prefix}/{name}"
        if "files" in child:
            walk(child, full)
        else:
            out.append(full)


walk(header, "")
print("\n".join(out))
PY
)"

check_present() { # <needle> <human description>
  if ! grep -q -- "$1" <<<"$ENTRIES"; then
    fail "$2 missing from app.asar (looked for '$1')"
  fi
  echo "  ok   $2"
}

check_absent() { # <needle> <human description>
  local hits
  hits="$(grep -c -- "$1" <<<"$ENTRIES" || true)"
  if [ "$hits" -ne 0 ]; then
    fail "$2 present in app.asar ($hits entries) — the native binding is back and will SIGSEGV"
  fi
  echo "  ok   $2 absent"
}

echo "app.asar sharp payload:"
check_present "@img/sharp-wasm32"                "@img/sharp-wasm32 (wasm fallback)"
check_present "@emnapi/runtime"                  "@emnapi/runtime (wasm glue)"
check_present "tslib"                            "tslib (wasm glue dep)"
check_absent  "@img/sharp-linux-x64"             "@img/sharp-linux-x64 (native, segfaults)"

echo
echo "PASS: $PAYLOAD"
