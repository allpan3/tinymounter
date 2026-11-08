#!/usr/bin/env python3
"""Build and run the SMB2 CHANGE_NOTIFY probe against the disposable Samba fixture.

The fixture address and password come from the VM's Keychain item for the test account and
reach the probe through its environment and stdin; neither is printed.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SMB = ROOT / "Vendor/libsmb2"


def build(output):
    makefile = (SMB / "lib/Makefile.am").read_text()
    names = re.findall(r"[\w-]+\.c", makefile.split("libsmb2_la_SOURCES =", 1)[1].split("SOCURRENT", 1)[0])
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "xcrun", "clang", "-std=gnu11", "-O2", "-Wall", "-Wno-unused-parameter", "-Wno-sign-compare",
        "-DHAVE_CONFIG_H=1", "-DHAVE_LIBKRB5=1", "-D_U_=__attribute__((unused))",
        f"-I{SMB}/include/apple", f"-I{SMB}/include", f"-I{SMB}/include/smb2",
        *[str(SMB / "lib" / name) for name in names], str(ROOT / "Tools/check-smb-notify.c"),
        "-framework", "GSS", "-framework", "CoreFoundation", "-o", str(output),
    ], check=True)


def credential(account):
    attributes = subprocess.run(["/usr/bin/security", "find-internet-password", "-a", account, "-r", "smb "],
                                capture_output=True, text=True)
    match = re.search(r'"srvr"<blob>="([^"]+)"', attributes.stdout)
    if attributes.returncode or not match:
        sys.exit("fixture credential unavailable")
    host = os.environ.get("TM_NOTIFY_HOST", match.group(1))
    secret = subprocess.run(["/usr/bin/security", "find-internet-password", "-s", host, "-a", account, "-w"],
                            capture_output=True)
    if secret.returncode:
        sys.exit("fixture credential unavailable")
    return host, secret.stdout.rstrip(b"\n") + b"\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, default=ROOT / ".build/check-smb-notify")
    parser.add_argument("--share", default="tinymounter-notify")
    parser.add_argument("--account", default="tmnotify")
    parser.add_argument("--log", type=Path, help="append the probe's JSON lines here")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("scenario", nargs=argparse.REMAINDER,
                        help="coverage [filter] | content | flat | latency [n] [depth] | burst n buffer [late] | buffers | shared | "
                             "many n | cancel | listen folder seconds [echo_s] | idle seconds [echo_s]")
    arguments = parser.parse_args()
    if not arguments.no_build:
        build(arguments.probe)
    host, secret = credential(arguments.account)
    environment = dict(os.environ, TM_NOTIFY_HOST=host, TM_NOTIFY_SHARE=arguments.share,
                       TM_NOTIFY_ACCOUNT=arguments.account)
    log = arguments.log.open("ab") if arguments.log else None
    status = 0
    # One credential read serves several scenarios, separated by ",".
    words = " ".join(arguments.scenario).split(",")
    for scenario in (w.split() for w in words if w.split()):
        process = subprocess.Popen([str(arguments.probe), *scenario], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, env=environment)
        process.stdin.write(secret)
        process.stdin.close()
        for line in process.stdout:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            if log:
                log.write(line)
                log.flush()
        status = status or process.wait()
    return status


if __name__ == "__main__":
    sys.exit(main())
