#!/usr/bin/env python3
r"""Parent-operated M24 signed recursive-deletion runtime checks.

This tool prepares, changes and audits the backing fixture only. It never builds,
signs, installs, launches, mounts, cleans up or changes server configuration. Use
only macOS VM 1 with the approved loopback session SESSION below, its existing
mount /Volumes/tinymounter-m19-edit-test, and the normal app closed. Run one
process at a time: SMBEdit holds a process-wide client lock, and each helper phase
opens its own fresh connections, one after another.

Build (parent): in an isolated archive of the integration commit, compile
Tools/check-deletion-runtime.swift IN PLACE OF Prototype/App/TinyMounterApp.swift.
Keep every other app source, the bundle identity, entitlements and sandbox. No
installation, provider registration or File Provider domain is needed. Launch the
signed executable directly, as the fixture user:
  ARCHIVE/TinyMounterPrototype.app/Contents/MacOS/TinyMounterPrototype \
    --m24-recursive PHASE RUN 3A9DE695-8327-4D86-B393-2520E71A75D8
That location must be the existing writable one whose write bookmark is the share
root. The helper only reads the original Settings. It keeps private Settings,
catalogs, state and reports in the container's Application Support/tinymounter/
M24Recursive/RUN/ and stdout carries only a phase label.

Sequence. RUN is one new uppercase UUID; EVIDENCE is SESSION/m24-recursive-RUN.
Every Python step runs as root with the same arguments:
  python3 -I Tools/check-deletion-runtime.py ACTION --run RUN --evidence EVIDENCE \
    --fixture-device 16777234 --fixture-inode 63266703
  1. stat -f '%d %i' /Users/Shared/tinymounter-m19-edit-fixture prints 16777234 63266703.
  2. ACTION prepare.
  3. For each phase in order: launch it once with a 600 s timeout. Copy only
     PHASE-report.json to SESSION/m24-recursive-RUN-app/; Settings.json holds a
     bookmark and stays private. Then run ACTION audit with --phase PHASE
     --app-report COPY --app-exit-status STATUS. Run ACTION compete before the
     compete phase and ACTION replace before the replace phase.

  Phase      Case                                                     Connections
  refuse     listings, two e1 bases, protected replacement, refusals, symlink capture   10
  delete     c01 two-view recursive deletion, replay, relisting       5
  interrupt  c04 admitted; selected close sent, its reply lost        3
  recover    c04 replay after restart stays unconfirmed               1
  admit      c03 admitted only                                        1
  (compete)  Python: Sub moved, changed.txt changed, replaced.txt replaced, arrival
  compete    c03 resumed under its stored plan, then settled          7
  remote     c05 deleted remotely; no settlement                       2
  (replace)  Python: same-name replacement at c05/file.txt
  replace    final replays; c05 settled after a catalog write          0

Earlier connections took about 20 s in this VM, so the longest phase is expected
to run about four minutes. The helper bounds reply waits by a 560 s phase budget;
the parent's process timeout also covers blocked calls. A timeout may lack a report.
Between steps it waits at most 30 s for normal ShareAccess health probes after an
expected slow refusal; it neither resets health nor repeats a failed mutation.
It retries only connection setup, and a production call only when no request can be in flight.
A phase refuses a second launch with the same RUN and keeps the first report.
After a failure, inspect the report; a new attempt needs a new RUN and prepare.

Expected: refusal of a configured root, a stale request at the catalog layer, a
changed e1 child and a replaced child at the traversal, a populated folder without
recursion, an unsupported name, a package child and a hard link, all without a
deletion record. c01 deletes leaf, Nested, a.txt and Tree child-first with no
sharing violation, tombstones both views and finishes both. c04 keeps the folder
unconfirmed after restart while its absent rows are tombstoned. c03 records
deleted, directoryNotEmpty, parentChanged (missing ancestor), unconfirmed,
changed, replaced, deleted and directoryNotEmpty; settlement keeps the survivors,
the replacement under its row ID and the arrival. c05's live replacement refuses
success with versionChanged. Replays change no record; production network calls
are not counted. The
production scheduler runs catalog settlement and calls a private Settings callback.
Saved keeps of confirmed nodes go, including c05's old saved path; the unconfirmed
c04 folder keeps its own. The c05 replacement retains its live catalog binding and
still refuses provider success.

Backing audits require exact neighbor metadata. The two deliberate native content
changes may add Samba DOS attributes and quarantine metadata; existing attributes
must remain equal, and no other additions are accepted. The identical replacement
is prepared with protected SMB no-replace rename, followed by native exclusive
creation; native SMB exclusive rename is unsupported. The moved original may add
only a Samba DOS attribute. The helper refreshes both native parent listings before
opening the moved file. These metadata effects remain in the failed runs' evidence.

Not tested: pagination beyond one listing buffer, the 10,000-node limit, a real
crash or network loss, Finder controls, provider callbacks, launch/reconnect
triggers and the controller's Settings callback, location pending keeps,
competing opens, stop and dismiss, symlinks beyond one capture, and older builds.
Each report lists them. Directory-cache freshness is tested only for server-side
changes made between processes.

Leftovers for parent teardown: the fixture subtree, EVIDENCE, the private
directory, edit receipts, and the deletion records. The c03 and c04 records stay
pending because they are unconfirmed and not dismissed. Their guards stay too,
including the container's shared Renames/Deletion.rename.
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


SESSION = Path("/Users/user/Developer/tinymounter/.local/phase4/m21-20261029")
FIXTURE = Path("/Users/Shared/tinymounter-m19-edit-fixture")
PINNED_ID = (16777234, 63266703)
PHASES = ("refuse", "delete", "interrupt", "recover", "admit", "compete", "remote", "replace")
# Server-side changes made before the app phase of the same name.
MUTATIONS = {"compete": "admit", "replace": "remote"}
FILES = [
    "neighbor.txt", "c01/neighbor.txt", "c01/Sibling/keep.txt", "c01/Tree/a.txt", "c01/Tree/Nested/leaf.txt",
    "c02/Stale/file.txt", "c02/Changed/x.txt", "c02/Changed/y.txt", "c02/Replaced/x.txt", "c02/Replaced/y.txt",
    "c02/Populated/x.txt", "c02/Unsupported/ok.txt", "c02/Unsupported/data.sqlite",
    "c02/WithPackage/Doc.rtfd/TXT.rtf", "c02/Linked/one.txt", "c02/Symlinked/target.txt",
    "c03/neighbor.txt", "c03/Tree/Arrival/z.txt", "c03/Tree/Sub/x.txt", "c03/Tree/changed.txt",
    "c03/Tree/replaced.txt", "c03/Tree/y.txt", "c04/neighbor.txt", "c04/Tree/a.txt", "c05/neighbor.txt",
    "c05/file.txt",
]
EMPTY_DIRECTORIES = ["c02/Hold", "c03/Hold"]
HARD_LINK = ("c02/Linked/two.txt", "c02/Linked/one.txt")
SYMLINK = ("c02/Symlinked/alias.txt", "target.txt")
MAX_ENTRIES = 64
MAX_FILE = 64 << 10
MAX_BYTES = 8 << 20
RENAME_EXCL = 0x4


def require(value, label):
    if not value:
        raise RuntimeError(label)


def now():
    return datetime.now(timezone.utc).isoformat()


def payload(run, path):
    return ("m24-recursive:" + run + ":" + path + "\n").encode() * 4


def changed_bytes(run, path):
    return b"CHANGED!" + payload(run, path)[8:]


def marker(run):
    return ("tinymounter-m24-recursive:" + run + "\n").encode()


def arrival(run):
    return ("m24-arrival:" + run + "\n").encode()


def replacement(run):
    return ("m24-replacement:" + run + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


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
    require(evidence.is_absolute() and evidence.parent == SESSION
            and evidence.name == "m24-recursive-" + args.run, "private-session-evidence-child")
    return user, FIXTURE / ("probe-m24-recursive-" + args.run), evidence


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
    device = checked_directory(root).st_dev
    result, pending, total = {}, [root], 0
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
        elif stat.S_ISLNK(info.st_mode):
            require(name == SYMLINK[0], "fixture-unexpected-symlink")
            entry.update(kind="symlink", nlink=info.st_nlink, target=os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            require(info.st_nlink == 1 or name in HARD_LINK, "fixture-unexpected-hard-link")
            require(0 <= info.st_size <= MAX_FILE, "fixture-file-bound")
            total += info.st_size
            require(total <= MAX_BYTES, "fixture-total-bound")
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


def transformed(baseline, deleted=(), moved=None):
    """The baseline without deleted entries; moved subtrees keep their identities under new names."""
    result = {}
    for path, item in baseline.items():
        if path in deleted:
            continue
        for old, new in (moved or {}).items():
            if path == old or path.startswith(old + "/"):
                path = new + path[len(old):]
                break
        result[path] = item
    return result


def verify(baseline, expected, current, run, user, changed=(), created=None, server_side=False, smb_moved=()):
    """Unchanged objects match exactly; deliberate native writes may add known SMB attributes."""
    created = created or {}
    require(set(current) == set(expected) | set(created), "unexpected-fixture-entries")
    for path, item in expected.items():
        actual = current[path]
        if path in changed or path in smb_moved:
            mutable = {"digest", "mtime_ns"} if path in changed else set()
            if not server_side:
                mutable.add("xattrs")
                require(all(actual["xattrs"].get(key) == value for key, value in item["xattrs"].items()),
                        "changed-file-existing-attributes:" + path)
                added = set(actual["xattrs"]) - set(item["xattrs"])
                allowed = {"user.DOSATTRIB"}
                if path in changed:
                    allowed.add("user.DosStream.com.apple.quarantine:$DATA")
                require(added <= allowed,
                        "changed-file-unexpected-attributes:" + path)
            stable = {key: value for key, value in item.items() if key not in mutable}
            require(set(actual) == set(item) and {key: actual[key] for key in stable} == stable,
                    "changed-file-identity:" + path)
            if path in changed:
                require(actual["digest"] == digest(changed_bytes(run, path)), "changed-file-contents:" + path)
        else:
            require(actual == item, "fixture-identity-or-contents-changed:" + path)
    previous = {(item["device"], item["inode"]) for item in baseline.values()}
    for path, contents in created.items():
        actual = current[path]
        require(actual["kind"] == "file" and actual["nlink"] == 1
                and (actual["device"], actual["inode"]) not in previous, "created-object-is-new:" + path)
        require(actual["size"] == len(contents) and actual["digest"] == digest(contents)
                and actual["uid"] == user.pw_uid, "created-object-contents:" + path)
        if server_side:
            require(actual["gid"] == user.pw_gid and actual["mode"] == 0o600 and actual["xattrs"] == {},
                    "created-object-metadata:" + path)


def app_changes(run, phase):
    """Backing-store effects of each app phase; refuse makes its own changes through the mount."""
    if phase == "refuse":
        return dict(changed=["c02/Stale/file.txt", "c02/Changed/x.txt"],
                    moved={"c02/Replaced/x.txt": "c02/Hold/replaced-x.txt"},
                    created={"c02/Replaced/x.txt": payload(run, "c02/Replaced/x.txt")})
    deleted = {
        "delete": ["c01/Tree", "c01/Tree/a.txt", "c01/Tree/Nested", "c01/Tree/Nested/leaf.txt"],
        "interrupt": ["c04/Tree", "c04/Tree/a.txt"],
        "compete": ["c03/Tree/Arrival/z.txt", "c03/Tree/y.txt"],
        "remote": ["c05/file.txt"],
    }
    return dict(deleted=deleted.get(phase, []))


def load_manifest(args, evidence):
    checked_directory(evidence)
    manifest = load(evidence / "fixture.json")
    require(manifest["run"] == args.run and (manifest["fixture_device"], manifest["fixture_inode"]) == PINNED_ID,
            "manifest-fixture-identity")
    return manifest


def load_step(evidence, name, run):
    step = load(evidence / name)
    require(step.get("run") == run and step.get("result") == "passed", "previous-step-passed:" + name)
    return step


def app_report(args):
    require(args.app_report is not None and args.app_exit_status is not None, "copied-app-report-and-exit-status")
    # The helper writes its report before the final checks return, so a failed exit voids a passed report.
    require(args.app_exit_status == 0, "app-process-exit-status")
    path = Path(args.app_report)
    require(path.is_absolute() and path.parent.parent == SESSION and path.name == args.phase + "-report.json",
            "copied-app-report-location")
    checked_directory(path.parent)
    report = load(path)
    require(report.get("run") == args.run and report.get("phase") == args.phase, "app-report-run-and-phase")
    require(report.get("passed") is True and report.get("requiresSuccessfulProcessExit") is True,
            "app-phase-not-passed")
    require(isinstance(report.get("untested"), list) and report["untested"], "app-report-untested-gates")
    return report


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
    os.link(root / HARD_LINK[1], root / HARD_LINK[0], follow_symlinks=False)
    os.symlink(SYMLINK[1], root / SYMLINK[0])
    for name, item in inventory(root).items():
        path = root if name == "." else root / name
        info = path.lstat()
        require((info.st_dev, info.st_ino) == (item["device"], item["inode"]), "chown-task-identity")
        os.chown(path, user.pw_uid, user.pw_gid, follow_symlinks=False)
    before = inventory(root)
    require(len(before) == 1 + len(directories) + len(contents) + 2, "fixture-entry-count")
    write_new(evidence / "fixture.json", {"run": args.run, "date": now(), "before": before,
        "fixture_device": PINNED_ID[0], "fixture_inode": PINNED_ID[1], "cache": "uncontrolled",
        "endpoint": "127.0.0.1/tinymounter-m19-edit-test", "entries": len(before)})
    print(json.dumps({"prepared": True, "run": args.run, "entries": len(before)}))


def rename_exclusive(source, target, item):
    require(source.lstat().st_ino == item["inode"], "rename-source-identity")
    libc = ctypes.CDLL(None, use_errno=True)
    libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    libc.renamex_np.restype = ctypes.c_int
    if libc.renamex_np(os.fsencode(source), os.fsencode(target), RENAME_EXCL) != 0:
        raise OSError(ctypes.get_errno(), "exclusive-rename-failed")
    require(target.lstat().st_ino == item["inode"], "rename-target-identity")


def change_in_place(path, item):
    fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require((info.st_dev, info.st_ino) == (item["device"], item["inode"]) and info.st_size >= 8,
                "changed-file-identity")
        require(os.pwrite(fd, b"CHANGED!", 0) == 8, "changed-file-write")
        os.fsync(fd)
    finally:
        os.close(fd)


def create_new(path, data, user):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        os.fchown(stream.fileno(), user.pw_uid, user.pw_gid)
        os.fchmod(stream.fileno(), 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def mutate(args):
    """Another writer at the server, between two app processes, as each case requires."""
    user, root, evidence = fixture(args)
    load_manifest(args, evidence)
    previous = load_step(evidence, "audit-" + MUTATIONS[args.action] + ".json", args.run)
    current = inventory(root)
    verify(previous["after"], previous["after"], current, args.run, user)
    write_new(evidence / ("mutation-" + args.action + "-started.json"), {"run": args.run, "date": now()})
    if args.action == "compete":
        tree = root / "c03/Tree"
        moved = {"c03/Tree/Sub": "c03/Hold/Sub", "c03/Tree/replaced.txt": "c03/Hold/replaced-original.txt"}
        changed = ["c03/Tree/changed.txt"]
        created = {"c03/Tree/replaced.txt": payload(args.run, "c03/Tree/replaced.txt"),
                   "c03/Tree/Arrival/new.txt": arrival(args.run)}
        rename_exclusive(tree / "Sub", root / "c03/Hold/Sub", current["c03/Tree/Sub"])
        change_in_place(tree / "changed.txt", current["c03/Tree/changed.txt"])
        rename_exclusive(tree / "replaced.txt", root / "c03/Hold/replaced-original.txt",
                         current["c03/Tree/replaced.txt"])
        create_new(tree / "replaced.txt", created["c03/Tree/replaced.txt"], user)
        create_new(tree / "Arrival/new.txt", created["c03/Tree/Arrival/new.txt"], user)
    else:
        moved, changed = {}, []
        created = {"c05/file.txt": replacement(args.run)}
        create_new(root / "c05/file.txt", created["c05/file.txt"], user)
    after = inventory(root)
    verify(current, transformed(current, moved=moved), after, args.run, user, changed=changed, created=created,
           server_side=True)
    write_new(evidence / ("mutation-" + args.action + ".json"), {"run": args.run, "date": now(),
        "result": "passed", "after": after, "boundary": "backing-store-changes-between-app-processes",
        "created": {path: after[path]["inode"] for path in created}})
    print(json.dumps({"mutation": args.action, "run": args.run, "result": "passed"}))


def audit(args):
    user, root, evidence = fixture(args)
    manifest = load_manifest(args, evidence)
    report = app_report(args)
    index = PHASES.index(args.phase)
    if index == 0:
        baseline = manifest["before"]
    else:
        baseline = load_step(evidence, "audit-" + PHASES[index - 1] + ".json", args.run)["after"]
        if args.phase in MUTATIONS:
            baseline = load_step(evidence, "mutation-" + args.phase + ".json", args.run)["after"]
    current = inventory(root)
    changes = app_changes(args.run, args.phase)
    expected = transformed(baseline, deleted=changes.get("deleted", ()), moved=changes.get("moved"))
    verify(baseline, expected, current, args.run, user, changed=changes.get("changed", ()),
           created=changes.get("created"), smb_moved=changes.get("moved", {}).values())
    write_new(evidence / ("audit-" + args.phase + ".json"), {"run": args.run, "phase": args.phase, "date": now(),
        "result": "passed", "after": current, "app_seconds": report.get("seconds"),
        "app_connections": len(report.get("connections", [])), "app_cases": report.get("cases"),
        "app_native_identities": report.get("nativeIdentities"), "untested": report["untested"],
        "boundary": "backing store after a successful app process; the app's private evidence stays local"})
    print(json.dumps({"audit": args.phase, "run": args.run, "result": "passed"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("prepare", "audit", "compete", "replace"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--fixture-device", type=int, required=True)
    parser.add_argument("--fixture-inode", type=int, required=True)
    parser.add_argument("--phase", choices=PHASES)
    parser.add_argument("--app-report")
    parser.add_argument("--app-exit-status", type=int)
    args = parser.parse_args()
    try:
        if args.action == "audit":
            require(args.phase is not None, "audit-phase-required")
            audit(args)
        elif args.action == "prepare":
            prepare(args)
        else:
            mutate(args)
    except Exception as error:
        print(json.dumps({"result": "failed", "error": str(error)}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
