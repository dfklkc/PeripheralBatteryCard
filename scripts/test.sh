#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_USRLIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ "$DEV_DIR" == *"CommandLineTools"* ]] && [[ -d "$CLT_FRAMEWORKS" ]]; then
  swift test \
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
    -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_USRLIB"
else
  swift test
fi
