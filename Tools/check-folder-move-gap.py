#!/usr/bin/env python3
r"""Parent-operated M22 signed checks of the folder-move Settings gap.

This tool prepares and audits the backing fixture only. It never builds, signs,
installs, launches, mounts, changes the fixture after preparation, cleans up or
changes server configuration. Use only macOS VM 1 with the approved loopback
session SESSION below, its existing mount /Volumes/tinymounter-m19-edit-test,
and the normal app closed. Run one process at a time: SMBEdit holds a
process-wide client lock, and each helper phase opens its connections one after
another.

Build (parent): in an isolated archive of the integration commit, compile
Tools/check-folder-move-gap.swift IN PLACE OF Prototype/App/TinyMounterApp.swift.
Keep every other app source, the bundle identity, entitlements and sandbox. No
installation, provider registration or File Provider domain is needed. Launch the
signed executable directly, as the fixture user:
  ARCHIVE/TinyMounterPrototype.app/Contents/MacOS/TinyMounterPrototype \
    --m22-gap PHASE RUN 3A9DE695-8327-4D86-B393-2520E71A75D8
That location must be the existing writable one whose write bookmark is the share
root. The helper only reads the original Settings and checks at the end that its
bytes are unchanged. Each phase keeps private Settings, catalogs and its report in
the container's Application Support/tinymounter/M22Gap/RUN/PHASE/; stdout carries
only a phase label.

Sequence. RUN is one new uppercase UUID; EVIDENCE is SESSION/m22-gap-RUN.
Every Python step runs as root with the same arguments:
  python3 -I Tools/check-folder-move-gap.py ACTION --run RUN --evidence EVIDENCE \
    --fixture-device 16777234 --fixture-inode 63266703
  1. stat -f '%d %i' /Users/Shared/tinymounter-m19-edit-fixture prints 16777234 63266703.
  2. ACTION prepare.
  3. For each phase in order: launch it once with a 600 s timeout. Copy only
     PHASE-report.json, if it exists, to SESSION/m22-gap-RUN-app/; Settings.json
     holds a bookmark and stays private. Then run ACTION audit with --phase PHASE
     --app-exit-status STATUS and, when a report exists, --app-report COPY. Audit
     every phase, including failed ones: phases use separate subtrees.

  Phase      Cases (each moves FOLDER/src/.../Tree to Moved)                 Connections
  spelling   case: child.txt to CHILD.txt; nfd: NFC Cafe name to NFD        8
  ancestors  ancestor: src/Old renamed and replaced; destination: dst
             replaced, restored and retried                                 9
  retry      root: one view finished, root renamed, retired and rediscovered;
             recover: injected Settings error, direct replan, retry         12

Each Settings call uses one protected SMB connection, after the mover released
its namespace and SMB scopes. Its lock check requires
protectFolderMoveParents(source: destination, destination: destination) to equal
the durable destinationParents and, unless retired, the root identity and exact name to match.
Then the call makes its outside change with the production no-replace SMB
renames; it never uses native renames. The destination-replacement call skips
its lock check, because its own parent handle would deny the rename; the retry's
call checks equality on the restored parent. Earlier connections took about 20 s
here, so the longest phase should take about four minutes. The helper's 555 s
watchdog writes a failed report and exits. It waits at most 30 s (20 s inside
Settings, which the mover bounds at 60 s) for normal share-health recovery, never
resets health, and retries only connection setup and a production move whose
Settings step was never reached.

Expected. case and nfd: the move completes with a recovery plan; the respelled
child's exact binding is retired; a relisting gives it a new discovery ID with no
keep, no e1 version and no edit base; the other descendant keeps its ID, version
and path; the saved keep holds the admitted spelling under the destination.
ancestor: completes without recovery. destination: the first attempt
fails with UploadError.unresolved, stays verified without recovery, keeps the root
bindings at the destination and blocks the namespace; after the restore a verified
retry completes. root: fresh parent evidence retires all admitted IDs in both views,
clears saved subtree keeps and completes with versionChanged. Restoring the server
folder produces new discovery IDs without per-item keeps or e1 versions. recover: the
injected error leaves a verified intent; a direct replan saves a recovering plan
that retires the child; the retry applies that plan unchanged. Replays of
completed intents change nothing and make no Settings call; retired-root replay
still returns versionChanged. Root retirement was approved on 2026-10-30.

Exact bytes. A spelling case passes only if the native listing showed the admitted
bytes before the move and the protected SMB listing shows the exact target bytes
after the server rename. Otherwise the helper records the case unavailable, its
phase exits 1 and the audit records incomplete: never passed. The audit also
requires the backing name to hold the exact target bytes for a passed case; a
canonically equivalent backing spelling records incomplete.

Audit results: passed (exit 0), incomplete (unavailable cases, or a backing
spelling that differs only in normalization), app-failed (no report, a failed
step, or a report that disagrees with the exit status) and failed (unexpected
backing changes). Every result is written exclusively with the full inventory.
The helper only renames: in every result each phase object keeps its inode,
contents and metadata, and only Samba's user.DOSATTRIB may be added. Objects
outside the phase must match exactly. A failed audit stops later phases.

Not tested: listed in each app report under untested, including Finder and
provider callbacks, downloaded-copy invalidation, the controller's Settings,
real crashes, fresh-process retries and spelling-only root or destination changes.

Leftovers for parent teardown: the fixture subtree, EVIDENCE and the app copy
directory, the private M22Gap/RUN directory, completed folder intents in the
container's shared rename outbox, and edit receipts of the synthetic domains each
report lists. A failed phase can leave its folder intent pending.
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
import unicodedata
import uuid
from datetime import datetime, timezone


SESSION = Path("/Users/user/Developer/tinymounter/.local/phase4/m21-20261029")
FIXTURE = Path("/Users/Shared/tinymounter-m19-edit-fixture")
PINNED_ID = (16777234, 63266703)
NFC = "Café.txt"
NFD = "Café.txt"
PHASES = {"spelling": ("case", "nfd"), "ancestors": ("ancestor", "destination"), "retry": ("root", "recover")}
FILES = [
    "neighbor.txt", "spelling/src/Tree/child.txt", "spelling/src/Tree/other.txt", "nfd/src/Tree/" + NFC,
    "nfd/src/Tree/other.txt", "ancestor/src/Old/Tree/a.txt", "destination/src/Tree/a.txt", "root/src/Tree/a.txt",
    "root/src/Tree/Nested/b.txt", "recover/src/Tree/child.txt", "recover/src/Tree/other.txt",
]
EMPTY_DIRECTORIES = ["ancestor/Spare", "destination/dst", "destination/Spare"]
# The committed folder move of each case.
MOVES = {
    "case": ("spelling/src/Tree", "spelling/Moved"), "nfd": ("nfd/src/Tree", "nfd/Moved"),
    "ancestor": ("ancestor/src/Old/Tree", "ancestor/Moved"),
    "destination": ("destination/src/Tree", "destination/dst/Moved"),
    "root": ("root/src/Tree", "root/Moved"), "recover": ("recover/src/Tree", "recover/Moved"),
}
# Net outside renames when a case reports a change; destination and root changes are restored.
OUTSIDE = {
    "case": [("spelling/Moved/child.txt", "spelling/Moved/CHILD.txt")],
    "nfd": [("nfd/Moved/" + NFC, "nfd/Moved/" + NFD)],
    "ancestor": [("ancestor/src/Old", "ancestor/src/OldGone"), ("ancestor/Spare", "ancestor/src/Old")],
    "destination": [], "root": [],
    "recover": [("recover/Moved/child.txt", "recover/Moved/CHILD.txt")],
}
RESPELLED = {"case", "nfd", "recover"}
MAX_ENTRIES = 64
MAX_FILE = 64 << 10


def require(value, label):
    if not value:
        raise RuntimeError(label)


def now():
    return datetime.now(timezone.utc).isoformat()


def payload(run, path):
    return ("m22-gap:" + run + ":" + path + "\n").encode() * 4


def marker(run):
    return ("tinymounter-m22-gap:" + run + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def name_key(name):
    return unicodedata.normalize("NFC", name).casefold()


def case_directory(case):
    return MOVES[case][0].split("/")[0]


def checked_directory(path):
    require(path.resolve(strict=True) == path, "directory-alias")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode), "directory-required")
    return info


def load(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 4 << 20, "bounded-regular-report")
    with path.open() as stream:
        return json.load(stream)


def write_new(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    temporary = path.with_name(".incomplete-" + str(uuid.uuid4()).upper())
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        identity = os.fstat(stream.fileno())
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    # The link refuses an existing name, so no step replaces earlier evidence.
    os.link(temporary, path, follow_symlinks=False)
    current = temporary.lstat()
    require((current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino), "temporary-identity")
    temporary.unlink()


def fixture(args):
    require(platform.system() == "Darwin", "macOS-VM-only")
    require(str(uuid.UUID(args.run)).upper() == args.run, "uppercase-run-UUID")
    require(os.geteuid() == 0, "run-as-root")
    user = pwd.getpwnam("user")
    require(user.pw_dir == "/Users/user", "native-user-mapping")
    checked_directory(SESSION)
    mapping = SESSION / "server/username-map"
    require(mapping.resolve(strict=True) == mapping and stat.S_ISREG(mapping.lstat().st_mode), "map-alias")
    require(mapping.read_text().splitlines() == ["user = _tinymounter_m19", "nobody = _tinymounter_m19_observer"],
            "exact-username-map")
    require((args.fixture_device, args.fixture_inode) == PINNED_ID, "session-identity-pin")
    info = checked_directory(FIXTURE)
    require((info.st_dev, info.st_ino) == PINNED_ID, "backing-root-identity")
    evidence = Path(args.evidence)
    require(evidence.is_absolute() and evidence.parent == SESSION and evidence.name == "m22-gap-" + args.run,
            "private-session-evidence-child")
    return user, FIXTURE / ("probe-m22-gap-" + args.run), evidence


def extended_attributes(path):
    # macOS's bundled Python omits os.listxattr and os.getxattr; option 1 never follows a link.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    length = libc.listxattr(encoded, None, 0, 1)
    if length < 0:
        raise OSError(ctypes.get_errno(), "list fixture attributes")
    require(length <= 64 << 10, "xattr-name-bound")
    names = ctypes.create_string_buffer(max(1, length))
    require(libc.listxattr(encoded, names, length, 1) == length, "xattr-list-changed")
    result = {}
    for name in names.raw[:length].split(b"\0"):
        if not name:
            continue
        size = libc.getxattr(encoded, name, None, 0, 0, 1)
        if size < 0:
            raise OSError(ctypes.get_errno(), "read fixture attribute")
        require(size <= 64 << 10 and len(result) < 32, "xattr-bound")
        value = ctypes.create_string_buffer(max(1, size))
        require(libc.getxattr(encoded, name, value, size, 0, 1) == size, "xattr-value-changed")
        result[os.fsdecode(name)] = digest(value.raw[:size])
    return result


def inventory(root):
    """Names keep their exact bytes: Python never normalizes them, and the backing APFS preserves them."""
    device = checked_directory(root).st_dev
    result, pending = {}, [root]
    while pending:
        path = pending.pop()
        require(len(result) < MAX_ENTRIES, "fixture-entry-bound")
        info = path.lstat()
        require(info.st_dev == device, "fixture-filesystem-bound")
        name = path.relative_to(root).as_posix()
        entry = {"device": info.st_dev, "inode": info.st_ino, "mode": stat.S_IMODE(info.st_mode),
                 "uid": info.st_uid, "gid": info.st_gid, "xattrs": extended_attributes(path)}
        if stat.S_ISDIR(info.st_mode):
            entry["kind"] = "directory"
            with os.scandir(path) as children:
                for child in children:
                    require(len(pending) < MAX_ENTRIES, "fixture-directory-bound")
                    pending.append(Path(child.path))
        elif stat.S_ISREG(info.st_mode):
            require(info.st_nlink == 1 and 0 <= info.st_size <= MAX_FILE, "fixture-file-bound")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino), "file-open-identity")
                data = stream.read(MAX_FILE + 1)
                after = os.fstat(stream.fileno())
            require((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                    == (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                    and len(data) == info.st_size and path.lstat().st_ino == info.st_ino, "file-changed-during-hash")
            entry.update(kind="file", nlink=info.st_nlink, size=info.st_size, mtime_ns=info.st_mtime_ns,
                         digest=digest(data))
        else:
            raise RuntimeError("fixture-special-entry")
        result[name] = entry
    return result


def renamed(layout, old, new):
    require(old in layout and new not in layout, "expected-rename:" + old)
    result = {}
    for path, item in layout.items():
        if path == old or path.startswith(old + "/"):
            path = new + path[len(old):]
        result[path] = item
    return result


def in_cases(path, cases):
    return path.split("/")[0] in {case_directory(case) for case in cases}


def same_object(expected, actual, label):
    """Renames keep every recorded property; Samba may add only its DOS attributes."""
    require(all(actual["xattrs"].get(key) == value for key, value in expected["xattrs"].items())
            and set(actual["xattrs"]) - set(expected["xattrs"]) <= {"user.DOSATTRIB"}, "attributes:" + label)
    require({key: value for key, value in actual.items() if key != "xattrs"}
            == {key: value for key, value in expected.items() if key != "xattrs"}, "object-changed:" + label)
    return actual["xattrs"] != expected["xattrs"]


def renames_only(baseline, current, cases):
    """Outside the phase nothing changes; inside it the same objects remain, perhaps under new names."""
    outside = {path: item for path, item in baseline.items() if not in_cases(path, cases)}
    require({path: item for path, item in current.items() if not in_cases(path, cases)} == outside,
            "outside-phase-changed")
    before = {item["inode"]: item for path, item in baseline.items() if in_cases(path, cases)}
    after = {item["inode"]: (path, item) for path, item in current.items() if in_cases(path, cases)}
    require(set(after) == set(before), "phase-objects-created-or-removed")
    return sorted(path for inode, (path, item) in after.items() if same_object(before[inode], item, path))


def expected_layout(baseline, current, case, record):
    """The case's backing layout from the outcome, move and change its report records."""
    moved, changed, outcome = record.get("moved"), record.get("changed"), record.get("outcome")
    require(isinstance(moved, bool) and isinstance(changed, bool) and outcome in ("passed", "unavailable"),
            "case-record:" + case)
    require(moved or not changed, "change-without-move:" + case)
    require(outcome != "passed" or changed, "passed-without-change:" + case)
    layout, spelling, incomplete = dict(baseline), None, None
    if moved:
        layout = renamed(layout, *MOVES[case])
    if changed:
        for old, new in OUTSIDE[case]:
            if case not in RESPELLED:
                layout = renamed(layout, old, new)
                continue
            inode = layout[old]["inode"]
            matches = [path for path, item in current.items() if item["inode"] == inode]
            require(len(matches) == 1, "respelled-object:" + case)
            actual = matches[0]
            require(actual.rsplit("/", 1)[0] == old.rsplit("/", 1)[0]
                    and name_key(actual.rsplit("/", 1)[1]) == name_key(old.rsplit("/", 1)[1]), "respelled-name:" + case)
            spelling = {"target": os.fsencode(new).hex(), "backing": os.fsencode(actual).hex(),
                        "exact": os.fsencode(actual) == os.fsencode(new)}
            if outcome == "passed" and not spelling["exact"]:
                require(unicodedata.normalize("NFC", actual) == unicodedata.normalize("NFC", new),
                        "backing-spelling:" + case)
                incomplete = "backing-normalized-spelling:" + case
            if actual != old:
                layout = renamed(layout, old, actual)
    return layout, spelling, incomplete


def app_report(args):
    """The report and how far the app got; a missing report is accepted only after a failed exit."""
    require(args.app_exit_status is not None, "app-exit-status")
    if args.app_report is None:
        require(args.app_exit_status != 0, "copied-app-report-required")
        return None, "app-failed"
    path = Path(args.app_report)
    require(path.is_absolute() and path.parent == SESSION / ("m22-gap-" + args.run + "-app")
            and path.name == args.phase + "-report.json", "copied-app-report-location")
    checked_directory(path.parent)
    report = load(path)
    require(report.get("run") == args.run and report.get("phase") == args.phase, "app-report-run-and-phase")
    require(report.get("requiresSuccessfulProcessExit") is True and isinstance(report.get("untested"), list)
            and report["untested"], "app-report-untested-gates")
    cases = report.get("cases") or {}
    outcomes = [cases.get(case, {}).get("outcome") for case in PHASES[args.phase]]
    # The helper writes its report before the process exits, so a failed exit voids a passed report.
    if report.get("passed") is True and args.app_exit_status == 0 and outcomes == ["passed"] * len(outcomes):
        return report, "passed"
    if (report.get("passed") is False and args.app_exit_status != 0 and "failedStep" not in report
            and all(outcome in ("passed", "unavailable") for outcome in outcomes)):
        return report, "incomplete"
    return report, "app-failed"


def baseline(args, evidence):
    names = list(PHASES)
    index = names.index(args.phase)
    if index == 0:
        manifest = load(evidence / "fixture.json")
        require(manifest.get("run") == args.run and (manifest["fixture_device"], manifest["fixture_inode"])
                == PINNED_ID, "manifest-fixture-identity")
        return manifest["before"]
    previous = load(evidence / ("audit-" + names[index - 1] + ".json"))
    require(previous.get("run") == args.run and previous.get("result") in ("passed", "incomplete", "app-failed")
            and isinstance(previous.get("after"), dict), "previous-audit-has-verified-inventory")
    return previous["after"]


def prepare(args):
    user, root, evidence = fixture(args)
    evidence.mkdir(mode=0o700, exist_ok=False)
    checked_directory(evidence)
    write_new(evidence / "prepare-started.json", {"run": args.run, "date": now(), "fixture": root.name})
    root.mkdir(mode=0o700, exist_ok=False)
    directories = set(EMPTY_DIRECTORIES)
    for name in FILES:
        directories.update(str(path) for path in Path(name).parents if str(path) != ".")
    for name in sorted(directories, key=lambda value: (len(Path(value).parts), value)):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    contents = {name: payload(args.run, name) for name in FILES}
    contents["marker.txt"] = marker(args.run)
    for name, data in contents.items():
        fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    require(os.fsencode(NFC) in os.listdir(os.fsencode(root / "nfd/src/Tree")), "backing-preserves-nfc-bytes")
    for name, item in inventory(root).items():
        path = root if name == "." else root / name
        info = path.lstat()
        require((info.st_dev, info.st_ino) == (item["device"], item["inode"]), "chown-task-identity")
        os.chown(path, user.pw_uid, user.pw_gid, follow_symlinks=False)
    before = inventory(root)
    require(len(before) == 1 + len(directories) + len(contents), "fixture-entry-count")
    write_new(evidence / "fixture.json", {"run": args.run, "date": now(), "before": before,
        "fixture_device": PINNED_ID[0], "fixture_inode": PINNED_ID[1], "cache": "uncontrolled",
        "endpoint": "127.0.0.1/tinymounter-m19-edit-test", "entries": len(before)})
    print(json.dumps({"prepared": True, "run": args.run, "entries": len(before)}))


def audit(args):
    _, root, evidence = fixture(args)
    checked_directory(evidence)
    cases = PHASES[args.phase]
    record = {"run": args.run, "phase": args.phase, "date": now(), "app_exit_status": args.app_exit_status,
              "boundary": "backing store after one app process; the app's private evidence stays local"}
    try:
        start = baseline(args, evidence)
        report, result = app_report(args)
        if report is not None:
            record.update(app_cases=report.get("cases"), app_seconds=report.get("seconds"),
                          app_connections=len(report.get("connections", [])), app_settings=report.get("settingsCalls"),
                          app_failed_step=report.get("failedStep"), app_error=report.get("error"),
                          untested=report["untested"])
        current = inventory(root)
        record["after"] = current
        record["dos_attributes_added"] = renames_only(start, current, cases)
        if result != "app-failed":
            expected, spellings, incomplete = dict(start), {}, []
            for case in cases:
                expected, spelling, reason = expected_layout(expected, current, case, report["cases"][case])
                if spelling:
                    spellings[case] = spelling
                if reason:
                    incomplete.append(reason)
            require(set(current) == set(expected)
                    and all(current[path]["inode"] == item["inode"] for path, item in expected.items()),
                    "backing-layout")
            if incomplete:
                result, record["reasons"] = "incomplete", incomplete
            record["backing_spellings"] = spellings
        record["result"] = result
    except Exception as error:
        record.update(result="failed", error=str(error))
    write_new(evidence / ("audit-" + args.phase + ".json"), record)
    print(json.dumps({"audit": args.phase, "run": args.run, "result": record["result"]}))
    return record["result"] == "passed"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("prepare", "audit"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--fixture-device", type=int, required=True)
    parser.add_argument("--fixture-inode", type=int, required=True)
    parser.add_argument("--phase", choices=list(PHASES))
    parser.add_argument("--app-report")
    parser.add_argument("--app-exit-status", type=int)
    args = parser.parse_args()
    try:
        if args.action == "audit":
            require(args.phase is not None, "audit-phase-required")
            return 0 if audit(args) else 1
        prepare(args)
    except Exception as error:
        print(json.dumps({"result": "failed", "error": str(error)}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
