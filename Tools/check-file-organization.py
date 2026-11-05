#!/usr/bin/env python3
"""Gate M21 cross-folder file moves and parent identity on the approved disposable SMB fixture.

The moving client is the production libTinyMounterSMB.dylib with the native mount's cached
credential; a password-based probe client competes. Every path is below one random synthetic
folder. Checks are assertions; observations record native and server metadata without a claim.
Passing these operations does not bind legacy catalog entries to their historical server objects.
"""
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
import struct
import subprocess
import sys
import time
import unicodedata
import uuid

spec = importlib.util.spec_from_file_location("in_place", Path(__file__).with_name("check-edit-in-place.py"))
in_place = importlib.util.module_from_spec(spec)
spec.loader.exec_module(in_place)
publication = in_place.publication
READ, WRITE, DELETE, HANDLE = in_place.READ, in_place.WRITE, in_place.DELETE, publication.HANDLE
SHARING_DENIED = in_place.SHARING_DENIED
SERVER, SHARE, ACCOUNT = b"127.0.0.1", b"tinymounter-m19-edit-test", b"_tinymounter_m19"
BACKING = Path("/Users/Shared/tinymounter-m19-edit-fixture")
OWNED = re.compile(r"probe-org-[0-9a-f]{16}(/probe-[^/\\:\x00]+)*")
CONTENTS = bytes(range(256)) * 257
EVERYONE = bytes.fromhex("010100000000000100000000")
LIMIT = 16 * 1024 * 1024
NATIVE_INFO = None


def load_production(path):
    library = C.CDLL(str(path))
    pointer, data = C.c_void_p, C.POINTER(C.c_ubyte)
    declarations = {
        "connect": ([C.c_char_p, C.c_char_p, C.c_char_p, C.POINTER(C.c_int)], pointer),
        "disconnect": ([pointer], None),
        "open": ([pointer, C.c_char_p, C.c_uint32, C.c_uint32, data], C.c_int),
        "open_directory": ([pointer, C.c_char_p, C.c_uint32, C.c_uint32, data], C.c_int),
        "close": ([pointer, data], C.c_int),
        "info": ([pointer, data, C.POINTER(C.c_uint64)], C.c_int),
        "list": ([pointer, data, C.c_int, data, C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_int)], C.c_int),
        "read": ([pointer, data, C.c_uint64, data, C.c_uint32, C.POINTER(C.c_uint32)], C.c_int),
        "rename": ([pointer, data, C.c_char_p], C.c_int),
    }
    for name, (arguments, result) in declarations.items():
        function = getattr(library, "tm_edit_" + name)
        function.argtypes, function.restype = arguments, result
    return library


def probe_metadata(client, path, security):
    handle = client.open(path, 0x20080, sharing=7)
    try:
        return client.metadata(handle, security)
    finally:
        client.close(handle)


def split(path):
    parent, _, leaf = path.rpartition("/")
    return parent, leaf


def name_key(name):
    return unicodedata.normalize("NFC", unicodedata.normalize("NFD", name).casefold())


def microseconds(ticks):
    return ticks // 10 - 11644473600000000 if ticks // 10 > 11644473600000000 else 0


def parse_entries(data):
    """FileIdFullDirectoryInformation records, as RenameDirectoryEntry reads them."""
    entries, offset = [], 0
    while True:
        if offset + 80 > len(data):
            raise ValueError("invalid fixture directory entry")
        following, length = struct.unpack_from("<I", data, offset)[0], struct.unpack_from("<I", data, offset + 60)[0]
        if length % 2 or offset + 80 + length > len(data):
            raise ValueError("invalid fixture entry name")
        name = data[offset + 80:offset + 80 + length].decode("utf-16-le")
        if name not in (".", ".."):
            birth, _, modified, changed, size = struct.unpack_from("<QQQQq", data, offset + 8)
            entries.append({"name": name, "identity": [struct.unpack_from("<Q", data, offset + 72)[0], microseconds(birth)],
                            "size": size, "mtime_us": microseconds(modified), "ctime_us": microseconds(changed)})
        if not following:
            return entries
        if following < 80 + length or following > len(data) - offset:
            raise ValueError("invalid fixture entry offset")
        offset += following


class Direct:
    """SMBEdit's calls, with one independent context per connection."""

    def __init__(self, library, top):
        self.library, self.top, self.handles, self.held, self.evidence = library, top, [], {}, {}
        error = C.c_int()
        self.context = library.tm_edit_connect(SERVER, SHARE, ACCOUNT, C.byref(error))
        if not self.context:
            raise OSError(error.value, "connect production client")

    def call(self, operation, function, *arguments):
        if not self.context:
            raise OSError(errno.EIO, operation)
        code = function(self.context, *arguments)
        if code:
            raise OSError(code, operation)

    def path(self, path, folder=False):
        if not (folder and path == "") and path != self.top and not path.startswith(self.top + "/"):
            raise ValueError("path outside the task's synthetic folder")
        return path.encode()

    def open(self, path, access=READ | DELETE, sharing=1):
        handle = HANDLE()
        self.call("production open", self.library.tm_edit_open, self.path(path), access, sharing, handle)
        self.handles.append(handle)
        return handle

    def directory(self, path, access=0x81, sharing=3):
        handle = HANDLE()
        self.call("production folder open", self.library.tm_edit_open_directory, self.path(path, True),
                  access, sharing, handle)
        self.handles.append(handle)
        return handle

    def close(self, handle):
        self.handles = [h for h in self.handles if h is not handle]
        for path in [path for path, held in self.held.items() if held is handle]:
            del self.held[path]
        self.call("production close", self.library.tm_edit_close, handle)

    def release(self):
        for handle in list(self.handles):
            publication.attempt(lambda: self.close(handle))
        self.held.clear()

    def disconnect(self):
        if self.context:
            self.library.tm_edit_disconnect(self.context)
            self.context = None
        self.handles, self.held = [], {}

    def info(self, handle):
        values = (C.c_uint64 * 8)()
        self.call("production info", self.library.tm_edit_info, handle, values)
        return list(values)

    def identity(self, handle):
        return self.info(handle)[:2]

    def read(self, handle):
        size, result = self.info(handle)[2], bytearray()
        if size > LIMIT:
            raise ValueError("fixture file exceeds the probe limit")
        while len(result) < size:
            buffer, count = (C.c_ubyte * min(1024 * 1024, size - len(result)))(), C.c_uint32()
            self.call("production read", self.library.tm_edit_read, handle, len(result), buffer, len(buffer),
                      C.byref(count))
            if not count.value:
                raise OSError(errno.EIO, "short production read")
            result.extend(buffer[:count.value])
        return bytes(result)

    def rename(self, handle, destination):
        self.call("production rename", self.library.tm_edit_rename, handle, self.path(destination))

    def entries(self, folder):
        found, restart = [], 1
        for _ in range(1000):
            buffer, count, finished = (C.c_ubyte * 65536)(), C.c_uint32(), C.c_int()
            self.call("production list", self.library.tm_edit_list, self.held[folder], restart, buffer,
                      len(buffer), C.byref(count), C.byref(finished))
            if finished.value:
                return found
            found += parse_entries(bytes(buffer[:count.value]))
            restart = 0
        raise ValueError("unbounded fixture directory")

    def matches(self, folder, identity):
        return [entry for entry in self.entries(folder) if entry["identity"] == identity]

    def stored_name(self, folder, identity):
        found = self.matches(folder, identity)
        return found[0]["name"] if len(found) == 1 else None

    def hold(self, folder):
        """SMBEdit.protectAncestors, recording each folder's server identity and stored name."""
        parts, chain = folder.split("/") if folder else [], []
        for depth in range(len(parts) + 1):
            path = "/".join(parts[:depth])
            if path not in self.held:
                handle = self.directory(path)
                values = self.info(handle)
                if not all(values[:2]) or values[4] & 0x410 != 0x10:
                    raise ValueError("held folder is not an ordinary directory")
                self.held[path] = handle
                self.evidence[path] = {"leaf": parts[depth - 1] if depth else "", "identity": values[:2],
                                       "stored_name": self.stored_name(split(path)[0], values[:2]) if depth else None}
            chain.append(self.evidence[path])
        return chain

    def guard(self, path):
        """SMBEdit's rename source guard, bound to its one directory entry by server identity."""
        parent, leaf = split(path)
        self.hold(parent)
        handle = self.open(path)
        values = self.info(handle)
        entries = self.entries(parent)
        own = [entry for entry in entries if entry["identity"] == values[:2]]
        alike = [entry for entry in entries if name_key(entry["name"]) == name_key(leaf)]
        return handle, values, {"entry": own[0] if len(own) == 1 else None, "unique": len(alike) == 1,
                                "stored_name": own[0]["name"] if len(own) == 1 else None}


def exact(chain):
    return all(entry["stored_name"] == entry["leaf"] for entry in chain if entry["leaf"])


def native(path):
    try:
        # Enumerate first, as catalog listings do; native caches remain uncontrolled.
        names = [name for name in os.listdir(path.parent)
                 if unicodedata.normalize("NFC", name) == unicodedata.normalize("NFC", path.name)]
        if len(names) != 1:
            return {"errno": errno.ENOENT if not names else errno.EEXIST}
        values = (C.c_uint64 * 5)()
        error = NATIVE_INFO(os.fsencode(path.parent / names[0]), values)
        if error:
            return {"errno": error}
    except OSError as error:
        return {"errno": error.errno}
    return dict(zip(("ino", "size", "mtime_us", "ctime_us", "birth_us"), values))


def direct_fingerprint(values):
    return [values[2], values[5], values[6]]


def native_fingerprint(observation):
    return [observation.get(key) for key in ("size", "mtime_us", "ctime_us")]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def set_times(client, path, creation=0, modified=0, changed=0):
    def filetime(value):
        return (value + 11644473600000000) * 10 if value else 0
    handle = client.open(path, 0x100)
    try:
        client.set_metadata(handle, struct.pack("<QQQQII", filetime(creation), 0, filetime(modified),
                                                filetime(changed), 0, 0), False)
    finally:
        client.close(handle)


def copy_file(client, donor, path):
    """Create a file through the competing client from a donor's bytes, bypassing native caches."""
    source = client.open(donor, READ, 7)
    target = client.open(path, READ | WRITE, 7, create=True)
    try:
        client.copy(source, target, client.info(source)[2])
    finally:
        client.close(target)
        client.close(source)


def aces(security):
    acl = in_place.dacl(security)
    offset, found = 8, []
    for _ in range(struct.unpack_from("<H", acl, 4)[0]):
        kind, flags, size = struct.unpack_from("<BBH", acl, offset)
        if size < 8 or offset + size > len(acl):
            raise ValueError("invalid fixture ACE")
        found.append((kind, flags, struct.unpack_from("<I", acl, offset + 4)[0], acl[offset + 8:offset + size]))
        offset += size
    return found


def inherit_only_denial(security):
    """The folder's DACL plus a rule that only new child files inherit."""
    acl = in_place.dacl(security)
    revision, _, length, count, _ = struct.unpack_from("<BBHHH", acl)
    ace = struct.pack("<BBHI", 1, 0x09, 8 + len(EVERYONE), WRITE) + EVERYONE
    return (struct.pack("<BBHIIII", 1, 0, 0x8004, 0, 0, 0, 20)
            + struct.pack("<BBHHH", revision, 0, length + len(ace), count + 1, 0) + ace + acl[8:])


def retry(operation):
    """Fresh evidence after SIGKILL waits for the server to drop the dead session's handles."""
    for attempt in range(20):
        try:
            return operation()
        except OSError as error:
            if error.errno not in SHARING_DENIED or attempt == 19:
                raise
            time.sleep(0.5)


class Case:
    def __init__(self, report, name):
        self.result = {"passed": False, "checks": {}, "observations": {}}
        report["cases"][name] = self.result

    def require(self, key, value):
        self.result["checks"][key] = bool(value)
        if not value:
            raise AssertionError(key)

    def observe(self, key, value):
        self.result["observations"][key] = value


class Fixture:
    def __init__(self, args, root, top, probe_library, smb_library):
        self.args, self.root, self.top = args, root, top
        self.probe_library, self.smb_library = probe_library, smb_library
        self.seed = top + "/probe-seed"
        self.a = self.b = self.moved = None
        self.prepared_folders = set()

    def prepare_folders(self):
        names = ["move-src", "move-dst", "col-src", "col-dst", "deny-src", "deny-dst",
                 "chg", "par-src", "par-dst", "ob-target", "ob-dir"]
        names += ["int-" + point + "-" + side for point in ("before", "after") for side in ("src", "dst")]
        for name in names:
            self.folder(name)
        self.prepared_folders = set(names)

    def folder(self, name):
        path = self.top + "/probe-" + name
        if name in self.prepared_folders:
            self.prepared_folders.remove(name)
        else:
            (BACKING / path).mkdir(mode=0o777)
            os.chmod(BACKING / path, 0o777)
        return path

    def write(self, path, payload):
        publication.native_write(self.root / path, payload, True)

    def copy(self, path):
        # Folders that are renamed later get direct-SMB children, so no native client handle stays below.
        copy_file(self.b, self.seed, path)


def move_case(case, fixture):
    a, b, root, top = fixture.a, fixture.b, fixture.root, fixture.top
    src, dst = fixture.folder("move-src"), fixture.folder("move-dst")
    source, neighbor = src + "/probe-move-file", src + "/probe-move-neighbor"
    destination = dst + "/probe-Moved-Caf\u00e9"
    fixture.write(source, CONTENTS)
    fixture.write(neighbor, CONTENTS)
    folder = b.directory(dst, access=0x20000 | 0x40000, sharing=7)
    try:
        rule = inherit_only_denial(b.metadata(folder, True))
        case.observe("destination_permission_change_errno", publication.attempt(lambda: b.set_metadata(folder, rule, True)))
    except ValueError as error:
        case.observe("destination_permission_change_errno", str(error))
    folder_security = {"destination": b.metadata(folder, True)}
    b.close(folder)
    folder = b.directory(src, access=0x20000, sharing=7)
    folder_security["source"] = b.metadata(folder, True)
    b.close(folder)
    row = native(root / source)
    native_parents = {"source": native(root / src), "destination": native(root / dst)}
    item = a.open(neighbor, READ, 7)
    neighbor_identity = a.identity(item)
    a.close(item)
    reader = b.open(source, READ, 5)

    chain = a.hold(src) + a.hold(dst)
    parents = {"source": a.identity(a.held[src]), "destination": a.identity(a.held[dst])}
    parent_before = {"source": a.info(a.held[src]), "destination": a.info(a.held[dst])}
    guard, before, bound = a.guard(source)
    identity = before[:2]
    case.require("ancestors_have_server_identity", all(all(entry["identity"]) for entry in chain))
    case.require("ancestors_have_exact_stored_names", exact(chain))
    case.require("parents_distinct", parents["source"] != parents["destination"])
    case.require("source_bound_by_identity_and_stored_name", bound["stored_name"] == split(source)[1] and bound["unique"])
    case.require("single_link", before[3] == 1)
    case.observe("parent_permissions_differ",
                 in_place.dacl(folder_security["source"]) != in_place.dacl(folder_security["destination"]))
    case.observe("catalog_row_native", row)
    case.observe("row_fingerprint_matches_protected_source", native_fingerprint(row) == direct_fingerprint(before))
    case.observe("enumeration_fingerprint_matches_protected_source", [
        bound["entry"][key] for key in ("size", "mtime_us", "ctime_us")] == direct_fingerprint(before)
        if bound["entry"] else None)
    case.observe("native_ino_equals_server_file_id", {
        "file": row.get("ino") == identity[0],
        "source_parent": native_parents["source"].get("ino") == parents["source"][0],
        "destination_parent": native_parents["destination"].get("ino") == parents["destination"][0]})
    case.observe("native_birth_equals_server_birth", row.get("birth_us") == identity[1])

    for key, operation in (("writer", lambda: b.close(b.open(source, WRITE))),
                           ("delete", lambda: b.close(b.open(source, DELETE))),
                           ("source_parent_delete", lambda: b.close(b.directory(src, access=0x10081, sharing=7))),
                           ("destination_parent_delete", lambda: b.close(b.directory(dst, access=0x10081, sharing=7))),
                           ("common_parent_delete", lambda: b.close(b.directory(top, access=0x10081, sharing=7)))):
        code = publication.attempt(operation)
        case.observe(key + "_errno", code)
        case.require(key + "_denied", code in SHARING_DENIED)
    for key, old, new in (("native_file_rename", source, src + "/probe-move-escape"),
                          ("native_parent_rename", dst, top + "/probe-move-escape")):
        code = publication.attempt(lambda: os.rename(root / old, root / new))
        case.observe(key + "_errno", code)
        case.require(key + "_denied", code == errno.EBUSY)
    case.require("guarded_paths_unmoved", a.stored_name(src, identity) == split(source)[1]
                 and a.stored_name(top, parents["destination"]) == split(dst)[1])
    case.observe("native_stat_under_guard", native(root / source))
    # As in M20, another client attaches data and changes access while the guard is held.
    b.close(b.create_stream(source))
    handle = b.open(source, 0x20000 | 0x40000)
    changed = publication.deny_data_writes(b.metadata(handle, True))
    b.set_metadata(handle, changed, True)
    b.close(handle)
    before = a.info(guard)
    case.require("complete_contents_before", a.read(guard) == CONTENTS)
    security, streams = probe_metadata(b, source, True), probe_metadata(b, source, False)
    case.require("live_permission_change_observed", in_place.dacl(security) == in_place.dacl(changed))
    staged = native(root / source)

    a.rename(guard, destination)
    after = a.info(guard)
    parent_after = {"source": a.info(a.held[src]), "destination": a.info(a.held[dst])}
    case.observe("direct_changes_from_move", {
        "file_mtime": after[5] != before[5], "file_ctime": after[6] != before[6],
        "source_parent_mtime": parent_after["source"][5] != parent_before["source"][5],
        "destination_parent_mtime": parent_after["destination"][5] != parent_before["destination"][5]})
    case.observe("stream_information_unchanged", probe_metadata(b, destination, False) == streams)
    case.require("same_object_after_move", after[:2] == identity and after[3] == 1)
    case.require("exact_destination_spelling", a.stored_name(dst, identity) == split(destination)[1])
    case.require("absent_from_source_parent", not a.matches(src, identity)
                 and all(name_key(entry["name"]) != name_key(split(source)[1]) for entry in a.entries(src)))
    case.require("complete_contents_after", a.read(guard) == CONTENTS)
    case.require("permissions_preserved", in_place.dacl(probe_metadata(b, destination, True)) == in_place.dacl(security))
    stream = b.stream(destination)
    case.require("attached_stream_preserved", b.read(stream) == in_place.STREAM_CONTENTS)
    b.close(stream)
    case.require("existing_reader_preserved", b.read(reader) == CONTENTS)
    case.require("parents_unchanged", a.identity(a.held[src]) == parents["source"]
                 and a.identity(a.held[dst]) == parents["destination"]
                 and a.stored_name(top, parents["source"]) == split(src)[1]
                 and a.stored_name(top, parents["destination"]) == split(dst)[1])
    item = a.open(neighbor, READ, 7)
    case.require("untouched_neighbor", a.identity(item) == neighbor_identity and a.read(item) == CONTENTS
                 and a.stored_name(src, neighbor_identity) == split(neighbor)[1])
    a.close(item)
    control = b.open(dst + "/probe-move-control", READ, 7, create=True)
    try:
        inherited = any(kind == 1 and mask & WRITE and sid == EVERYONE
                        for kind, _, mask, sid in aces(b.metadata(control, True)))
    except ValueError:
        inherited = None
    b.close(control)
    case.observe("new_destination_file_inherits_denial", inherited)
    a.release()
    b.close(reader)
    moved = native(root / destination)
    case.observe("native_after_move", {"file": moved, "old_path": native(root / source),
                                       "source_parent": native(root / src), "destination_parent": native(root / dst)})
    case.observe("native_changes_from_move", {
        key: moved[key] != staged[key] if key in moved and key in staged else None
        for key in ("ino", "mtime_us", "ctime_us", "birth_us")})
    fixture.moved = {"path": destination, "identity": identity, "digest": digest(CONTENTS),
                     "parents": {"source": [src, parents["source"]], "destination": [dst, parents["destination"]]}}


def collisions_case(case, fixture):
    a, b = fixture.a, fixture.b
    src, dst = fixture.folder("col-src"), fixture.folder("col-dst")
    for name in ("probe-taken", "probe-caf\u00e9"):
        fixture.write(dst + "/" + name, b"competitor")
    for label, request, existing in (("ordinary", "probe-taken", "probe-taken"),
                                     ("case", "probe-TAKEN", "probe-taken"),
                                     ("unicode", "probe-caf\u00e9", "probe-caf\u00e9"),
                                     ("unicode_normalized", "probe-cafe\u0301", "probe-caf\u00e9"),
                                     ("race", "probe-race", None)):
        source = src + "/probe-col-" + label.replace("_", "-")
        fixture.write(source, CONTENTS)
        a.hold(dst)
        guard, values, _ = a.guard(source)
        if existing is None:
            fixture.write(dst + "/" + request, b"competitor")
            existing = request
        code = publication.attempt(lambda: a.rename(guard, dst + "/" + request))
        case.observe(label + "_errno", code)
        competitor = b.open(dst + "/" + existing, READ, 7)
        preserved = (a.identity(guard) == values[:2] and a.read(guard) == CONTENTS
                     and a.stored_name(src, values[:2]) == split(source)[1] and b.read(competitor) == b"competitor")
        b.close(competitor)
        a.close(guard)
        case.require(label + "_collision_refused", code == errno.EEXIST)
        case.require(label + "_both_preserved", preserved)


def denied_case(case, fixture):
    a = fixture.a
    src, dst = fixture.folder("deny-src"), fixture.folder("deny-dst")
    source = src + "/probe-deny-file"
    fixture.write(source, CONTENTS)
    _, values, _ = a.guard(source)
    identity = values[:2]
    a.release()
    for label, locked in (("destination", dst), ("source", src)):
        stage = {}

        def move():
            a.hold(dst)
            stage["guard"] = a.guard(source)[0]
            a.rename(stage["guard"], dst + "/probe-deny-file")

        os.chmod(BACKING / locked, 0o555)
        try:
            code = publication.attempt(move)
        finally:
            a.release()
            os.chmod(BACKING / locked, 0o777)
        case.observe(label + "_denied_errno", code)
        case.observe(label + "_denied_at", "rename" if "guard" in stage else "admission")
        a.hold(dst)
        guard, after, _ = a.guard(source)
        intact = after[:2] == identity and a.read(guard) == CONTENTS and a.stored_name(src, identity) == split(source)[1]
        unpublished = not a.entries(dst)
        a.release()
        case.require(label + "_parent_denied", code in (errno.EACCES, errno.EPERM))
        case.require(label + "_source_intact", intact)
        case.require(label + "_nothing_published", unpublished)


def changes_case(case, fixture):
    a, b, root = fixture.a, fixture.b, fixture.root
    folder = fixture.folder("chg")
    edited, replaced = folder + "/probe-chg-edited", folder + "/probe-chg-replaced"
    donor, previous = folder + "/probe-chg-donor", folder + "/probe-chg-previous"
    for path, payload in ((edited, CONTENTS), (replaced, CONTENTS), (donor, CONTENTS[::-1])):
        fixture.write(path, payload)
    base = {}
    for path in (edited, replaced):
        guard, values, _ = a.guard(path)
        base[path] = {"values": values, "digest": digest(a.read(guard)), "native": native(root / path)}
        a.close(guard)
    # Another SMB client rewrites the bytes in place, then restores size and modification time.
    source, target = b.open(donor, READ, 7), b.open(edited, READ | WRITE, 7)
    b.copy(source, target, len(CONTENTS))
    b.close(target)
    b.close(source)
    old = base[edited]["values"]
    case.observe("edited_mtime_restore_errno", publication.attempt(lambda: set_times(b, edited, modified=old[5])))
    case.observe("edited_ctime_forge_errno", publication.attempt(lambda: set_times(b, edited, changed=old[6])))
    # It also replaces the other file with a new object of identical bytes and restored times.
    os.rename(root / replaced, root / previous)
    copy_file(b, previous, replaced)
    old = base[replaced]["values"]
    case.observe("replacement_times_restore_errno",
                 publication.attempt(lambda: set_times(b, replaced, creation=old[1], modified=old[5])))
    case.observe("replacement_ctime_forge_errno", publication.attempt(lambda: set_times(b, replaced, changed=old[6])))
    found = {}
    for label, path in (("edited", edited), ("replaced", replaced)):
        guard, values, _ = a.guard(path)
        then, now = base[path], native(root / path)
        found[label] = {
            "file_id_same": values[0] == then["values"][0], "birth_same": values[1] == then["values"][1],
            "size_same": values[2] == then["values"][2], "mtime_same": values[5] == then["values"][5],
            "ctime_same": values[6] == then["values"][6], "bytes_same": digest(a.read(guard)) == then["digest"],
            "native_ino_same": now.get("ino") == then["native"].get("ino"),
            "native_fingerprint_same": native_fingerprint(now) == native_fingerprint(then["native"]),
            "native_birth_same": now.get("birth_us") == then["native"].get("birth_us")}
        a.close(guard)
        case.observe(label, found[label])
    retained = a.matches(folder, base[replaced]["values"][:2])
    edit, swap = found["edited"], found["replaced"]
    case.observe("metadata_only_binding_accepts", {
        "edited": edit["native_fingerprint_same"] and edit["native_ino_same"],
        "replaced": swap["native_fingerprint_same"] and swap["native_ino_same"]})
    # Restored times only strengthen the counterexample, so they stay observations above.
    case.require("edited_same_server_object", edit["file_id_same"] and edit["birth_same"])
    case.require("edited_full_digest_detects_change", edit["size_same"] and not edit["bytes_same"])
    case.require("replacement_bytes_identical", swap["bytes_same"] and swap["size_same"])
    case.require("replacement_server_file_id_differs", not swap["file_id_same"])
    case.require("replaced_original_retained", len(retained) == 1 and retained[0]["name"] == split(previous)[1])


def parents_case(case, fixture):
    a, b, root, top = fixture.a, fixture.b, fixture.root, fixture.top
    src, dst = fixture.folder("par-src"), fixture.folder("par-dst")
    source = src + "/probe-par-file"
    fixture.copy(source)
    a.hold(dst)
    _, values, _ = a.guard(source)
    recorded = {"source": a.identity(a.held[src]), "destination": a.identity(a.held[dst])}
    native_before = {"source": native(root / src), "destination": native(root / dst), "file": native(root / source)}
    a.release()
    # While unprotected, both parents move away and new folders take their names, one as a case alias.
    os.rename(BACKING / src, BACKING / (top + "/probe-par-src-previous"))
    os.rename(BACKING / dst, BACKING / (top + "/probe-par-dst-previous"))
    fixture.folder("par-src")
    fixture.folder("PAR-dst")
    fixture.copy(source)
    case.observe("replacement_file_times_restore_errno",
                 publication.attempt(lambda: set_times(b, source, creation=values[1], modified=values[5])))

    chain = a.hold(src)
    fresh_source = a.identity(a.held[src])
    code = publication.attempt(lambda: a.hold(dst))
    fresh_destination = a.identity(a.held[dst]) if dst in a.held else None
    alias = a.stored_name(top, fresh_destination) if fresh_destination else None
    guard, now, _ = a.guard(source)
    identical = a.read(guard) == CONTENTS
    moved_away = {label: a.stored_name(top, identity) for label, identity in recorded.items()}
    case.observe("source_parent_names_exact", exact(chain))
    case.observe("destination_lookup_errno", code)
    case.observe("destination_stored_name_exact", alias == split(dst)[1] if alias else None)
    case.observe("native_changes_from_replacement", {
        "source_parent_ino": native(root / src).get("ino") != native_before["source"].get("ino"),
        "destination_parent_ino": native(root / dst).get("ino") != native_before["destination"].get("ino"),
        "file_ino": native(root / source).get("ino") != native_before["file"].get("ino")})
    case.require("source_parent_replacement_detected", fresh_source != recorded["source"])
    case.require("destination_parent_replacement_detected", code == errno.ENOENT
                 or (fresh_destination != recorded["destination"] and alias != split(dst)[1]))
    case.require("replacement_file_detected", now[:2] != values[:2] and identical)
    case.require("recorded_parents_retained_elsewhere", moved_away == {"source": "probe-par-src-previous",
                                                                       "destination": "probe-par-dst-previous"})


def open_below_case(case, fixture):
    a, b, root, top = fixture.a, fixture.b, fixture.root, fixture.top
    target, folder = fixture.folder("ob-target"), fixture.folder("ob-dir")
    child, escape = folder + "/probe-ob-child", top + "/probe-ob-escape"
    fixture.copy(child)
    fixture.write(target + "/probe-ob-taken", b"competitor")
    guard = a.open(child)
    case.observe("delete_open_with_guarded_file_below_errno",
                 publication.attempt(lambda: b.close(b.directory(folder, access=0x10081, sharing=7))))
    code = publication.attempt(lambda: os.rename(root / folder, root / escape))
    case.observe("native_rename_with_guarded_file_below_errno", code)
    if not code:
        case.require("open_below_rename_restored", publication.attempt(lambda: os.rename(root / escape, root / folder)) == 0)
    a.close(guard)
    a.hold(folder)
    identity = a.identity(a.held[folder])
    code = publication.attempt(lambda: os.rename(root / folder, root / escape))
    case.observe("native_rename_of_held_folder_errno", code)
    case.require("held_folder_rename_denied", code == errno.EBUSY
                 and a.stored_name(top, identity) == split(folder)[1])
    a.release()

    a.hold(target)
    handle = a.directory(folder, access=0x10081, sharing=3)
    item = a.open(child, READ, 7)
    child_identity = a.identity(item)
    a.close(item)
    native_before = {"folder": native(root / folder), "child": native(root / child)}
    collision = publication.attempt(lambda: a.rename(handle, target + "/probe-ob-taken"))
    reader = b.open(child, READ, 7)
    code = publication.attempt(lambda: a.rename(handle, target + "/probe-ob-dir"))
    case.observe("folder_collision_errno", collision)
    case.observe("folder_rename_with_reader_below_errno", code)
    if code:
        b.close(reader)
        reader = None
        code = publication.attempt(lambda: a.rename(handle, target + "/probe-ob-dir"))
    case.observe("folder_rename_errno", code)
    case.require("folder_collision_refused", collision == errno.EEXIST)
    case.require("folder_renamed", code == 0)
    moved = target + "/probe-ob-dir/probe-ob-child"
    item = a.open(moved, READ, 7)
    case.require("folder_identity_preserved", a.identity(handle) == identity)
    case.require("folder_exact_name_in_target", a.stored_name(target, identity) == "probe-ob-dir")
    case.require("folder_left_old_parent", not a.matches(top, identity))
    case.require("child_identity_and_contents_preserved", a.identity(item) == child_identity and a.read(item) == CONTENTS)
    if reader:
        case.require("reader_below_preserved", b.read(reader) == CONTENTS)
        b.close(reader)
    a.release()
    native_after = {"folder": native(root / (target + "/probe-ob-dir")), "child": native(root / moved)}
    case.observe("native", {"before": native_before, "after": native_after})
    case.observe("native_changes_from_folder_move", {
        key: native_after[key].get("ino") != native_before[key].get("ino") for key in native_before})


def interrupt_case(case, fixture, checkpoint):
    a, b, args = fixture.a, fixture.b, fixture.args
    src, dst = fixture.folder("int-" + checkpoint + "-src"), fixture.folder("int-" + checkpoint + "-dst")
    source, destination = src + "/probe-int-file", dst + "/probe-int-Moved"
    fixture.write(source, CONTENTS)
    a.hold(dst)
    guard, values, _ = a.guard(source)
    intent = {"source": source, "destination": destination, "identity": values[:2], "sha256": digest(a.read(guard)),
              "parents": {path: a.identity(handle) for path, handle in a.held.items()}}
    a.release()
    path = args.evidence_dir / ("organize-intent-" + checkpoint + ".json")
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        json.dump(intent, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    directory = os.open(args.evidence_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--library", str(args.library),
                            "--smb-library", str(args.smb_library), "--fixture-keychain", str(args.fixture_keychain),
                            "--evidence-dir", str(args.evidence_dir), "--crash-at", checkpoint,
                            "--crash-intent", str(path)], capture_output=True, timeout=180)
    case.observe("child_returncode", child.returncode)
    if child.returncode != -signal.SIGKILL:
        case.observe("child_error", child.stderr.decode(errors="replace").strip().splitlines()[-1:])
    case.require("process_interrupted", child.returncode == -signal.SIGKILL)
    chain = retry(lambda: a.hold(src) + a.hold(dst))
    surviving, missing = (source, destination) if checkpoint == "before" else (destination, source)
    guard, now, bound = retry(lambda: a.guard(surviving))
    proven = (now[:2] == intent["identity"] and bound["stored_name"] == split(surviving)[1]
              and digest(a.read(guard)) == intent["sha256"])
    absent = (publication.attempt(lambda: a.close(a.open(missing, READ, 7))) == errno.ENOENT
              and not a.matches(split(missing)[0], intent["identity"]))
    case.require("parents_unchanged", exact(chain)
                 and all(a.identity(a.held[folder]) == identity for folder, identity in intent["parents"].items()))
    case.require("surviving_name_proves_original", proven)
    case.require("other_name_absent", absent)
    if checkpoint == "before":
        fixture.write(destination, b"created after interruption")
        code = publication.attempt(lambda: a.rename(guard, destination))
        competitor = b.open(destination, READ, 7)
        kept = b.read(competitor) == b"created after interruption"
        b.close(competitor)
        case.observe("retry_errno", code)
        case.require("retry_refuses_new_destination", code == errno.EEXIST)
        case.require("retry_preserves_both", kept and a.identity(guard) == intent["identity"] and a.read(guard) == CONTENTS)
    else:
        copy_file(b, destination, source)
        _, recreated, _ = a.guard(source)
        case.require("recreated_source_is_another_object", recreated[:2] != intent["identity"])
        case.require("destination_still_proves_original", a.identity(guard) == intent["identity"]
                     and a.read(guard) == CONTENTS)


def reconnect_case(case, fixture):
    moved = fixture.moved
    case.require("move_case_completed", moved is not None)
    fixture.a.disconnect()
    fixture.a = a = Direct(fixture.smb_library, fixture.top)
    for label, (folder, identity) in moved["parents"].items():
        chain = a.hold(folder)
        case.require(label + "_parent_after_reconnect", exact(chain) and a.identity(a.held[folder]) == identity)
    guard, values, bound = a.guard(moved["path"])
    case.require("object_identity_and_name_after_reconnect", values[:2] == moved["identity"]
                 and bound["stored_name"] == split(moved["path"])[1])
    case.require("complete_contents_after_reconnect", digest(a.read(guard)) == moved["digest"])


CASES = (("move", move_case), ("collisions", collisions_case), ("denied", denied_case),
         ("changes", changes_case), ("parents", parents_case), ("open_below", open_below_case),
         ("interrupt_before", interrupt_case, "before"), ("interrupt_after", interrupt_case, "after"),
         ("reconnect", reconnect_case))


def run(report, fixture, name, function, *arguments):
    case = Case(report, name)
    try:
        function(case, fixture, *arguments)
        case.result["passed"] = True
    except Exception as error:
        case.result["failure"] = type(error).__name__ + ": " + str(error)
        case.result["operation"] = getattr(error, "strerror", None)
        case.result["errno"] = getattr(error, "errno", None)
        case.result["probe_ntstatus"] = hex(fixture.probe_library.probe_status())
    finally:
        fixture.a.release()
        for handle in list(fixture.b.handles):
            publication.attempt(lambda: fixture.b.close(handle))


def crash(args):
    path = args.crash_intent
    if not path.name.startswith("organize-intent-") or path.resolve().parent != args.evidence_dir.resolve():
        raise ValueError("requires this probe's intent file")
    intent = json.loads(path.read_text())
    top = intent["source"].split("/")[0]
    paths = [intent["source"], intent["destination"]] + [path for path in intent["parents"] if path]
    if not all(OWNED.fullmatch(item) and item.split("/")[0] == top for item in paths):
        raise ValueError("intent paths are not task-owned")
    required = {"", top, split(intent["source"])[0], split(intent["destination"])[0]}
    if not required.issubset(intent["parents"]):
        raise ValueError("intent is missing protected directories")
    a = Direct(load_production(args.smb_library), top)
    for folder, identity in intent["parents"].items():
        chain = a.hold(folder)
        if not exact(chain) or a.identity(a.held[folder]) != identity:
            raise SystemExit(3)
    guard, values, bound = a.guard(intent["source"])
    if (values[:2] != intent["identity"] or bound["stored_name"] != split(intent["source"])[1]
            or not bound["unique"] or digest(a.read(guard)) != intent["sha256"]):
        raise SystemExit(4)
    if args.crash_at == "after":
        a.rename(guard, intent["destination"])
    os.kill(os.getpid(), signal.SIGKILL)


def probe(args):
    global NATIVE_INFO
    root = in_place.validate_fixture()
    if BACKING.is_symlink() or not BACKING.is_dir():
        raise ValueError("requires the disposable fixture's backing folder")
    top = "probe-org-" + uuid.uuid4().hex[:16]
    report = {"macos": platform.mac_ver()[0], "cache_state": "uncontrolled", "file_bytes": len(CONTENTS),
              "fixture_prefix": top, "historical_catalog_binding_proven": False, "passed": False, "cases": {}}
    probe_library = publication.load(args.library, True, args.fixture_keychain)
    NATIVE_INFO = probe_library.probe_native_info
    NATIVE_INFO.argtypes, NATIVE_INFO.restype = [C.c_char_p, C.POINTER(C.c_uint64)], C.c_int
    fixture = Fixture(args, root, top, probe_library,
                      load_production(args.smb_library))
    (BACKING / top).mkdir(mode=0o777)
    os.chmod(BACKING / top, 0o777)
    # Populate setup before native SMB caches the directory's children.
    fixture.prepare_folders()
    if not (root / top).is_dir():
        raise ValueError("the backing folder is not the mounted fixture")
    publication.native_write(root / fixture.seed, CONTENTS, True)
    try:
        fixture.b = in_place.Client(fixture.probe_library)
        fixture.a = Direct(fixture.smb_library, top)
    except OSError as error:
        report["failure"], report["errno"] = error.strerror, error.errno
        if fixture.b:
            fixture.b.disconnect()
        return report
    try:
        for name, function, *arguments in CASES:
            run(report, fixture, name, function, *arguments)
    finally:
        fixture.a.disconnect()
        fixture.b.disconnect()
    report["passed"] = len(report["cases"]) == len(CASES) and all(case["passed"] for case in report["cases"].values())
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True, help="the probe built from check-edit-publication.c")
    parser.add_argument("--smb-library", type=Path, required=True, help="the production libTinyMounterSMB.dylib")
    parser.add_argument("--fixture-keychain", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--crash-at", choices=("before", "after"))
    parser.add_argument("--crash-intent", type=Path)
    args = parser.parse_args()
    in_place.validate_fixture()
    if args.crash_at:
        if not args.crash_intent:
            parser.error("--crash-at requires --crash-intent")
        crash(args)
        return
    args.evidence_dir.mkdir(parents=True, exist_ok=False)
    result = probe(args)
    (args.evidence_dir / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True))
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
