#!/usr/bin/env bash
# Prepare a source tree of upstream deepseek-harness with the Linux Desktop port applied.
#
#   ./scripts/bootstrap.sh [target-dir]
#
# Default target: ~/build/deepseek-harness
# Idempotent: re-running on an already-patched tree is a no-op.
#
# The clone is shallow (--depth=1 at the pinned tag). Nothing in this workflow needs
# history — the patch applies to the tree, not to commits — and a full clone of
# deepseek-harness costs ~2.3 GB of working tree for no benefit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

UPSTREAM="${UPSTREAM:-https://github.com/deepseek-ai/deepseek-harness.git}"
# Pinned to the release the port was developed and verified against.
TAG="${TAG:-dsh-v0.2.0-rc.2}"
COMMIT="${COMMIT:-639ed015397290b3745d163aafe02ffee4aa3f84}"

DEST="${1:-$HOME/build/deepseek-harness}"
PATCH="$HERE/patches/0001-desktop-linux-port.patch"

command -v git >/dev/null || { echo "error: git not found" >&2; exit 1; }
[ -f "$PATCH" ] || { echo "error: patch not found at $PATCH" >&2; exit 1; }

if [ -d "$DEST/.git" ]; then
  echo "==> reusing existing checkout at $DEST"
else
  echo "==> cloning $UPSTREAM @ $TAG (shallow)"
  mkdir -p "$(dirname "$DEST")"
  if ! git clone --depth=1 --branch "$TAG" "$UPSTREAM" "$DEST"; then
    echo "==> tag $TAG not cloneable; falling back to a full clone" >&2
    rm -rf "$DEST"
    git clone "$UPSTREAM" "$DEST"
  fi
fi

cd "$DEST"

if ! git cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  echo "==> fetching $TAG"
  git fetch --depth=1 origin "refs/tags/$TAG:refs/tags/$TAG" || git fetch origin --tags
fi

if ! git cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  echo "error: commit $COMMIT is not available in $DEST" >&2
  echo "       (upstream may have rewritten history; update TAG/COMMIT in this script)" >&2
  exit 1
fi

if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  echo "==> checking out $TAG ($COMMIT)"
  git checkout --detach "$COMMIT"
fi

if git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "==> patch already applied; skipping"
else
  echo "==> applying $(basename "$PATCH")"
  git apply "$PATCH"
fi

echo "==> vendoring sharp WebAssembly packages"
bash "$HERE/scripts/fetch-sharp-wasm-vendor.sh" "$DEST"

echo "==> writing apps/desktop/.env.linux"
cp "$HERE/config/env.linux" "$DEST/apps/desktop/.env.linux"

cat <<EOF

Done. Patched tree: $DEST

Next:
  $HERE/scripts/build.sh "$DEST"
EOF
