#!/usr/bin/env python3
"""Build and run the change-watching check against the disposable Samba fixture.

It links the app's SMBWatch and LocationChangeWatch with the built libTinyMounterSMB, so build
the app first (Tools/run-checks.sh does). The fixture address and password come from files
that stay in the VM; the password reaches the check on stdin. Neither is printed.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SMB = ROOT / "Vendor/libsmb2"
SCENARIOS = "coverage | overflow | names | parents | restart [s] | idle [s] | echo-timeout | limit"


def build(output, products):
    output.parent.mkdir(parents=True, exist_ok=True)
    actor = output.with_suffix(".actor.o")
    subprocess.run([
        "xcrun", "clang", "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-DHAVE_CONFIG_H=1", "-D_U_=__attribute__((unused))",
        f"-I{SMB}/include/apple", f"-I{SMB}/include", f"-I{SMB}/include/smb2", f"-I{ROOT}/Tools",
        "-c", str(ROOT / "Tools/check-smb-watch-actor.c"), "-o", str(actor),
    ], check=True)
    swift = sorted(str(p) for p in (ROOT / "Sources/TransferCore").glob("*.swift"))
    subprocess.run([
        "xcrun", "swiftc", "-O", "-parse-as-library", "-import-objc-header", str(ROOT / "Tools/check-smb-watch.h"),
        *swift, str(ROOT / "Prototype/App/SMBWatch.swift"), str(ROOT / "Prototype/App/LocationChangeWatch.swift"),
        str(ROOT / "Tools/check-smb-watch.swift"), str(actor),
        f"-L{products}", "-lTinyMounterSMB", "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-o", str(output),
    ], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", type=Path, default=ROOT / ".build/check-smb-watch")
    parser.add_argument("--products", type=Path, default=ROOT / ".build/xcode/Build/Products/Release")
    parser.add_argument("--host-file", type=Path, required=True)
    parser.add_argument("--password-file", type=Path, required=True)
    parser.add_argument("--share", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--log", type=Path, help="append the check's JSON lines here")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("scenario", nargs=argparse.REMAINDER, help=SCENARIOS)
    arguments = parser.parse_args()
    if not arguments.no_build:
        build(arguments.check, arguments.products)
    environment = dict(os.environ, TM_WATCH_HOST=arguments.host_file.read_text().strip(),
                       TM_WATCH_SHARE=arguments.share, TM_WATCH_ACCOUNT=arguments.account)
    log = arguments.log.open("ab") if arguments.log else None
    status = 0
    # One run can hold several scenarios, separated by ",".
    for scenario in (w.split() for w in " ".join(arguments.scenario).split(",") if w.split()):
        process = subprocess.Popen([str(arguments.check), *scenario], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, env=environment)
        process.stdin.write(arguments.password_file.read_bytes())
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
