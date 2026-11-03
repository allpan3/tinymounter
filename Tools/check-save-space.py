#!/usr/bin/env python3
"""Run the real-disk M23 core check on a disposable 4 GiB APFS image in macOS VM 1.

Pass a new --evidence directory in the VM. The image is detached afterward and
retained with the test log and report. Only that image is filled; the VM boot
volume is never filled. This checks local outbox recovery, not Finder callbacks.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin" or Path.home() != Path("/Users/user"):
        raise RuntimeError("run only in macOS VM 1")
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
    if not model.startswith("VirtualMac"):
        raise RuntimeError("refusing to run outside a macOS VM")
    root = Path(__file__).resolve().parent.parent
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    image = evidence / "TinyMounter-SaveSpace.asif"
    mount = evidence / "volume"
    mount.mkdir()
    status = {"date": datetime.now(timezone.utc).isoformat(), "imageSizeGiB": 4,
              "filesystem": "APFS", "cacheState": "uncontrolled; correctness only"}
    subprocess.run(["diskutil", "image", "create", "blank", "--size", "4GiB", "-fs", "APFS",
                    "--format", "ASIF", "--volumeName", "TinyMounter-SaveSpace", str(image)], check=True,
                   stdout=subprocess.DEVNULL)
    attached = False
    try:
        result = subprocess.check_output(["diskutil", "image", "attach", "--mountOptions", "nobrowse,noowners",
                                          "--mountPoint", str(mount), str(image)])
        attached = True
        (evidence / "attachment.txt").write_bytes(result)
        info = subprocess.check_output(["diskutil", "info", "-plist", str(mount)])
        (evidence / "volume.plist").write_bytes(info)
        if plistlib.loads(info).get("MountPoint") != str(mount):
            raise RuntimeError("unexpected fixture mount")
        (mount / "fixture.txt").write_text("tinymounter-save-space\n")
        (mount / ".metadata_never_index").touch(exist_ok=False)
        env = dict(os.environ, TINYMOUNTER_SAVE_SPACE_FIXTURE=str(mount))
        with (evidence / "test.log").open("x") as log:
            check = subprocess.run(["swift", "test", "--filter", "EditDiskSpaceTests"],
                                   cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        status["exitCode"] = check.returncode
        reports = list(mount.glob("*/report.json"))
        status["reports"] = len(reports)
        for index, report in enumerate(reports):
            (evidence / f"report-{index}.json").write_bytes(report.read_bytes())
        if check.returncode != 0 or len(reports) != 1:
            raise RuntimeError("save-space check failed; inspect the retained test log and image")
    finally:
        if attached:
            detached = subprocess.run(["diskutil", "eject", str(mount)],
                                      stdout=subprocess.DEVNULL, check=False)
            status["detached"] = detached.returncode == 0
        (evidence / "result.json").write_text(json.dumps(status, indent=2) + "\n")
    if not status.get("detached"):
        raise RuntimeError("fixture still mounted; detach it after inspecting evidence")
    print(json.dumps(status))


if __name__ == "__main__":
    main()
