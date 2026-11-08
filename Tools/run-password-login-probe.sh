#!/bin/bash
# Runs the CLI password-login cases against the VM Samba fixture. Run it in the VM.
# Reads the fixture password once from the login keychain (one Allow prompt), keeps it in
# memory and pipes it to each case. Prints no server address, account password or share data.
set -uo pipefail
cd "$(dirname "$0")/.."
server=${1:?usage: run-password-login-probe.sh <server> <account> <encrypted share>}
account=${2:?}
share=${3:?}
probe=.build/login-probe/probe-password-login
password=$(/usr/bin/security find-internet-password -s "$server" -a "$account" -w) || exit 1
run() { printf '%s' "$password" | "$probe" "$@" 2>&1 | sed "s/$server/<server>/g"; }
echo "smbfs mounts: $(mount | grep -c smbfs)"
echo "## password, share with encryption required"; run "$server" "$share" "$account"
echo "## password, IPC\$"; run "$server" 'IPC$' "$account"
echo "## password, domain WORKGROUP"; run "$server" "$share" "$account" WORKGROUP
echo "## password, unrelated domain"; run "$server" "$share" "$account" OTHERDOMAIN
echo "## password, missing share"; run "$server" tinymounter-missing "$account"
echo "## current GSS path"; "$probe" --current "$server" "$share" "$account" 2>&1 | sed "s/$server/<server>/g"
password=
