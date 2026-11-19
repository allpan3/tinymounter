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
python3 Tools/check-performance-log.py

xcrun swiftc Prototype/App/SMBServerDiscovery.swift Tools/check-smb-discovery.swift \
    -o .build/check-smb-discovery
.build/check-smb-discovery

xcrun swiftc Prototype/Shared/ProviderDomainVersion.swift Tools/check-deletion-event.swift \
    -o .build/check-deletion-event
.build/check-deletion-event

xcrun swiftc Sources/TransferCore/*.swift Prototype/Shared/SharedContainer.swift \
    Prototype/Shared/SourceReaderProtocol.swift Prototype/Provider/CatalogItem.swift \
    Tools/check-provider-retention.swift -lsqlite3 -o .build/check-provider-retention
.build/check-provider-retention

log=$(mktemp)
trap 'rm -f "$log"' EXIT
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounter -configuration Release \
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

xcrun clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -IVendor/libsmb2/include \
    Tools/check-edit-status.c -L"$smb_products" -lTinyMounterSMB -Wl,-rpath,"$smb_products" \
    -o .build/check-edit-status
.build/check-edit-status

xcrun clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -IVendor/libsmb2/include \
    Tools/check-folder-create-status.c -L"$smb_products" -lTinyMounterSMB -Wl,-rpath,"$smb_products" \
    -framework CoreFoundation -o .build/check-folder-create-status
.build/check-folder-create-status

xcrun clang -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DHAVE_CONFIG_H=1 '-D_U_=__attribute__((unused))' -DTINYMOUNTER_CCM_REFERENCE=1 \
    -Daes128ccm_encrypt=reference_encrypt -Daes128ccm_decrypt=reference_decrypt \
    -IVendor/libsmb2/include/apple -IVendor/libsmb2/include \
    -c Vendor/libsmb2/lib/aes128ccm.c -o .build/check-smb-ccm-reference.o
xcrun clang -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DHAVE_CONFIG_H=1 '-D_U_=__attribute__((unused))' \
    -IVendor/libsmb2/include/apple -IVendor/libsmb2/include \
    Tools/check-smb-ccm.c .build/check-smb-ccm-reference.o \
    -L"$smb_products" -lTinyMounterSMB -Wl,-rpath,"$smb_products" -o .build/check-smb-ccm
.build/check-smb-ccm
