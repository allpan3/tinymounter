#!/usr/bin/env python3
"""Check M19's handle and publication assumptions on the approved loopback SMB fixture."""
import argparse
import ctypes as C
import errno
import json
import os
from pathlib import Path
import platform
import subprocess
import uuid


READ = 0x00000001 | 0x00000080
WRITE = 0x00000002
DELETE = 0x00010000
SHARE_READ, SHARE_WRITE, SHARE_DELETE = 1, 2, 4
ALL = SHARE_READ | SHARE_WRITE | SHARE_DELETE
HANDLE = C.c_ubyte * 16


class Client:
    def __init__(self, library):
        self.library = library
        self.handles = []
        error = C.c_int()
        self.context = library.probe_connect(C.byref(error))
        if not self.context:
            raise OSError(error.value, "connect fixture")

    def open(self, name, access=READ, sharing=ALL, create=False):
        handle = HANDLE()
        error = self.library.probe_open(self.context, name.encode(), access, sharing, create, handle)
        if error:
            raise OSError(error, "open fixture file")
        self.handles.append(handle)
        return handle

    def close(self, handle):
        error = self.library.probe_close(self.context, handle)
        self.handles = [h for h in self.handles if h is not handle]
        if error:
            raise OSError(error, "close fixture file")

    def disconnect(self):
        if self.context:
            self.library.probe_disconnect(self.context)
            self.context = None
            self.handles.clear()

    def info(self, handle):
        values = (C.c_uint64 * 8)()
        error = self.library.probe_info(self.context, handle, values)
        if error:
            raise OSError(error, "inspect fixture file")
        return list(values)

    def read(self, handle):
        size = self.info(handle)[2]
        result = bytearray()
        while len(result) < size:
            buffer = (C.c_ubyte * min(65536, size - len(result)))()
            count = C.c_uint32()
            error = self.library.probe_read(self.context, handle, len(result), buffer, len(buffer), C.byref(count))
            if error or not count.value:
                raise OSError(error or errno.EIO, "read fixture file")
            result.extend(buffer[:count.value])
        return bytes(result)

    def rename(self, handle, name):
        error = self.library.probe_rename(self.context, handle, name.encode())
        if error:
            raise OSError(error, "rename fixture file")

    def flush(self, handle):
        error = self.library.probe_flush(self.context, handle)
        if error:
            raise OSError(error, "flush fixture file")


def load(path):
    library = C.CDLL(str(path))
    pointer = C.c_void_p
    byte_pointer = C.POINTER(C.c_ubyte)
    declarations = {
        "connect": ([C.POINTER(C.c_int)], pointer),
        "disconnect": ([pointer], None),
        "open": ([pointer, C.c_char_p, C.c_uint32, C.c_uint32, C.c_int, byte_pointer], C.c_int),
        "close": ([pointer, byte_pointer], C.c_int),
        "info": ([pointer, byte_pointer, C.POINTER(C.c_uint64)], C.c_int),
        "read": ([pointer, byte_pointer, C.c_uint64, byte_pointer, C.c_uint32, C.POINTER(C.c_uint32)], C.c_int),
        "rename": ([pointer, byte_pointer, C.c_char_p], C.c_int),
        "delete": ([pointer, byte_pointer], C.c_int),
        "flush": ([pointer, byte_pointer], C.c_int),
    }
    for name, (arguments, result) in declarations.items():
        function = getattr(library, "probe_" + name)
        function.argtypes, function.restype = arguments, result
    return library


def attempt(operation):
    try:
        operation()
        return 0
    except OSError as error:
        return error.errno


def native_write(path, payload, create=False):
    flags = os.O_WRONLY | os.O_NOFOLLOW | (os.O_CREAT | os.O_EXCL if create else 0)
    fd = os.open(path, flags, 0o644)
    try:
        offset = 0
        while offset < len(payload):
            count = os.write(fd, payload[offset:])
            if not count:
                raise OSError(errno.EIO, "short fixture write")
            offset += count
        os.fsync(fd)
    finally:
        os.close(fd)


def probe(root, library):
    a, b = Client(library), Client(library)
    prefix = "probe-" + uuid.uuid4().hex + "-"
    names = {key: prefix + key for key in ("stage", "original", "recovery", "moved", "conflict")}
    report = {"macos": platform.mac_ver()[0], "cache_state": "uncontrolled"}
    payload = bytes(range(256)) * 257
    original = b"previous contents\n" * 256
    try:
        stage = a.open(names["stage"], READ | DELETE, SHARE_READ | SHARE_WRITE, True)
        identity = a.info(stage)[:2]
        report["stage_identity_present"] = all(identity)
        report["native_upload_under_guard_errno"] = attempt(lambda: native_write(root / names["stage"], payload))
        if report["native_upload_under_guard_errno"]:
            return report
        report["direct_read_matches_native_upload"] = a.read(stage) == payload
        verifier = a.open(names["stage"], READ, SHARE_READ | SHARE_DELETE)
        report["flush_errno"] = attempt(lambda: a.flush(stage))
        report["direct_writer_denied_errno"] = attempt(lambda: b.close(b.open(names["stage"], WRITE)))
        report["direct_delete_open_denied_errno"] = attempt(lambda: b.close(b.open(names["stage"], DELETE)))
        report["native_writer_denied_errno"] = attempt(lambda: native_write(root / names["stage"], b"must not write"))
        report["stage_unchanged_under_guards"] = a.read(stage) == payload

        native_write(root / names["original"], original, True)
        old = a.open(names["original"], READ | DELETE, SHARE_READ)
        old_identity = a.info(old)[:2]
        report["old_full_read_matches"] = a.read(old) == original
        report["old_native_writer_denied_errno"] = attempt(lambda: native_write(root / names["original"], b"must not write"))
        report["old_native_rename_denied_errno"] = attempt(lambda: os.rename(root / names["original"], root / names["moved"]))
        report["old_native_delete_denied_errno"] = attempt(lambda: os.unlink(root / names["original"]))
        report["old_unchanged_under_guard"] = a.read(old) == original
        report["stage_collision_errno"] = attempt(lambda: a.rename(stage, names["original"]))
        report["collision_preserved_both"] = a.read(old) == original and a.read(stage) == payload
        a.rename(old, names["recovery"])
        report["recovery_identity_retained"] = a.info(old)[:2] == old_identity
        report["old_name_absent_errno"] = attempt(lambda: b.close(b.open(names["original"])))
        a.rename(stage, names["original"])
        report["published_identity_retained"] = a.info(stage)[:2] == identity
        published = b.open(names["original"])
        report["published_read_matches"] = b.read(published) == payload
        b.close(published)
        a.close(verifier)
        a.disconnect()
        a = Client(library)
        published = a.open(names["original"], READ | DELETE, SHARE_READ)
        recovered = a.open(names["recovery"], READ | DELETE, SHARE_READ)
        report["reconnected_published_matches"] = a.info(published)[:2] == identity and a.read(published) == payload
        report["reconnected_previous_matches"] = a.info(recovered)[:2] == old_identity and a.read(recovered) == original
        report["protected_cleanup_errno"] = library.probe_delete(a.context, recovered)
        a.close(recovered)
        report["recovery_removed_errno"] = attempt(lambda: b.close(b.open(names["recovery"])))
        a.close(published)

        stage = a.open(names["stage"], READ | DELETE, SHARE_READ | SHARE_WRITE, True)
        native_write(root / names["stage"], payload)
        verifier = a.open(names["stage"], READ, SHARE_READ | SHARE_DELETE)
        old = a.open(names["original"], READ | DELETE, SHARE_READ)
        a.rename(old, names["recovery"])
        competitor = b.open(names["original"], READ, ALL, True)
        report["competing_create_collision_errno"] = attempt(lambda: a.rename(stage, names["original"]))
        report["competitor_preserved"] = b.info(competitor)[2] == 0
        report["recovery_preserved_after_collision"] = a.read(old) == payload
        report["stage_preserved_after_collision"] = a.read(stage) == payload
        b.close(competitor)
        a.rename(stage, names["conflict"])
        report["conflict_copy_matches"] = a.read(stage) == payload
        a.close(verifier)
    except OSError as error:
        report["probe_errno"] = error.errno
    finally:
        a.disconnect()
        b.disconnect()
        report["fixture_prefix"] = prefix
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    args = parser.parse_args()
    expected = Path("/Volumes/tinymounter-m19-edit-test")
    if args.fixture_root != expected or not os.path.ismount(expected):
        parser.error("requires the approved mounted M19 loopback fixture")
    mounts = subprocess.run(["/sbin/mount", "-t", "smbfs"], capture_output=True, text=True, check=True)
    source = "//guest@127.0.0.1/tinymounter-m19-edit-test on " + str(expected) + " ("
    if not any(line.startswith(source) for line in mounts.stdout.splitlines()):
        parser.error("fixture must be the approved native loopback guest mount")
    report = probe(expected, load(args.library))
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
