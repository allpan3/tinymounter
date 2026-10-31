#!/usr/bin/env python3
r"""Parent-operated M22 signed app fixture.

This driver does not build, sign, register, install, launch, stop or clean up anything.
Run only in the already approved macOS VM 1 fixture session, with the normal app
closed. Do not run the helper beside an app using the same application container.

Parent integration:
  Compile Tools/check-folder-move-app.swift into the signed app module IN PLACE OF
  Prototype/App/TinyMounterApp.swift. Retain the production LocationSource,
  ShareAccess, LocationFolderMoves, LocationEdits, settings, core and SMB sources,
  existing bundle identity, entitlements and library. No generator change is
  supplied. The replacement @main avoids AppModel/LocationController startup,
  domain reconciliation, background retries and access to other saved shares.
  The parent owns compilation/signing/launch and must first run required checks.

Sequence (replace RUN with one uppercase UUID; choose a NEW evidence directory):
  1. Inspect the backing fixture identity with stat -f '%d %i' on FIXTURE below.
  2. As root, run:
       python3 Tools/check-folder-move-app.py prepare --run RUN --evidence EVIDENCE \
         --fixture-device DEVICE --fixture-inode INODE
  3. Parent launches its signed task app with arguments:
       --m22-app exercise RUN EXISTING_WRITABLE_LOCATION_UUID
     The selected existing location must have the confirmed loopback share-root
     write bookmark. It is only read; its location, settings and catalogs stay intact.
  4. After the app exits successfully, copy ONLY exercise-report.json and
     checkpoint-intent.json from its private tinymounter/M22App/RUN directory.
     Keep state.json and Settings.json PRIVATE: Settings contains bookmarks.
  5. Run between with the same run/evidence/identity arguments and
       --app-report COPIED_EXERCISE_REPORT
     This changes one synthetic child in place and exclusively moves another
     into Hold. It refuses an unexpected tree or missing app checkpoint.
  6. Parent launches a fresh signed task app process:
       --m22-app resume RUN EXISTING_WRITABLE_LOCATION_UUID
  7. Copy resume-report.json and completed-intent.json; run audit with
       --app-report COPIED_RESUME_REPORT
     Preserve the evidence and all synthetic outboxes until parent review/teardown.
     Each app phase refuses a second invocation with the same run UUID, preserving
     failed reports. Inspect a failure before arranging a separate retry experiment.

Fixture manifest under FIXTURE/probe-m22-app-RUN (11 regular files):
  marker.txt, neighbor.txt
  drain/Tree/read.txt, timeout/Tree/read.txt       each 2.5 MiB
  blocked-{upload,save,retained}/Tree/child.txt
  overlap/Tree/{unchanged,changed,retired}.txt
  overlap/Tree/Nested/leaf.txt
  Empty Dest in every branch; empty overlap/Hold. prepare writes fixture.json
  with every directory/file's identity, mode and complete file digest/mtime.
  exercise moves drain/Tree and overlap/Tree to their Dest/Moved names.
  between writes overlap/Dest/Moved/changed.txt and moves retired.txt into Hold.
  Nothing is removed. The app's pending payloads and reader staging stay local.

Expected: root/subroot/overlap/self-descendant refusals; a real native read and
installed watch drain; a held-read timeout with no intent; prepared upload/save
and injected retained-save refusal; two real LocationSource catalogs preserve
keeps/IDs/versions and saved paths; injected error after settings save leaves an
unfinished verified intent; fresh-process replay replans changed/retired children;
relisting/replay preserve other children; stale read and retired edit are refused.
Each Settings callback acquires the namespace and opens a fresh protected SMB
client on the main actor, proving that the waiting mover holds neither lock.
It checks the stored parent/root identities without changing remote content.

APIs: LocationSource.moveFolder (including its retryFolderMove replay), list,
transfer, keep, configureWriteMode, edit; ShareSession.watch; production outboxes
for local-only pending fixtures; AppSettings.moveKeptFolder through the caller's
settings callback. Catalogs live in the probe directory but ONLY LocationSource
and its normal collaborators perform their operations; no direct transaction
publish or private SMB adapter path substitutes for the app API.

Limits: no Finder/IPC/provider capabilities, materialized-copy validation, actual
crash, one-view-only checkpoint, watch-close timeout injection, remote retained
artifact cleanup, or changed/preserved stale-base save publication. Retired save
fixtures inject a local creatingStage checkpoint with no remote stage. Two prior
ambiguous-name fixtures remain unavailable; this suite does not retest them.
The loopback synthetic cache state is uncontrolled; this is not a performance run.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import stat
import sys
import uuid
from datetime import datetime, timezone


FIXTURE = Path("/Users/Shared/tinymounter-m19-edit-fixture")
MOUNT = Path("/Volumes/tinymounter-m19-edit-test")
ACCOUNT = "_tinymounter_m19"
USERNAME_MAP = Path("/Users/user/Developer/tinymounter/.local/phase4/m21-20261029/server/username-map")


def require(condition, label):
    if not condition:
        raise RuntimeError(label)


def now():
    return datetime.now(timezone.utc).isoformat()


def write_new(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def payloads(run):
    files = {
        "marker.txt": f"tinymounter-m22-app:{run}\n".encode(),
        "neighbor.txt": b"untouched-neighbor\n",
        "overlap/Tree/Nested/leaf.txt": b"inherited-leaf\n",
    }
    for case in ("drain", "timeout"):
        files[f"{case}/Tree/read.txt"] = b"read\n" * 524_288
    for case in ("upload", "save", "retained"):
        files[f"blocked-{case}/Tree/child.txt"] = b"blocked-child\n"
    for name in ("unchanged.txt", "changed.txt", "retired.txt"):
        files[f"overlap/Tree/{name}"] = f"original-{name}\n".encode()
    return files


def checked_directory(path):
    require(path.resolve(strict=True) == path, "directory-or-ancestor-is-an-alias")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode), "expected-directory")
    return info


def fixture_identity(args):
    require(platform.system() == "Darwin", "macOS-VM-only")
    require(str(uuid.UUID(args.run)).upper() == args.run, "uppercase-run-UUID-required")
    info = checked_directory(FIXTURE)
    require((info.st_dev, info.st_ino) == (args.fixture_device, args.fixture_inode), "fixture-identity-mismatch")
    require(os.geteuid() == 0, "run-as-root")
    require(not USERNAME_MAP.is_symlink(), "fixture-username-map-is-not-a-link")
    mappings = USERNAME_MAP.read_text().splitlines()
    require(mappings == ["user = " + ACCOUNT, "nobody = _tinymounter_m19_observer"],
            "fixture-username-map-mismatch")
    account = pwd.getpwnam("user")
    require(account.pw_dir == "/Users/user", "fixture-native-account")
    return account


def inventory(root):
    result = {}
    device = root.lstat().st_dev
    for index, path in enumerate([root] + sorted(root.rglob("*"))):
        require(index < 128, "fixture-entry-bound")
        info = path.lstat()
        require(info.st_dev == device, "fixture-crosses-filesystems")
        require(stat.S_ISDIR(info.st_mode) or (stat.S_ISREG(info.st_mode) and info.st_nlink == 1),
                "fixture-has-link-or-unsupported-entry")
        require(path.resolve(strict=True) == path, "fixture-has-symlink-ancestor")
        item = {"device": info.st_dev, "inode": info.st_ino, "mode": stat.S_IMODE(info.st_mode),
                "kind": "directory" if stat.S_ISDIR(info.st_mode) else "file"}
        if item["kind"] == "file":
            require(info.st_size <= 4 * 1024 * 1024, "fixture-file-size-bound")
            item.update(size=info.st_size, digest=hashlib.sha256(path.read_bytes()).hexdigest(),
                        mtime_ns=info.st_mtime_ns)
        result[path.relative_to(root).as_posix()] = item
    return result


def owned(args):
    account = fixture_identity(args)
    root = FIXTURE / ("probe-m22-app-" + args.run)
    evidence = Path(args.evidence).absolute()
    require(evidence != FIXTURE and FIXTURE not in evidence.parents
            and evidence != MOUNT and MOUNT not in evidence.parents, "evidence-must-be-local-and-outside-share")
    return account, root, evidence


def prepare(args):
    account, root, evidence = owned(args)
    evidence.mkdir(mode=0o700, parents=False, exist_ok=False)
    require(evidence.resolve(strict=True) == evidence, "evidence-directory-alias")
    write_new(evidence / "prepare-started.json", {"run": args.run, "date": now(), "cache": "uncontrolled"})
    root.mkdir(mode=0o700, exist_ok=False)
    directories = {"overlap/Tree/Nested", "overlap/Dest", "overlap/Hold"}
    for branch in ("drain", "timeout", "blocked-upload", "blocked-save", "blocked-retained"):
        directories.update((branch + "/Tree", branch + "/Dest"))
    for path in sorted(directories):
        (root / path).mkdir(mode=0o700, parents=True, exist_ok=False)
    for path, contents in payloads(args.run).items():
        fd = os.open(root / path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
    if os.geteuid() == 0:
        for path in [root] + sorted(root.rglob("*")):
            os.chown(path, account.pw_uid, account.pw_gid, follow_symlinks=False)
    before = inventory(root)
    write_new(evidence / "fixture.json", {"run": args.run, "date": now(), "before": before,
        "fixture_device": args.fixture_device, "fixture_inode": args.fixture_inode,
        "endpoint": "127.0.0.1/tinymounter-m19-edit-test", "cache": "uncontrolled"})
    print(json.dumps({"prepared": True, "run": args.run, "file_count": len(payloads(args.run))}))


def load_fixture(args):
    _, root, evidence = owned(args)
    checked_directory(evidence)
    manifest = json.loads((evidence / "fixture.json").read_text())
    require(manifest["run"] == args.run and manifest["fixture_device"] == args.fixture_device
            and manifest["fixture_inode"] == args.fixture_inode, "manifest-fixture-identity")
    current = inventory(root)
    require(current["."] == manifest["before"]["."], "probe-root-identity")
    require((root / "marker.txt").read_bytes() == payloads(args.run)["marker.txt"], "probe-marker")
    return root, evidence, manifest, current


def app_report(args, phase, case, outcome):
    require(args.app_report is not None, "copied-app-report-required")
    report = json.loads(Path(args.app_report).read_text())
    require(isinstance(report, list) and report, "app-report-shape")
    require(all(event.get("run") == args.run and event.get("phase") == phase for event in report),
            "app-report-run-and-phase")
    require(report[-1].get("case") == "phase" and report[-1].get("outcome") == "passed", "app-phase-not-passed")
    require(any(event.get("case") == case and event.get("outcome") == outcome for event in report),
            "app-required-checkpoint-missing")
    return report


def moved_path(path):
    for prefix in ("drain", "overlap"):
        old = prefix + "/Tree"
        if path == old or path.startswith(old + "/"):
            return prefix + "/Dest/Moved" + path[len(old):]
    return path


def compare(expected, current):
    require(set(expected) == set(current), "unexpected-fixture-entries")
    for path, item in expected.items():
        require(current[path] == item, "fixture-identity-or-contents-changed:" + path)


def rename_exclusive(source, target):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    libc.renamex_np.restype = ctypes.c_int
    if libc.renamex_np(os.fsencode(source), os.fsencode(target), 0x4) != 0:
        raise OSError(ctypes.get_errno(), "exclusive-retirement-rename-failed")


def between(args):
    root, evidence, manifest, current = load_fixture(args)
    report = app_report(args, "exercise", "checkpoint", "ready-for-between")
    expected = {moved_path(path): value for path, value in manifest["before"].items()}
    compare(expected, current)
    write_new(evidence / "between-started.json", {"run": args.run, "date": now(), "app_report": report})
    changed = root / "overlap/Dest/Moved/changed.txt"
    expected_file = current[changed.relative_to(root).as_posix()]
    fd = os.open(changed, os.O_WRONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "wb") as stream:
        info = os.fstat(stream.fileno())
        require((info.st_dev, info.st_ino) == (expected_file["device"], expected_file["inode"]), "changed-file-identity")
        stream.write(b"external-changed.txt\n")
        stream.truncate()
        stream.flush()
        os.fsync(stream.fileno())
    rename_exclusive(root / "overlap/Dest/Moved/retired.txt", root / "overlap/Hold/retired.txt")
    after = inventory(root)
    expected = dict(current)
    expected["overlap/Dest/Moved/changed.txt"] = after["overlap/Dest/Moved/changed.txt"]
    expected["overlap/Hold/retired.txt"] = expected.pop("overlap/Dest/Moved/retired.txt")
    compare(expected, after)
    require(after["overlap/Dest/Moved/changed.txt"]["inode"] == expected_file["inode"], "changed-child-original-object")
    require(after["overlap/Dest/Moved/changed.txt"]["digest"] != expected_file["digest"], "changed-child-new-contents")
    write_new(evidence / "between.json", {"run": args.run, "date": now(), "after": after,
        "boundary": "backing-disk-mutations-between-clean-app-processes"})
    print(json.dumps({"between": True, "run": args.run, "original_retired_child_preserved": True}))


def audit(args):
    _, evidence, _, current = load_fixture(args)
    report = app_report(args, "resume", "recovery", "passed")
    changed = json.loads((evidence / "between.json").read_text())
    require(changed["run"] == args.run, "between-run")
    compare(changed["after"], current)
    write_new(evidence / "audit.json", {"run": args.run, "date": now(), "app_report": report,
        "result": "passed", "unchanged_after_recovery": True,
        "unverified": ["Finder", "materialized copies", "actual crash", "one-view-only commit",
                       "ambiguous names", "changed/preserved stale save publication"]})
    print(json.dumps({"audit": "passed", "run": args.run}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("prepare", "between", "audit"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--fixture-device", type=int, required=True)
    parser.add_argument("--fixture-inode", type=int, required=True)
    parser.add_argument("--app-report")
    args = parser.parse_args()
    try:
        {"prepare": prepare, "between": between, "audit": audit}[args.action](args)
    except Exception as error:
        print(json.dumps({"result": "failed", "error": str(error)}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
