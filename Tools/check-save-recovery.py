#!/usr/bin/env python3
"""VM-only M23 fixture preparation/audit; no signing, launch, disk filling or cleanup.

Use the approved open loopback session with the normal app closed. Choose one new
uppercase run UUID. Seed with --run UUID --approved-vm-session --evidence
<private-dir>/probe-m23-final/seed.json. The fixed subtree must not exist.

In an isolated archive, replace TinyMounterApp.swift with check-save-recovery.swift,
then compile/sign with the existing sandbox and identity. Run separate processes:
  TinyMounterPrototype --m23-final c01 UUID EXISTING_WRITABLE_LOCATION_UUID
Repeat for c02, c03 and c04; each refuses reused local state. The selected existing
location must have the approved loopback share-root write bookmark. The helper
uses private settings/catalogs and outboxes, without registering a provider domain.

Copy the private case reports after the app exits. Each report must pass before
running audit with the same arguments and a new final.json evidence file. The audit
requires exact latest/neighbor contents and the retained artifacts' complete bytes.
Keep the fixture and recovery copies until the parent reviews and removes them.

If c02 stopped after retiring its partial stage, or c03 after its retired cleanup, do
not reseed or rerun that case. From an archive built as above with this helper, run
its continuation once. It adopts the case's exact outbox and never admits a new save:
  TinyMounterPrototype --m23-continue c02 UUID LOCATION_UUID
  TinyMounterPrototype --m23-inspect c03 UUID LOCATION_UUID RETIRED_ID RETIRED_STAGE OCCUPANT
c02 copies its outbox, then publishes the already prepared newest save. c03 only
inspects. Its pins come from separately kept parent evidence: the retired record UUID,
then SMB identities as FILEID:BIRTH_MICROSECONDS. Pass "-" where that evidence is
missing; the report then lists the limit. Reports go to <case>/continue or
<case>/inspect, and a second continuation of a case is refused. c02's continuation
can verify completion while retaining its original failure report. c03 reports
inspectionPassed for its final-state checks and always leaves passed false:
historical occupant preservation through cleanup remains unverified, even with
identity pins. Its inspection never replaces the original case's missing result.
Require successful process exit and an independent comparison of original Settings
as well as the report; the helper's final Settings check follows report creation.

For a separate c03 preservation run, use --fresh-c03 with seed and audit. This
creates only c03 in probe-m23-final-UUID, leaving the original fixture untouched.
Use a matching local evidence parent and launch --m23-fresh c03 UUID LOCATION_UUID.
The helper flushes occupant-before.json before successor publication and cleanup,
then occupant-after.json after the full version equality check. Preserve both.
This new case cannot retroactively prove the earlier run's occupant preservation.

c01 injects reserve loss; c02 cancels a native stage upload after 1 MiB; c03 fails
after one acknowledged cleanup; c04 simulates a lost cleanup reply. These are
core/adapter checks, not File Provider callbacks or real disk exhaustion. The
callback files are reserved for separately observed editor checks.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone


MOUNT = Path("/Volumes/tinymounter-m19-edit-test")
ROOT = MOUNT / "probe-m23-final"
CASES = ("c01", "c02", "c03", "c04")
MAX_FILE = 2 << 20
MAX_FILES = 64


def require_fixture():
    if sys.platform != "darwin" or MOUNT.is_symlink() or MOUNT.resolve() != MOUNT:
        raise RuntimeError("fixture unavailable")
    result = subprocess.run(["/sbin/mount", "-t", "smbfs"], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    pattern = (r"//_tinymounter_m19@127\.0\.0\.1/tinymounter-m19-edit-test on "
               r"/Volumes/tinymounter-m19-edit-test \(smbfs(?:, [^\n]*)?\)")
    if not any(re.fullmatch(pattern, line) for line in result.stdout.splitlines()):
        raise RuntimeError("fixture identity mismatch")


def exclusive(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data)
            output.flush()
            os.fsync(fd)
    finally:
        os.close(fd)


def seed(run, root=ROOT, cases=CASES):
    root.mkdir(mode=0o700)
    exclusive(root / "marker.txt", ("tinymounter-m23-final:" + run + "\n").encode())
    for case in cases:
        directory = root / case
        directory.mkdir(mode=0o700)
        exclusive(directory / "document.txt", ("base " + case + "\n").encode())
        exclusive(directory / "neighbor.txt", ("neighbor " + case + "\n").encode())
    if cases == CASES:
        directory = root / "callbacks"
        directory.mkdir(mode=0o700)
        for name in ("direct.txt", "atomic.txt", "neighbor.txt"):
            exclusive(directory / name, ("base " + name + "\n").encode())
    return {"seeded": True, "files": 1 + 2 * len(cases) + (3 if cases == CASES else 0), "cases": list(cases)}


def audit(run, root=ROOT, cases=CASES):
    if root.is_symlink() or root.resolve() != root:
        raise RuntimeError("fixture scope mismatch")
    if (root / "marker.txt").read_bytes() != ("tinymounter-m23-final:" + run + "\n").encode():
        raise RuntimeError("fixture marker mismatch")
    report = []
    for case in cases:
        directory = root / case
        if directory.is_symlink() or directory.resolve() != directory:
            raise RuntimeError("fixture scope mismatch")
        files = list(directory.iterdir())
        if len(files) > MAX_FILES:
            raise RuntimeError("fixture bound exceeded")
        counts = {"stage": 0, "recovery": 0, "work": 0, "other": 0}
        for path in files:
            if path.is_symlink() or not path.is_file():
                raise RuntimeError("unexpected fixture entry")
            if path.stat().st_size > MAX_FILE:
                raise RuntimeError("fixture bound exceeded")
            if path.name in ("document.txt", "neighbor.txt"):
                continue
            kind = path.suffix.lstrip(".")
            counts[kind if kind in counts else "other"] += 1
        document = (directory / "document.txt").read_bytes()
        neighbor = (directory / "neighbor.txt").read_bytes()
        expected = b"N" * 4096 if case == "c01" else b"latest complete save\n"
        expected_counts = {"stage": int(case in ("c02", "c03")), "recovery": int(case == "c04"),
                           "work": 0, "other": 0}
        if document != expected or neighbor != ("neighbor " + case + "\n").encode() or counts != expected_counts:
            raise RuntimeError("unexpected final contents or artifacts in " + case)
        artifact_bytes = {"c02": b"A" * (1 << 20), "c03": b"new occupant\n", "c04": b"base c04\n"}
        for path in files:
            if path.name not in ("document.txt", "neighbor.txt"):
                if not re.fullmatch(r"\.tinymounter-[0-9A-F-]{36}\.(stage|recovery)", path.name):
                    raise RuntimeError("unexpected artifact name")
                if path.read_bytes() != artifact_bytes[case]:
                    raise RuntimeError("retained artifact contents changed")
        report.append({"case": case, "latest_matches": document == expected,
                       "neighbor_matches": neighbor == ("neighbor " + case + "\n").encode(),
                       "document_sha256": hashlib.sha256(document).hexdigest(),
                       "artifacts": counts})
    return {"cases": report}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("seed", "audit"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--approved-vm-session", action="store_true", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--fresh-c03", action="store_true")
    args = parser.parse_args()
    if str(uuid.UUID(args.run)).upper() != args.run:
        raise RuntimeError("uppercase run UUID required")
    evidence = args.evidence.absolute()
    root = MOUNT / ("probe-m23-final-" + args.run) if args.fresh_c03 else ROOT
    cases = ("c03",) if args.fresh_c03 else CASES
    if evidence.parent.name != root.name or evidence.exists():
        raise RuntimeError("use a new private probe-m23-final evidence file")
    require_fixture()
    if evidence.resolve().is_relative_to(MOUNT.resolve()):
        raise RuntimeError("evidence must be outside the SMB mount")
    evidence.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if evidence.parent.is_symlink() or evidence.parent.resolve() != evidence.parent:
        raise RuntimeError("evidence scope mismatch")
    result = seed(args.run, root, cases) if args.action == "seed" else audit(args.run, root, cases)
    result.update({"run": args.run, "date": datetime.now(timezone.utc).isoformat(), "cache": "uncontrolled",
                   "real_disk_exhaustion": "unverified"})
    exclusive(evidence, (json.dumps(result, sort_keys=True) + "\n").encode())
    print(json.dumps({"action": args.action, "recorded": True}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"failed": True, "error_type": type(error).__name__}), file=sys.stderr)
        raise SystemExit(1)
