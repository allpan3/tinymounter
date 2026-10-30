#!/bin/bash
# The checks in AGENTS.md "Before you finish" that need no judgment. Run it in the VM.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 Tools/generate-project.py
if ! git diff --quiet -- TinyMounter.xcodeproj; then
    echo "TinyMounter.xcodeproj doesn't match Tools/generate-project.py." >&2
    exit 1
fi

swift test
swift build -c release
python3 Tools/verify-benchmark.py

log=$(mktemp)
trap 'rm -f "$log"' EXIT
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounterPrototype -configuration Release \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$log"
if grep -E '\.swift:[0-9]+:[0-9]+: warning:' "$log"; then
    echo "The app build has Swift warnings." >&2
    exit 1
fi

smb_products="$PWD/.build/xcode/Build/Products/Release"
xcrun clang -std=gnu11 -Wall -Wextra -Werror -IVendor/libsmb2/include \
    Tools/check-set-info-encoding.c -L"$smb_products" -lTinyMounterSMB -Wl,-rpath,"$smb_products" \
    -o .build/check-set-info-encoding
.build/check-set-info-encoding
