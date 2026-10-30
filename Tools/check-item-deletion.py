#!/usr/bin/env python3
"""Probe guarded permanent deletion on the approved disposable loopback SMB fixture."""
import argparse
import ctypes as C
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import signal
import stat
import struct
import subprocess
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location("in_place", Path(__file__).with_name("check-edit-in-place.py"))
in_place = importlib.util.module_from_spec(spec)
spec.loader.exec_module(in_place)
publication = in_place.publication
READ, WRITE, DELETE, ALL = in_place.READ, in_place.WRITE, in_place.DELETE, in_place.ALL
LIST, ATTRIBUTES, WRITE_ATTRIBUTES, READ_CONTROL = 0x81, 0x80, 0x100, 0x20000
READONLY, NORMAL = 0x1, 0x80
SERVER, SHARE = "127.0.0.1", "tinymounter-m19-edit-test"
MOUNT = Path("/Volumes/tinymounter-m19-edit-test")
BACKING = Path("/Users/Shared/tinymounter-m19-edit-fixture")
TREE = re.compile(r"probe-[0-9a-f]{32}-deletion")
COMPONENT = re.compile(r"probe-[a-z0-9-]+")
SIZE = 65792
STREAM = ":m19-probe:$DATA"
NEIGHBORS = ("neighbor-file", "neighbor-folder", "neighbor-child")
CHECKPOINTS = ("protected", "marked", "closed")
# Lost-reply scenario: object kind, last step before SIGKILL, and the only accepted recovery.
RECOVERY = {"protected": ("file", "protected", "retried_and_deleted"),
            "marked": ("file", "marked", "absent_unconfirmed"),
            "closed": ("file", "closed", "absent_unconfirmed"),
            "moved-out": ("file", "protected", "absent_unconfirmed"),
            "replaced": ("file", "protected", "new_occupant"),
            "moved-within": ("file", "protected", "moved_within_parent"),
            "changed-after": ("file", "protected", "changed"),
            "stream-after": ("file", "protected", "changed"),
            "folder-protected": ("directory", "protected", "retried_and_deleted"),
            "folder-marked": ("directory", "marked", "absent_unconfirmed"),
            "folder-closed": ("directory", "closed", "absent_unconfirmed")}
COMPETITORS = ("moved-out", "replaced", "moved-within", "changed-after", "stream-after")
ARRIVALS = ("pending-child", "stale-listing")
STATUS = {0xC000000D: "invalid_parameter", 0xC0000022: "access_denied", 0xC0000034: "name_not_found",
          0xC0000035: "name_collision", 0xC000003A: "path_not_found", 0xC0000043: "sharing_violation",
          0xC0000056: "delete_pending", 0xC00000BA: "file_is_a_directory", 0xC00000BB: "not_supported",
          0xC0000101: "directory_not_empty", 0xC0000103: "not_a_directory", 0xC0000121: "cannot_delete",
          0xC0000128: "file_closed"}
SETTLING = ("sharing_violation", "delete_pending")
NATIVE_REFUSAL = "errno_EBUSY"


class Client(in_place.Client):
    def listing(self, directory):
        entries, restart = {}, 1
        for _ in range(64):
            buffer = (C.c_ubyte * 65536)()
            count, finished = C.c_uint32(), C.c_int()
            error = self.library.probe_list(self.context, directory, restart, buffer, len(buffer),
                                            C.byref(count), C.byref(finished))
            if error:
                raise OSError(error, "list fixture directory")
            if finished.value:
                return entries
            restart, data, offset = 0, bytes(buffer[:count.value]), 0
            while True:
                if offset + 80 > len(data):
                    raise ValueError("invalid fixture directory entry")
                next_offset = struct.unpack_from("<I", data, offset)[0]
                size = struct.unpack_from("<I", data, offset + 60)[0]
                if size % 2 or offset + 80 + size > len(data):
                    raise ValueError("invalid fixture entry length")
                name = data[offset + 80:offset + 80 + size].decode("utf-16-le")
                if name not in (".", ".."):
                    if name in entries:
                        raise ValueError("repeated fixture directory entry")
                    birth = struct.unpack_from("<Q", data, offset + 8)[0] // 10 - 11644473600000000
                    entries[name] = [struct.unpack_from("<Q", data, offset + 72)[0], birth]
                if not next_offset:
                    break
                if next_offset < 80 + size or next_offset > len(data) - offset:
                    raise ValueError("invalid fixture entry offset")
                offset += next_offset
        raise ValueError("fixture directory listing did not finish")

    def delete(self, handle):
        error = self.library.probe_delete(self.context, handle)
        if error:
            raise OSError(error, "mark fixture item for deletion")

    def streams(self, handle):
        data, offset, result = self.metadata(handle, False), 0, []
        while data:
            if offset + 24 > len(data):
                raise ValueError("incomplete fixture stream information")
            next_offset, length, size, _ = struct.unpack_from("<IIQQ", data, offset)
            if length % 2 or offset + 24 + length > len(data):
                raise ValueError("invalid fixture stream information")
            result.append([data[offset + 24:offset + 24 + length].decode("utf-16-le"), size])
            if not next_offset:
                break
            if next_offset < 24 + length:
                raise ValueError("invalid fixture stream offset")
            offset += next_offset
        return sorted(result)

    def attributes(self, handle, value):
        self.set_metadata(handle, struct.pack("<QQQQII", 0, 0, 0, 0, value, 0), False)


def tracked(method):
    """Attach the exact NTSTATUS at failure, before a cleanup request replaces the last status."""
    def call(self, *args, **kwargs):
        self.library.probe_clear_status()
        try:
            return method(self, *args, **kwargs)
        except OSError as error:
            if not hasattr(error, "status"):
                error.status = self.library.probe_status()
            raise
    return call


for name in ("open", "close", "directory", "info", "read", "metadata", "set_metadata", "create_stream",
             "stream", "listing", "delete"):
    setattr(Client, name, tracked(getattr(Client, name)))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(report, key, condition):
    report[key] = bool(condition)
    if not condition:
        raise AssertionError(key)


def status_label(status, code=None):
    if status:
        return STATUS.get(status, "0x%08x" % status)
    return "errno_" + errno.errorcode.get(code, str(code))


def failure(error):
    if isinstance(error, OSError):
        return status_label(getattr(error, "status", 0), error.errno)
    return type(error).__name__


def outcome(operation):
    try:
        operation()
        return "ok"
    except OSError as error:
        return failure(error)


def settled(operation, transient, seconds=20):
    """Retry only while a killed probe session may still hold its handles on the server."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            return operation()
        except OSError as error:
            state = STATUS.get(getattr(error, "status", 0))
            if state not in SETTLING or time.monotonic() > deadline:
                raise
            transient.append(state)
            time.sleep(0.5)


def inside(path):
    parts = path.split("/")
    if len(parts) > 5 or not TREE.fullmatch(parts[0]) or not all(COMPONENT.fullmatch(part) for part in parts):
        raise ValueError("path outside the probe subtree")
    return path


def backing(path):
    parts = inside(path).split("/")
    for depth in range(1, len(parts)):
        if not stat.S_ISDIR(os.lstat(BACKING.joinpath(*parts[:depth])).st_mode):
            raise ValueError("probe ancestor is not a directory")
    return BACKING.joinpath(*parts)


def native(path):
    return MOUNT.joinpath(*inside(path).split("/"))


def ancestry(path):
    parts = inside(path).split("/")
    return [""] + ["/".join(parts[:depth]) for depth in range(1, len(parts) + 1)]


def write_private(path, value):
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def lookup(client, path, directory=False):
    opener = client.directory if directory else client.open
    return outcome(lambda: client.close(opener(path, ATTRIBUTES, ALL)))


def proves(client, handle, item):
    """Accept only the recorded single-link object with its complete recorded contents, or an empty folder."""
    values = client.info(handle)
    if values[:2] != item["identity"]:
        return False
    if item["kind"] == "directory":
        return client.listing(handle) == {}
    return (values[3] == 1 and digest(client.read(handle)) == item["sha256"]
            and client.streams(handle) == item["streams"])


def gone(client, item):
    """Require the exact not-found status and no recorded identity in a complete parent listing."""
    parent = client.directory(item["path"].rpartition("/")[0])
    try:
        absent = lookup(client, item["path"], item["kind"] == "directory") == "name_not_found"
        return absent and item["identity"] not in client.listing(parent).values()
    finally:
        client.close(parent)


def protect(client, item):
    if item["kind"] == "directory":
        return client.directory(item["path"], DELETE | LIST, 0)
    return client.open(item["path"], READ | DELETE, 0)


def remove(client, item):
    """Delete one recorded object through a deny-all handle after proving it under that handle."""
    handle = protect(client, item)
    try:
        proven = proves(client, handle, item)
        if proven:
            client.delete(handle)
    finally:
        client.close(handle)
    if not proven:
        return "not_proved"
    if not gone(client, item):
        return "uncertain"
    item["state"] = "gone"
    return "deleted"


def load(path, keychain):
    library = publication.load(path, True, keychain)
    pointer = C.POINTER(C.c_ubyte)
    library.probe_list.argtypes = [C.c_void_p, pointer, C.c_int, pointer, C.c_uint32,
                                   C.POINTER(C.c_uint32), C.POINTER(C.c_int)]
    library.probe_list.restype = C.c_int
    library.probe_clear_status.argtypes, library.probe_clear_status.restype = [], None
    return library


def recover(library, intent, transient):
    """Classify a deletion with a lost reply from its durable intent and fresh SMB evidence only."""
    client = Client(library)
    try:
        guards = [client.directory(path) for path in ancestry(intent["parent"])]
        if client.info(guards[-1])[:2] != intent["parent_identity"]:
            return "parent_changed"
        try:
            handle = settled(lambda: protect(client, intent), transient)
        except OSError as error:
            state = failure(error)
            if state != "name_not_found":
                return "unresolved_" + state
            # Absence cannot distinguish deletion from a move out of the parent.
            moved = intent["identity"] in client.listing(guards[-1]).values()
            return "moved_within_parent" if moved else "absent_unconfirmed"
        identity = client.info(handle)[:2]
        proven = identity == intent["identity"] and proves(client, handle, intent)
        if proven:
            client.delete(handle)
        client.close(handle)
        if identity != intent["identity"]:
            return "new_occupant"
        if not proven:
            return "changed"
        return "retried_and_deleted" if gone(client, intent) else "retry_uncertain"
    finally:
        client.disconnect()


def crash(args):
    if not args.crash_intent.name.startswith("deletion-intent-"):
        raise SystemExit("unexpected deletion intent")
    intent = json.loads(args.crash_intent.read_text())
    if intent["kind"] not in ("file", "directory"):
        raise SystemExit("unexpected intent kind")
    if inside(intent["path"]).rpartition("/")[0] != inside(intent["parent"]):
        raise SystemExit("intent path outside its parent")
    library = load(args.library, args.fixture_keychain)
    client = Client(library)
    guards = [client.directory(path) for path in ancestry(intent["parent"])]
    handle = protect(client, intent)
    if client.info(guards[-1])[:2] != intent["parent_identity"] or not proves(client, handle, intent):
        raise SystemExit("recorded object not proved")
    if args.crash_at != "protected":
        client.delete(handle)
    if args.crash_at == "closed":
        client.close(handle)
    os.kill(os.getpid(), signal.SIGKILL)


def cleanup(library, evidence):
    """Remove only recorded probe objects, newest first, each after fresh identity and content proof."""
    result = {"performed": True, "removed": 0, "already_absent": 0, "retained": []}
    client = Client(library)
    try:
        for item in reversed(evidence.items):
            if item["state"] == "gone":
                continue
            found = lookup(client, item["path"], item["kind"] == "directory")
            if found == "name_not_found" and item["state"] == "unconfirmed":
                result["already_absent"] += 1
                continue
            try:
                action = remove(client, item) if found == "ok" else "lookup_" + found
            except (OSError, ValueError) as error:
                action = "failed_" + failure(error)
            if action == "deleted":
                result["removed"] += 1
            else:
                result["retained"].append([item["label"], action])
            evidence.save()
    finally:
        client.disconnect()
    result["complete"] = not result["retained"]
    return result


def command(args):
    return [sys.executable, str(Path(__file__).resolve()), "--library", str(args.library),
            "--fixture-keychain", str(args.fixture_keychain), "--evidence-dir", str(args.evidence_dir),
            "--expect-server", args.expect_server, "--expect-share", args.expect_share,
            "--fixture-root", str(args.fixture_root), "--backing-root", str(args.backing_root)]


class Evidence:
    def __init__(self, directory, report):
        self.directory, self.report, self.items = directory, report, []

    def save(self):
        write_private(self.directory / "result.json", self.report)
        write_private(self.directory / "ledger.json", self.items)

    def add(self, client, label, path, kind, payload=None):
        handle = client.directory(path) if kind == "directory" else client.open(path)
        try:
            return self.record(client, handle, label, path, kind, payload)
        finally:
            client.close(handle)

    def record(self, client, handle, label, path, kind, payload=None):
        """Ledger an object only with the identity, single link and contents proved under its handle."""
        values = client.info(handle)
        item = {"label": label, "path": path, "kind": kind, "identity": values[:2], "state": "present"}
        if kind == "file":
            if values[3] != 1 or client.read(handle) != payload:
                raise ValueError("fixture file not proved for the ledger")
            item.update(sha256=digest(payload), streams=client.streams(handle))
        self.items.append(item)
        self.save()
        return item

    def item(self, label):
        return next(item for item in self.items if item["label"] == label)

    def move(self, old, new):
        for item in self.items:
            if item["state"] != "gone" and (item["path"] == old or item["path"].startswith(old + "/")):
                item["path"] = new + item["path"][len(old):]
        self.save()


class Probe:
    def __init__(self, args, library, evidence):
        self.args, self.library, self.evidence, self.report = args, library, evidence, evidence.report
        self.tree = "probe-" + uuid.uuid4().hex + "-deletion"
        self.shared = self.tree + "/probe-shared"
        self.a = self.b = self.baseline = None

    def gate(self, name):
        if name not in self.report["open_gates"]:
            self.report["open_gates"].append(name)

    def create_folder(self, path, label):
        # The fixture's SMB users need write access to folders that the local test user creates.
        os.mkdir(backing(path), 0o777)
        os.chmod(backing(path), 0o777)
        return self.evidence.add(self.a, label, path, "directory")

    def create_file(self, path, label, payload):
        # Server-local setup keeps native SMB caches from holding names that the probe later deletes.
        publication.native_write(backing(path), payload, True)
        os.chmod(backing(path), 0o666)
        return self.evidence.add(self.a, label, path, "file", payload)

    def prepare(self):
        """Create every fixed folder before the native client first lists the tree and leases it."""
        t, shared = self.tree, self.shared
        folders = [("tree", t), ("shared", shared), ("neighbor-folder", shared + "/probe-neighbor-folder"),
                   ("empty-folder", shared + "/probe-empty")]
        folders += [(name + "-folder", t + "/probe-" + name)
                    for name in ("stream-race", "in-use", "shared-handle", "changed", "read-only")]
        for name in ARRIVALS:
            folders += [(name + "-case", t + "/probe-" + name), (name, t + "/probe-" + name + "/probe-target")]
        folders += [("nonempty-case", t + "/probe-nonempty"), ("nonempty", t + "/probe-nonempty/probe-target"),
                    ("nonempty-sub", t + "/probe-nonempty/probe-target/probe-sub"),
                    ("parent-folder", t + "/probe-parent"), ("crash-elsewhere", t + "/probe-crash-elsewhere")]
        for scenario, (kind, _, _) in RECOVERY.items():
            folders.append(("crash-" + scenario + "-folder", t + "/probe-crash-" + scenario))
            if kind == "directory":
                folders.append(("crash-" + scenario, t + "/probe-crash-" + scenario + "/probe-item"))
        for label, path in folders:
            self.create_folder(path, label)

    def folder(self, label):
        return self.evidence.item(label)

    def refresh_streams(self, label):
        item = self.evidence.item(label)
        handle = self.a.open(item["path"])
        item["streams"] = self.a.streams(handle)
        self.a.close(handle)
        self.evidence.save()
        return item

    def guard(self, path):
        return [self.a.directory(ancestor) for ancestor in ancestry(path)]

    def release(self, guards):
        for handle in guards:
            self.a.close(handle)

    def retained(self, item):
        if item["kind"] == "directory":
            handle = self.a.directory(item["path"])
            kept = self.a.info(handle)[:2] == item["identity"]
        else:
            handle = self.a.open(item["path"], READ, 1)
            kept = proves(self.a, handle, item)
        self.a.close(handle)
        return kept

    def native_visible(self, item):
        """A native refusal counts only after the native client lists the object with its type and size."""
        parent, _, name = item["path"].rpartition("/")
        listed = name in os.listdir(native(parent))
        info = os.lstat(native(item["path"]))
        if item["kind"] == "directory":
            return listed and stat.S_ISDIR(info.st_mode)
        return listed and stat.S_ISREG(info.st_mode) and info.st_size == SIZE

    def bind(self):
        r, a = self.report, self.a
        tree = self.folder("tree")
        path = self.tree + "/probe-sentinel"
        sentinel = os.urandom(32)
        item = self.create_file(path, "sentinel", sentinel)
        for parent, child in (("", tree), (self.tree, item)):
            handle = a.directory(parent)
            listed = a.listing(handle).get(child["path"].rpartition("/")[2])
            a.close(handle)
            require(r, "listing_identity_matches_handle_" + child["label"], listed == child["identity"])
        require(r, "backing_matches_share", self.retained(item))
        require(r, "backing_matches_mount", native(path).read_bytes() == sentinel)

    def snapshot(self):
        """Capture complete bytes, attached data, permissions and identity of the untouched neighbors."""
        result = {}
        for name in NEIGHBORS:
            item = self.evidence.item(name)
            local = os.lstat(backing(item["path"]))
            entry = {"mode": stat.S_IMODE(local.st_mode), "owner": [local.st_uid, local.st_gid]}
            if item["kind"] == "directory":
                handle = self.a.directory(item["path"], LIST | READ_CONTROL, 3)
                entry["listing"] = self.a.listing(handle)
            else:
                if not stat.S_ISREG(local.st_mode):
                    raise ValueError("neighbor is not a regular file")
                handle = self.a.open(item["path"], READ, 1)
                entry.update(contents=digest(self.a.read(handle)), streams=self.a.streams(handle),
                             backing=digest(backing(item["path"]).read_bytes()))
            entry.update(identity=self.a.info(handle)[:2], dacl=digest(in_place.dacl(self.a.metadata(handle, True))))
            self.a.close(handle)
            if any(stream == STREAM for stream, _ in entry.get("streams", [])):
                handle = self.a.stream(item["path"])
                entry["stream"] = digest(self.a.read(handle))
                self.a.close(handle)
            result[name] = entry
        return result

    def record_neighbors(self):
        path = self.shared + "/probe-neighbor-file"
        self.create_file(path, "neighbor-file", in_place.contents(b"neighbor", SIZE))
        self.b.close(self.b.create_stream(path))
        self.refresh_streams("neighbor-file")
        folder = self.folder("neighbor-folder")
        self.create_file(folder["path"] + "/probe-neighbor-child", "neighbor-child", in_place.contents(b"child", SIZE))
        self.baseline = self.snapshot()
        write_private(self.args.evidence_dir / "neighbors-baseline.json", self.baseline)

    def ordinary_file(self):
        r, a, b = self.report, self.a, self.b
        path = self.shared + "/probe-item"
        item = self.create_file(path, "file", in_place.contents(b"item", SIZE))
        created = len(item["streams"])
        b.close(b.create_stream(path))
        item = self.refresh_streams("file")
        require(r, "file_has_attached_stream", len(item["streams"]) == created + 1)
        require(r, "file_native_visible", self.native_visible(item))
        guards = self.guard(self.shared)
        handle = a.open(path, READ | DELETE, 0)
        require(r, "file_proved_under_deny_all", proves(a, handle, item))
        for name, access in (("reader", READ), ("writer", WRITE), ("deleter", DELETE)):
            r["file_guard_" + name] = outcome(lambda: b.close(b.open(path, access, ALL)))
            require(r, "file_guard_denies_" + name, r["file_guard_" + name] == "sharing_violation")
        r["file_guard_native_unlink"] = outcome(lambda: os.unlink(native(path)))
        moved = native(self.shared + "/probe-moved")
        r["file_guard_native_rename"] = outcome(lambda: os.rename(native(path), moved))
        require(r, "file_guard_denies_native_changes",
                r["file_guard_native_unlink"] == r["file_guard_native_rename"] == NATIVE_REFUSAL)
        require(r, "file_unchanged_under_guard", proves(a, handle, item))
        a.delete(handle)
        r["file_lookup_while_pending"] = lookup(b, path)
        code = publication.attempt(lambda: b.close(b.open(path, ATTRIBUTES, ALL)))
        r["file_pending_errno"] = errno.errorcode.get(code, str(code))
        r["file_listed_while_pending"] = "probe-item" in a.listing(guards[-1])
        a.close(handle)
        require(r, "file_removed_with_identity_absent", gone(a, item))
        item["state"] = "gone"
        r["file_stream_after_removal"] = outcome(lambda: b.close(b.stream(path)))
        require(r, "file_stream_removed", r["file_stream_after_removal"] in ("name_not_found", "path_not_found"))
        require(r, "file_backing_entries_removed",
                not set(os.listdir(backing(self.shared))) & {"probe-item", "._probe-item"})
        recreated = self.create_file(path, "file-recreated", in_place.contents(b"recreated", SIZE))
        require(r, "recreated_name_has_no_old_stream", all(name != STREAM for name, _ in recreated["streams"]))
        self.release(guards)

    def empty_folder(self):
        r, a, b = self.report, self.a, self.b
        folder = self.folder("empty-folder")
        path = folder["path"]
        require(r, "folder_native_visible", self.native_visible(folder))
        guards = self.guard(self.shared)
        handle = a.directory(path, DELETE | LIST, 0)
        require(r, "folder_proved_empty_under_deny_all", proves(a, handle, folder))
        r["folder_guard_rename_open"] = outcome(lambda: b.close(b.directory(path, DELETE, ALL)))
        r["folder_guard_list_open"] = outcome(lambda: b.close(b.directory(path)))
        r["folder_guard_native_rmdir"] = outcome(lambda: os.rmdir(native(path)))
        require(r, "folder_guard_denies_competitors",
                r["folder_guard_rename_open"] == r["folder_guard_list_open"] == "sharing_violation"
                and r["folder_guard_native_rmdir"] == NATIVE_REFUSAL)
        a.delete(handle)
        r["folder_lookup_while_pending"] = lookup(b, path, True)
        r["folder_listed_while_pending"] = "probe-empty" in a.listing(guards[-1])
        a.close(handle)
        require(r, "folder_removed_with_identity_absent", gone(a, folder))
        folder["state"] = "gone"
        self.release(guards)

    def stream_race(self):
        r, a, b = self.report, self.a, self.b
        folder = self.folder("stream-race-folder")
        path = folder["path"] + "/probe-item"
        item = self.create_file(path, "stream-race", in_place.contents(b"race", SIZE))
        guards = self.guard(folder["path"])
        handle = a.open(path, READ | DELETE, 0)
        require(r, "stream_race_proved", proves(a, handle, item))
        r["stream_create_under_guard"] = outcome(lambda: b.close(b.create_stream(path)))
        r["stream_change_visible_to_guard"] = a.streams(handle) != item["streams"]
        a.close(handle)
        if r["stream_create_under_guard"] == "ok":
            # A change after the final check would be deleted with the file.
            self.gate("attached_data_change_during_deletion")
            handle = b.stream(path)
            require(r, "stream_race_stream_retained", b.read(handle) == in_place.STREAM_CONTENTS)
            b.close(handle)
            item = self.refresh_streams("stream-race")
        require(r, "stream_race_item_retained", self.retained(item))
        self.release(guards)

    def in_use(self):
        r, a, b = self.report, self.a, self.b
        folder = self.folder("in-use-folder")
        path = folder["path"] + "/probe-item"
        item = self.create_file(path, "in-use", in_place.contents(b"in-use", SIZE))
        for name, access, sharing in (("reader", READ, ALL), ("writer", WRITE, ALL), ("deleter", DELETE, ALL),
                                      ("reader_without_delete_sharing", READ, 1)):
            holder = b.open(path, access, sharing)
            r["in_use_" + name] = outcome(lambda: a.close(a.open(path, READ | DELETE, 0)))
            b.close(holder)
            require(r, "in_use_" + name + "_refused", r["in_use_" + name] == "sharing_violation")
        require(r, "in_use_item_retained", self.retained(item))

        path = folder["path"] + "/probe-competitor"
        item = self.create_file(path, "competitor-deleted", in_place.contents(b"competitor", SIZE))
        holder = b.open(path, DELETE | ATTRIBUTES, ALL)
        require(r, "competitor_identity_proved", b.info(holder)[:2] == item["identity"])
        b.delete(holder)
        r["competitor_pending_protected_open"] = outcome(lambda: a.close(a.open(path, READ | DELETE, 0)))
        require(r, "competitor_pending_refused", r["competitor_pending_protected_open"] in SETTLING)
        b.close(holder)
        require(r, "competitor_deletion_completed", gone(a, item))
        item["state"] = "gone"

    def shared_handle(self):
        r, a, b = self.report, self.a, self.b
        folder = self.folder("shared-handle-folder")
        path = folder["path"] + "/probe-item"
        item = self.create_file(path, "shared-handle", in_place.contents(b"shared", SIZE))
        guards = self.guard(folder["path"])
        reader = b.open(path, READ, ALL)
        handle = a.open(path, READ | DELETE, 1)
        require(r, "shared_handle_proved", proves(a, handle, item))
        a.delete(handle)
        a.close(handle)
        r["shared_handle_lookup_after_own_close"] = lookup(a, path)
        r["shared_handle_listed_after_own_close"] = "probe-item" in a.listing(guards[-1])
        require(r, "shared_handle_reader_sees_complete_contents", digest(b.read(reader)) == item["sha256"])
        b.close(reader)
        require(r, "shared_handle_removed_after_last_close", gone(a, item))
        item["state"] = "gone"
        self.release(guards)

    def changed(self):
        r, a = self.report, self.a
        folder = self.folder("changed-folder")
        path = folder["path"] + "/probe-same-object"
        item = self.create_file(path, "same-object", in_place.contents(b"before", SIZE))
        replaced = folder["path"] + "/probe-replaced"
        payload = in_place.contents(b"replaced", SIZE)
        original = self.create_file(replaced, "replaced-original", payload)
        require(r, "replaced_native_visible", self.native_visible(original))
        guards = self.guard(folder["path"])
        changed = in_place.contents(b"after!", SIZE)
        # Same-size bytes written in place keep the identity; only the complete digest refuses them.
        publication.native_write(backing(path), changed)
        handle = a.open(path, READ | DELETE, 0)
        r["changed_identity_retained"] = a.info(handle)[:2] == item["identity"]
        require(r, "changed_contents_refused", not proves(a, handle, item))
        a.close(handle)
        item["sha256"] = digest(changed)
        require(r, "changed_object_retained", self.retained(item))

        os.rename(native(replaced), native(folder["path"] + "/probe-previous"))
        self.evidence.move(replaced, folder["path"] + "/probe-previous")
        occupant = self.create_file(replaced, "replaced-occupant", payload)
        require(r, "replacement_has_new_identity", occupant["identity"] != original["identity"])
        handle = a.open(replaced, READ | DELETE, 0)
        r["replacement_bytes_identical"] = digest(a.read(handle)) == original["sha256"]
        require(r, "replacement_refused", not proves(a, handle, original))
        a.close(handle)
        require(r, "replacement_both_retained", self.retained(original) and self.retained(occupant))
        self.release(guards)

    def read_only(self):
        r, a = self.report, self.a
        folder = self.folder("read-only-folder")
        path = folder["path"] + "/probe-item"
        item = self.create_file(path, "read-only", in_place.contents(b"read-only", SIZE))
        handle = a.open(path, READ | WRITE_ATTRIBUTES, ALL)
        try:
            r["read_only_attribute_change"] = outcome(lambda: a.attributes(handle, READONLY))
            require(r, "read_only_attribute_set", a.info(handle)[4] & READONLY)
        finally:
            a.close(handle)
        guards = self.guard(folder["path"])

        def delete():
            handle = a.open(path, READ | DELETE, 0)
            try:
                if not proves(a, handle, item):
                    raise ValueError("read-only item changed before deletion")
                a.delete(handle)
            finally:
                a.close(handle)
        r["read_only_delete"] = outcome(delete)
        if r["read_only_delete"] == "ok":
            require(r, "read_only_removed", gone(a, item))
            item["state"] = "gone"
        else:
            handle = a.open(path, READ | WRITE_ATTRIBUTES, ALL)
            a.attributes(handle, NORMAL)
            a.close(handle)
            require(r, "read_only_item_retained", self.retained(item))
        self.release(guards)

    def arrival(self, name, before_mark):
        """A child that arrives after the emptiness proof must survive; nothing deletes recursively."""
        r, a, b = self.report, self.a, self.b
        key = name.replace("-", "_")
        case, target = self.folder(name + "-case"), self.folder(name)
        child = target["path"] + "/probe-arrival"
        guards = self.guard(case["path"])
        handle = a.directory(target["path"], DELETE | LIST, 0)
        require(r, key + "_proved_empty", proves(a, handle, target))
        if not before_mark:
            r[key + "_mark"] = outcome(lambda: a.delete(handle))
            require(r, key + "_marked_before_arrival", r[key + "_mark"] == "ok")
        created = []
        r[key + "_smb_child"] = outcome(lambda: created.append(b.open(child, READ | WRITE, ALL, True)))
        r[key + "_child_created"] = None
        if created:
            r[key + "_child_created"] = "smb"
            self.evidence.save()
            try:
                self.evidence.record(b, created[0], name + "-child", child, "file", b"")
            finally:
                b.close(created[0])
        else:
            payload = in_place.contents(name.encode(), SIZE)
            r[key + "_local_child"] = outcome(lambda: publication.native_write(backing(child), payload, True))
            if r[key + "_local_child"] == "ok":
                r[key + "_child_created"] = "local"
                self.evidence.save()
                self.evidence.add(b, name + "-child", child, "file", payload)
        if before_mark:
            r[key + "_mark"] = outcome(lambda: a.delete(handle))
        r[key + "_close"] = outcome(lambda: a.close(handle))
        if r[key + "_child_created"]:
            arrived = self.evidence.item(name + "-child")
            require(r, key + "_child_and_folder_retained", self.retained(arrived) and self.retained(target))
        else:
            require(r, key + "_removed_when_empty", gone(a, target))
            target["state"] = "gone"
        self.release(guards)

    def nonempty(self):
        r, a = self.report, self.a
        case, target, sub = self.folder("nonempty-case"), self.folder("nonempty"), self.folder("nonempty-sub")
        child = self.create_file(target["path"] + "/probe-child", "nonempty-child", in_place.contents(b"child", SIZE))
        grandchild = self.create_file(sub["path"] + "/probe-grandchild", "nonempty-grandchild",
                                      in_place.contents(b"grandchild", SIZE))
        guards = self.guard(case["path"])
        handle = a.directory(target["path"], DELETE | LIST, 0)
        require(r, "nonempty_identity_proved", a.info(handle)[:2] == target["identity"])
        require(r, "nonempty_listing_complete",
                a.listing(handle) == {"probe-child": child["identity"], "probe-sub": sub["identity"]})
        # Deliberately marks a populated folder to classify the server's own refusal.
        r["nonempty_mark"] = outcome(lambda: a.delete(handle))
        r["nonempty_close"] = outcome(lambda: a.close(handle))
        require(r, "nonempty_tree_retained", all(self.retained(item) for item in (target, child, sub, grandchild)))
        self.release(guards)

    def parent(self):
        r, a, b = self.report, self.a, self.b
        case = self.folder("parent-folder")
        path = case["path"] + "/probe-item"
        payload = in_place.contents(b"parent", SIZE)
        original = self.create_file(path, "parent-item", payload)
        require(r, "parent_native_visible", self.native_visible(case))
        guards = self.guard(case["path"])
        r["parent_rename_open_under_guard"] = outcome(lambda: b.close(b.directory(case["path"], DELETE, ALL)))
        r["parent_native_rename_under_guard"] = outcome(
            lambda: os.rename(native(case["path"]), native(case["path"] + "-moved")))
        require(r, "parent_guard_denies_replacement",
                r["parent_rename_open_under_guard"] == "sharing_violation"
                and r["parent_native_rename_under_guard"] == NATIVE_REFUSAL)
        require(r, "parent_identity_retained", a.info(guards[-1])[:2] == case["identity"])
        self.release(guards)

        previous = self.tree + "/probe-parent-previous"
        os.rename(native(case["path"]), native(previous))
        self.evidence.move(case["path"], previous)
        replacement = self.create_folder(self.tree + "/probe-parent", "parent-replacement")
        occupant = self.create_file(path, "parent-occupant", payload)
        guards = self.guard(replacement["path"])
        require(r, "replaced_parent_refused", a.info(guards[-1])[:2] != case["identity"])
        self.release(guards)
        require(r, "replaced_parent_items_retained",
                all(self.retained(item) for item in (case, original, replacement, occupant)))

    def compete(self, scenario, item, case, elsewhere, payload):
        """Act as another client on the unprotected object after the probe process died."""
        settled(lambda: self.b.close(self.b.open(item["path"], READ | DELETE, 0)), [])
        if scenario == "changed-after":
            changed = in_place.contents(b"changed", SIZE)
            publication.native_write(backing(item["path"]), changed)
            item["sha256"] = digest(changed)
            return
        if scenario == "stream-after":
            self.b.close(self.b.create_stream(item["path"]))
            self.refresh_streams(item["label"])
            return
        old = item["path"]
        if scenario == "moved-within":
            target = case["path"] + "/probe-renamed"
        else:
            target = elsewhere["path"] + "/probe-" + scenario
        require(self.report, "crash_" + scenario.replace("-", "_") + "_native_visible", self.native_visible(item))
        os.rename(native(old), native(target))
        self.evidence.move(old, target)
        if scenario == "replaced":
            self.create_file(old, "crash-replaced-occupant", payload)

    def interrupted(self):
        r = self.report
        elsewhere = self.folder("crash-elsewhere")
        for scenario, (kind, checkpoint, expected) in RECOVERY.items():
            key = "crash_" + scenario.replace("-", "_")
            case = self.folder("crash-" + scenario + "-folder")
            path = case["path"] + "/probe-item"
            payload = in_place.contents(scenario.encode(), SIZE)
            if kind == "directory":
                item = self.folder("crash-" + scenario)
            else:
                item = self.create_file(path, "crash-" + scenario, payload)
            intent = {"path": path, "parent": case["path"], "parent_identity": case["identity"], "kind": kind,
                      "identity": item["identity"]}
            if kind == "file":
                intent.update(sha256=item["sha256"], streams=item["streams"])
            intent_path = self.args.evidence_dir / ("deletion-intent-" + scenario + ".json")
            write_private(intent_path, intent)
            with (self.args.evidence_dir / ("crash-" + scenario + ".stderr")).open("xb") as errors:
                arguments = ["--crash-at", checkpoint, "--crash-intent", str(intent_path)]
                child = subprocess.run(command(self.args) + arguments, stdout=subprocess.DEVNULL,
                                       stderr=errors, timeout=180)
            r[key + "_exit"] = child.returncode
            require(r, key + "_killed_at_checkpoint", child.returncode == -signal.SIGKILL)
            if checkpoint != "protected":
                item["state"] = "unconfirmed"
            if scenario in COMPETITORS:
                self.compete(scenario, item, case, elsewhere, payload)
            transient = []
            r[key + "_recovery"] = recover(self.library, intent, transient)
            r[key + "_settling"] = sorted(set(transient))
            if r[key + "_recovery"] == "absent_unconfirmed":
                self.gate("lost_reply_absence_unprovable")
            require(r, key + "_recovery_matches_evidence", r[key + "_recovery"] == expected)
            if r[key + "_recovery"] == "retried_and_deleted":
                item["state"] = "gone"
            elif scenario in COMPETITORS:
                require(r, key + "_object_retained", self.retained(item))
            if scenario == "replaced":
                require(r, key + "_occupant_retained", self.retained(self.evidence.item("crash-replaced-occupant")))
            if scenario == "moved-out":
                r["absence_does_not_prove_deletion"] = True
            self.evidence.save()

    def folders_match_ledger(self):
        """Each probe folder lists exactly its recorded present objects; nothing else vanished or arrived."""
        for folder in self.evidence.items:
            if folder["kind"] != "directory" or folder["state"] != "present":
                continue
            expected = {item["path"].rpartition("/")[2]: item["identity"] for item in self.evidence.items
                        if item["state"] == "present" and item["path"].rpartition("/")[0] == folder["path"]}
            handle = self.a.directory(folder["path"])
            listed = self.a.listing(handle)
            self.a.close(handle)
            if listed != expected:
                return False
        return True

    def untouched(self):
        ending = self.snapshot()
        write_private(self.args.evidence_dir / "neighbors-ending.json", ending)
        require(self.report, "neighbors_unchanged", ending == self.baseline)
        require(self.report, "folders_match_ledger", self.folders_match_ledger())

    def run(self):
        steps = (("prepare", self.prepare), ("binding", self.bind), ("neighbors", self.record_neighbors),
                 ("file", self.ordinary_file), ("empty-folder", self.empty_folder),
                 ("stream-race", self.stream_race), ("in-use", self.in_use),
                 ("shared-handle", self.shared_handle), ("changed", self.changed), ("read-only", self.read_only),
                 ("pending-child", lambda: self.arrival("pending-child", False)),
                 ("stale-listing", lambda: self.arrival("stale-listing", True)),
                 ("nonempty", self.nonempty), ("parent", self.parent), ("interrupted", self.interrupted),
                 ("untouched", self.untouched))
        try:
            self.a = Client(self.library)
            self.b = Client(self.library)
            for name, step in steps:
                self.report["case"] = name
                step()
                self.evidence.save()
            self.report["passed"] = True
        except Exception as error:
            # Any failure only saves its evidence; the run then keeps every object and fails.
            self.report["failure"] = str(error) if isinstance(error, AssertionError) else type(error).__name__
            self.report["failure_status"] = failure(error)
        finally:
            for client in (self.a, self.b):
                if client:
                    client.disconnect()
        # A failed probe keeps every object for inspection instead of cleaning up past the failure.
        self.report["cleanup"] = {"performed": False}
        if self.report["passed"]:
            try:
                self.report["cleanup"] = cleanup(self.library, self.evidence)
            except Exception as error:
                self.report["cleanup"] = {"performed": "interrupted", "failure_status": failure(error)}
        if not self.report["cleanup"].get("complete"):
            self.report["cleanup"]["remaining"] = [item["label"] for item in self.evidence.items
                                                   if item["state"] != "gone"]
        self.evidence.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-keychain", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--expect-server", required=True)
    parser.add_argument("--expect-share", required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--backing-root", type=Path, required=True)
    parser.add_argument("--crash-at", choices=CHECKPOINTS)
    parser.add_argument("--crash-intent", type=Path)
    args = parser.parse_args()
    if (args.expect_server, args.expect_share, args.fixture_root, args.backing_root) != (SERVER, SHARE, MOUNT, BACKING):
        parser.error("requires the approved loopback endpoint, share, mount and backing folder")
    if (args.crash_at is None) != (args.crash_intent is None):
        parser.error("--crash-at and --crash-intent go together")
    if os.path.islink(BACKING) or not BACKING.is_dir() or os.path.realpath(BACKING) != str(BACKING):
        parser.error("requires the approved disposable backing folder")
    in_place.validate_fixture()
    if args.crash_at:
        crash(args)
        return
    args.evidence_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {"macos": platform.mac_ver()[0], "cache_state": "uncontrolled", "passed": False, "case": None,
              "open_gates": []}
    evidence = Evidence(args.evidence_dir, report)
    Probe(args, load(args.library, args.fixture_keychain), evidence).run()
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(0 if report["passed"] and report["cleanup"].get("complete") else 1)


if __name__ == "__main__":
    main()
