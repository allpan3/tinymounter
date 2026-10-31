#!/usr/bin/env python3
r"""Parent-operated M24 cancellation, Stop and automatic-settlement probe.

Source only until the parent builds and runs it. A pass requires a successful app
exit, its phase report, and this tool's backing-fixture audit. This tool prepares
and audits synthetic files. It never launches, builds, signs, installs, mounts,
changes server settings, supplies credentials or removes evidence.

Use the accepted macOS VM 1 session at SESSION below, the existing native mount
/Volumes/tinymounter-m19-edit-test and backing root device 16777234, inode 63266703.
The endpoint is 127.0.0.1/tinymounter-m19-edit-test, account _tinymounter_m19.
Keep the normal app closed. Run this probe and the existing recursive probe
sequentially. Each run owns one new UUID subtree and one private catalog;
other deletion records must remain equal. The shared guard must match the pending
inventory; production reconciliation removes a stale guard when no record needs it.

Parent execution
---------------
Choose one new uppercase UUID RUN. EVIDENCE must be SESSION/m24-cancellation-RUN.
Run Python as root in the VM, with these arguments for every action:
  python3 -I Tools/check-deletion-cancellation.py ACTION --run RUN \
    --evidence EVIDENCE --fixture-device 16777234 --fixture-inode 63266703

1. Confirm the backing identity with stat, then run ACTION prepare once.
2. In an isolated archive of the integration source, compile
   Tools/check-deletion-cancellation.swift in place of
   Prototype/App/TinyMounterApp.swift. Keep every other source, bundle identity,
   signing identity, entitlement and sandbox setting. Do not install or register
   the app or a File Provider domain. Build/sign decisions and all VM work belong
   to the parent; this script does none of them.
3. Run each phase below once, in order, as the fixture user, with a 560 s parent
   process timeout:
     ARCHIVE/TinyMounterPrototype.app/Contents/MacOS/TinyMounterPrototype \
       --m24-cancellation PHASE RUN 3A9DE695-8327-4D86-B393-2520E71A75D8
4. After each process exits, copy only PHASE-report.json from the container's
   Application Support/tinymounter/M24Cancellation/RUN/ to
   SESSION/m24-cancellation-RUN-app/. Run ACTION audit with --phase PHASE,
   --app-exit-status STATUS and --app-report COPY. If a timeout left no report,
   omit --app-report. The audit preserves the current bounded inventory and fails.
   Continue only after both the process and backing audit pass. Never rerun a
   phase under the same RUN; retain failed runs and choose a new RUN.

Phases and forced orderings
--------------------------
cancel: The source's synchronous onChange callback cancels the primary Progress,
then checks durable admission before the scheduler can execute a node. All
three tree nodes must be stopped, their bytes retained, Settings complete, and
the reply cancelled. This exercises deleteItem, not a manually edited journal.
Listing notifications before the scheduler registers that Progress are ignored.

joined: Delete one file and suspend the supplied asynchronous Settings callback.
Join the request, drain its registration, block the otherwise idle share lane and
cancel the joined Progress. A counted Stop must be queued, with neither reply
delivered. Process that Stop while Settings stays suspended, then release Settings.
Both replies must arrive once. Success here requires durable confirmed deletion,
completed catalog/Settings settlement and a selected tombstone. Cancellation after
confirmed remote deletion is not proof that the file survived.

close: Close the source in the same post-admission callback. Its active Progress
is cancelled, but closure must not create a token-driven Stop. The request replies
catalogClosed and the durable three-node plan remains prepared and unsettled.

unsettled: Reopen that catalog in a new process. Call retryDeletions twice and
drain the lane, observe for two seconds, then drain again. Inventory must remain
unchanged, with no recovery or Settings call. Queue two explicit Stops around a
second lane barrier and close the source before either runs. Observe pending Stop
counts 2, 1, 0; both replies must succeed once. The first checkpoint stops the
whole plan, the second is idempotent. Catalog settlement remains incomplete.

stopped: Reopen and call only retryDeletions to complete the stopped record's
catalog and private Settings obligations. Then replay the original request and
require a cancelled reply, unchanged outcomes and no additional Settings work.

uncertain: Admit one file using prepareDeletionOnLane. Run the production
RecursiveDeletionTransaction with the real SMBEdit adapter, wrapping closeTarget
to throw after the real close. Destroy that client before any later namespace
acquisition. Queue explicit Stop, close the source and release the lane. The
record must become settled but unconfirmed, with its guard and keep retained.
Native absence is deferred to the backing audit until the next phase settles it.
This injects a lost reply; it does not simulate a real network failure.

reconcile: In a new process call retryDeletions to complete the unconfirmed
record's catalog obligations. Its pending notice, uncertainty, guard and saved
keep must remain. Request replay must return unresolved and leave state unchanged.

Bounds, evidence and limits
---------------------------
Capture costs one fresh SMB connection, each executed node one more. The maximum
planned count is two per phase, sequential, with no helper retries. Allow about
20 s per connection for scheduling; this is not a measurement of this probe.
Reply/gate waits share a 520 s deadline. An independent process watchdog
exits at 550 s, so blocking native calls cannot silently exceed the parent's 560 s
bound. A watchdog exit can leave no report. Between operations the probe waits
off-lane for up to 30 s for normal ShareAccess health recovery after slow refusals.

The helper checks durable catalog rows against the admitted IDs and outcomes and
compares original Settings bytes before/after every phase and across processes.
Its Settings copy and original-settings.bin contain private data and
must stay in the container. Reports contain opaque IDs and fixed case labels.
Each start marker, report and backing audit is exclusive. A failed audit preserves
its observed inventory; never treat a report marked passed as sufficient by itself.

The backing audit checks the exact entry set, identities, complete file bytes,
mtime, link count, ownership, mode, flags and extended attributes. Directory times
are excluded because child deletion changes them. Cache state is uncontrolled.
No mutation beyond deleting joined/file.txt and uncertain/file.txt is expected.
Hashes here verify fixture contents, not source provenance.

Missing cases are explicit in every report: cancellation inside a protected node,
the KVO-before-lock race, completion concurrent with an unqueued Stop, real crash
or network loss, remount, storage failure, multiple views, active read/watch drains,
Finder/provider/IPC and the controller's actual Settings or lifecycle callbacks.
The two-second duplicate-reply observation is bounded. No race is claimed passed
unless the probe observes its prerequisite gate. Automatic retry's unchanged
inventory proves no resumed deletion in this ordering, not zero network requests.

Retain the subtree, EVIDENCE, reports, private Settings/catalog and all deletion
records for parent review. The final unconfirmed record and its domain/shared
guards remain pending. There is no Dismiss, cleanup, installation or publication
step in this runbook.
"""

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import stat
import sys
import uuid


SESSION = Path("/Users/user/Developer/tinymounter/.local/phase4/m21-20261029")
FIXTURE = Path("/Users/Shared/tinymounter-m19-edit-fixture")
PINNED_ID = (16777234, 63266703)
PHASES = ("cancel", "joined", "close", "unsettled", "stopped", "uncertain", "reconcile")
FILES = ("cancel/Tree/a.txt", "cancel/Tree/b.txt", "joined/file.txt", "close/Tree/a.txt",
         "close/Tree/b.txt", "uncertain/file.txt", "neighbor.txt")
FORCED = {
    "cancel": ["cancel-after-durable-admission-before-node-execution"],
    "joined": ["joined-cancellation-while-settings-suspended"],
    "close": ["close-after-admission-without-token-stop"],
    "unsettled": ["automatic-retry-of-unsettled-inventory", "two-counted-explicit-stops-survive-source-close"],
    "stopped": ["automatic-settlement-of-stopped-record"],
    "uncertain": ["lost-close-reply-followed-by-explicit-stop-and-close"],
    "reconcile": ["automatic-settlement-of-unconfirmed-record"],
}
REPLIES = {
    "cancel": ("primary", "primary-started"),
    "joined": ("primary", "primary-started", "joined", "joined-started"),
    "close": ("primary", "primary-started"),
    "unsettled": ("stop-1", "stop-2"),
    "stopped": ("replay", "replay-started"),
    "uncertain": ("uncertain-stop",),
    "reconcile": ("replay", "replay-started"),
}
MAX_ENTRIES = 32
MAX_FILE = 64 << 10
MAX_BYTES = 1 << 20


def require(condition, label):
    if not condition:
        raise RuntimeError(label)


def now():
    return datetime.now(timezone.utc).isoformat()


def checked_directory(path):
    require(path.resolve(strict=True) == path and stat.S_ISDIR(path.lstat().st_mode), "directory-alias-or-kind")
    return path.lstat()


def load(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 4 << 20, "bounded-report")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino), "report-identity")
        return json.load(stream)


def write_new(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def fixture(args):
    require(platform.system() == "Darwin" and os.geteuid() == 0, "macOS-VM-root-required")
    require(str(uuid.UUID(args.run)).upper() == args.run, "canonical-run-UUID")
    user = pwd.getpwnam("user")
    require(user.pw_dir == "/Users/user", "fixture-user")
    checked_directory(SESSION)
    mapping = SESSION / "server/username-map"
    require(mapping.resolve(strict=True) == mapping and stat.S_ISREG(mapping.lstat().st_mode), "mapping-alias")
    require(mapping.read_text().splitlines() == ["user = _tinymounter_m19", "nobody = _tinymounter_m19_observer"],
            "accepted-session-user-mapping")
    require((args.fixture_device, args.fixture_inode) == PINNED_ID, "requested-backing-identity")
    info = checked_directory(FIXTURE)
    require((info.st_dev, info.st_ino) == PINNED_ID, "backing-identity")
    evidence = Path(args.evidence)
    require(evidence.is_absolute() and evidence.parent == SESSION
            and evidence.name == "m24-cancellation-" + args.run, "evidence-boundary")
    return user, FIXTURE / ("probe-m24-cancellation-" + args.run), evidence


def digest(data):
    return hashlib.sha256(data).hexdigest()


def extended_attributes(path):
    # Bundled macOS Python lacks the xattr helpers; option 1 prohibits following links.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    length = libc.listxattr(encoded, None, 0, 1)
    require(0 <= length <= 64 << 10, "xattr-list-bound")
    names = ctypes.create_string_buffer(max(1, length))
    require(libc.listxattr(encoded, names, length, 1) == length, "xattr-list-changed")
    result = {}
    for name in names.raw[:length].split(b"\0"):
        if not name:
            continue
        size = libc.getxattr(encoded, name, None, 0, 0, 1)
        require(0 <= size <= 64 << 10 and len(result) < 32, "xattr-value-bound")
        value = ctypes.create_string_buffer(max(1, size))
        require(libc.getxattr(encoded, name, value, size, 0, 1) == size, "xattr-value-changed")
        result[os.fsdecode(name)] = digest(value.raw[:size])
    return result


def inventory(root):
    device = checked_directory(root).st_dev
    result, pending, total = {}, [root], 0
    while pending:
        path = pending.pop()
        require(len(result) < MAX_ENTRIES, "entry-bound")
        info = path.lstat()
        require(info.st_dev == device, "fixture-device-bound")
        entry = {"device": info.st_dev, "inode": info.st_ino, "mode": stat.S_IMODE(info.st_mode),
                 "uid": info.st_uid, "gid": info.st_gid, "flags": info.st_flags,
                 "xattrs": extended_attributes(path)}
        if stat.S_ISDIR(info.st_mode):
            entry["kind"] = "directory"
            with os.scandir(path) as children:
                for child in children:
                    require(len(pending) < MAX_ENTRIES, "directory-entry-bound")
                    pending.append(Path(child.path))
        else:
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "ordinary-single-link-file")
            require(0 <= info.st_size <= MAX_FILE, "file-size-bound")
            total += info.st_size
            require(total <= MAX_BYTES, "total-size-bound")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                require((before.st_dev, before.st_ino) == (info.st_dev, info.st_ino), "opened-file-identity")
                data = stream.read(MAX_FILE + 1)
                after = os.fstat(stream.fileno())
            require((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                    == (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                    and len(data) == info.st_size and path.lstat().st_ino == info.st_ino, "file-changed-during-audit")
            entry.update(kind="file", nlink=info.st_nlink, size=info.st_size,
                         mtime_ns=info.st_mtime_ns, digest=digest(data))
        result[path.relative_to(root).as_posix()] = entry
    return result


def prepare(args):
    user, root, evidence = fixture(args)
    evidence.mkdir(mode=0o700, exist_ok=False)
    checked_directory(evidence)
    write_new(evidence / "prepare-started.json", {"run": args.run, "date": now()})
    root.mkdir(mode=0o700, exist_ok=False)
    directories = {str(parent) for name in FILES for parent in Path(name).parents if str(parent) != "."}
    for name in sorted(directories, key=lambda value: (len(Path(value).parts), value)):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    contents = {name: ("m24-cancellation:" + args.run + ":" + name + "\n").encode() * 4 for name in FILES}
    contents["marker.txt"] = ("tinymounter-m24-cancellation:" + args.run + "\n").encode()
    for name, data in contents.items():
        fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    for name, item in inventory(root).items():
        path = root if name == "." else root / name
        current = path.lstat()
        require((current.st_dev, current.st_ino) == (item["device"], item["inode"]), "chown-owned-fixture-only")
        os.chown(path, user.pw_uid, user.pw_gid, follow_symlinks=False)
    before = inventory(root)
    require(len(before) == 1 + len(directories) + len(contents), "prepared-entry-count")
    write_new(evidence / "fixture.json", {"run": args.run, "date": now(), "before": before,
        "fixture_device": PINNED_ID[0], "fixture_inode": PINNED_ID[1], "cache": "uncontrolled"})
    print(json.dumps({"run": args.run, "prepared": True, "entries": len(before)}))


def app_report(args):
    require(args.app_exit_status == 0, "app-exit-must-succeed")
    require(args.app_report is not None, "app-report-required")
    path = Path(args.app_report)
    require(path.is_absolute() and path.parent == SESSION / ("m24-cancellation-" + args.run + "-app")
            and path.name == args.phase + "-report.json", "copied-report-boundary")
    checked_directory(path.parent)
    report = load(path)
    require(report.get("run") == args.run and report.get("phase") == args.phase, "app-report-identity")
    require(report.get("passed") is True and report.get("requiresSuccessfulProcessExit") is True, "app-report-pass")
    require(report.get("forced") == FORCED[args.phase], "race-prerequisites-not-forced")
    require(report.get("replyCounts") == {name: 1 for name in REPLIES[args.phase]}, "exactly-once-reply-counts")
    expected_settings = int(args.phase in ("cancel", "joined", "stopped", "reconcile"))
    require(report.get("settingsCalls") == report.get("settingsWrites") == expected_settings,
            "exact-settings-call-and-write-counts")
    require(report.get("nativeAbsenceDeferredToBackingAudit", False) == (args.phase == "uncertain"),
            "native-absence-deferral")
    require(all(report.get(name) is True for name in ("originalSettingsEqual", "nativeFixtureMatches",
                "keepsMatchOutcomes", "guardsMatchInventory", "catalogMatchesOutcomes",
                "recoveryStateDrained")), "app-evidence-incomplete")
    require(isinstance(report.get("untested"), list) and report["untested"], "missing-limitations")
    require(isinstance(report.get("seconds"), (int, float)) and 0 <= report["seconds"] < 550,
            "app-time-budget")
    return report


def audit(args):
    _, root, evidence = fixture(args)
    checked_directory(evidence)
    manifest = load(evidence / "fixture.json")
    require(manifest.get("run") == args.run
            and (manifest.get("fixture_device"), manifest.get("fixture_inode")) == PINNED_ID, "fixture-manifest")
    index = PHASES.index(args.phase)
    baseline = manifest["before"]
    if index:
        previous = load(evidence / ("audit-" + PHASES[index - 1] + ".json"))
        require(previous.get("run") == args.run and previous.get("result") == "passed", "previous-audit-required")
        baseline = previous["after"]
    write_new(evidence / ("audit-" + args.phase + "-started.json"), {"run": args.run, "date": now()})
    result = {"run": args.run, "phase": args.phase, "date": now(), "result": "failed",
              "app_exit_status": args.app_exit_status, "cache": "uncontrolled"}
    error = None
    try:
        current = inventory(root)
        result["after"] = current
        deleted = {"joined": "joined/file.txt", "uncertain": "uncertain/file.txt"}.get(args.phase)
        expected = {name: item for name, item in baseline.items() if name != deleted}
        require(current == expected, "backing-inventory-mismatch")
        report = app_report(args)
        result.update(result="passed", app=report)
    except Exception as failure:
        error = failure
        result["error"] = str(failure) if isinstance(failure, RuntimeError) else type(failure).__name__
    write_new(evidence / ("audit-" + args.phase + ".json"), result)
    if error is not None:
        raise error
    print(json.dumps({"run": args.run, "audit": args.phase, "result": "passed"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("prepare", "audit"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--fixture-device", type=int, required=True)
    parser.add_argument("--fixture-inode", type=int, required=True)
    parser.add_argument("--phase", choices=PHASES)
    parser.add_argument("--app-report")
    parser.add_argument("--app-exit-status", type=int)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            prepare(args)
        else:
            require(args.phase is not None and args.app_exit_status is not None, "phase-and-exit-status-required")
            audit(args)
    except Exception as error:
        label = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(json.dumps({"result": "failed", "error": label}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
