#!/bin/bash
# Builds the 0.2.0 password-login spike probes, unsigned, into $1. Run it in the VM.
# probe-password-login: CLI, NTLMSSP password login (password on stdin).
# TinyMounter-LoginSpike.app: sandboxed Keychain + login probe; sign it on the host before use.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?usage: build-password-login-probe.sh <output folder>}
mkdir -p "$out/objects"
flags=(-std=gnu11 -O1 -DHAVE_CONFIG_H=1 '-D_U_=__attribute__((unused))'
       -IVendor/libsmb2/include/apple -IVendor/libsmb2/include -IVendor/libsmb2/include/smb2 -ITools)
sources=$(python3 -c 'import re
text = open("Vendor/libsmb2/lib/Makefile.am").read().split("libsmb2_la_SOURCES =", 1)[1].split("SOCURRENT", 1)[0]
print(" ".join("Vendor/libsmb2/lib/" + name for name in re.findall(r"[\w-]+\.c", text) if name != "krb5-wrapper.c"))')
objects=()
for source in $sources Prototype/SMB/SMBRename.c; do
    object="$out/objects/$(basename "$source" .c).o"
    xcrun clang "${flags[@]}" -w -c "$source" -o "$object"
    objects+=("$object")
done
xcrun clang "${flags[@]}" -Wall -Wextra -Werror -c Tools/probe-password-login.c -o "$out/objects/probe.o"
xcrun clang "${flags[@]}" -Wall -Wextra -Werror -DPROBE_LOGIN_MAIN=1 \
    Tools/probe-password-login.c "${objects[@]}" -framework CoreFoundation \
    -o "$out/probe-password-login"

app="$out/TinyMounter-LoginSpike.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -O -import-objc-header Tools/probe-password-login.h Tools/probe-keychain-login.swift \
    "$out/objects/probe.o" "${objects[@]}" -framework CoreFoundation -framework Security \
    -o "$app/Contents/MacOS/TinyMounterLoginSpike"
build=${PROBE_BUILD:-1}
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>dev.tinymounter.loginspike</string>
    <key>CFBundleExecutable</key><string>TinyMounterLoginSpike</string>
    <key>CFBundleName</key><string>TinyMounter Login Spike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.$build</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSUIElement</key><true/>
</dict></plist>
EOF
tar -C "$out" -cf "$out/app.tar" TinyMounter-LoginSpike.app
echo "built $out/probe-password-login and $out/app.tar (build $build)"
