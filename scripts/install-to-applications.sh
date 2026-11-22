#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT_DIR/dist/外设电量卡片.app"
DEST_APP="/Applications/外设电量卡片.app"

if [[ ! -d "$SRC_APP" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

echo "==> Installing to $DEST_APP..."
STAGE="$(mktemp -d /Applications/.peripheral-battery-install.XXXXXX)"
PREVIOUS="$STAGE/previous-app"
cleanup() {
  if [[ -e "$PREVIOUS" && ! -e "$DEST_APP" ]]; then
    if ! mv "$PREVIOUS" "$DEST_APP"; then
      echo "Previous application retained at $PREVIOUS" >&2
      return 1
    fi
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$SRC_APP" "$STAGE/staged.app"
codesign --verify --deep --strict "$STAGE/staged.app"
if [[ -e "$DEST_APP" ]]; then
  mv "$DEST_APP" "$PREVIOUS"
fi
mv "$STAGE/staged.app" "$DEST_APP"
echo "==> Installed: $DEST_APP"
