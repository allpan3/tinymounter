#!/usr/bin/env python3
"""Check M19's handle and publication assumptions on the approved loopback SMB fixture."""
import argparse
import ctypes as C
import errno
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import uuid


READ = 0x00000001 | 0x00000080 | 0x00020000
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
        self.context = library.probe_connect(library.fixture_password, C.byref(error))
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

    def metadata(self, handle, security):
        buffer = (C.c_ubyte * 65536)()
        count = C.c_uint32()
        error = self.library.probe_metadata(self.context, handle, 7 if security else 0, buffer, len(buffer), C.byref(count))
        if error:
            raise OSError(error, "query fixture metadata")
        return bytes(buffer[:count.value])

    def set_metadata(self, handle, data, security):
        buffer = (C.c_ubyte * len(data)).from_buffer_copy(data)
        error = self.library.probe_set_metadata(self.context, handle, security, buffer, len(buffer))
        if error:
            raise OSError(error, "set fixture metadata")

    def create_stream(self, name):
        handle = HANDLE()
        error = self.library.probe_open_stream(self.context, name.encode(), handle)
        if error:
            raise OSError(error, "create fixture stream")
        self.handles.append(handle)
        error = self.library.probe_write_stream(self.context, handle)
        if error:
            raise OSError(error, "write competing fixture stream")
        return handle


def load(path, authenticated=False):
    library = C.CDLL(str(path))
    library.fixture_password = None
    if authenticated:
        credential = subprocess.run([
            "/usr/bin/security", "find-internet-password", "-s", "127.0.0.1",
            "-a", "_tinymounter_m19", "-r", "smb ", "-p", "/tinymounter-m19-edit-test", "-w",
        ], capture_output=True)
        if credential.returncode:
            raise OSError(errno.EACCES, "test credential unavailable")
        library.fixture_password = credential.stdout.rstrip(b"\n")
    pointer = C.c_void_p
    byte_pointer = C.POINTER(C.c_ubyte)
    declarations = {
        "connect": ([C.c_char_p, C.POINTER(C.c_int)], pointer),
        "disconnect": ([pointer], None),
        "open": ([pointer, C.c_char_p, C.c_uint32, C.c_uint32, C.c_int, byte_pointer], C.c_int),
        "close": ([pointer, byte_pointer], C.c_int),
        "info": ([pointer, byte_pointer, C.POINTER(C.c_uint64)], C.c_int),
        "read": ([pointer, byte_pointer, C.c_uint64, byte_pointer, C.c_uint32, C.POINTER(C.c_uint32)], C.c_int),
        "rename": ([pointer, byte_pointer, C.c_char_p], C.c_int),
        "delete": ([pointer, byte_pointer], C.c_int),
        "flush": ([pointer, byte_pointer], C.c_int),
        "metadata": ([pointer, byte_pointer, C.c_int, byte_pointer, C.c_uint32, C.POINTER(C.c_uint32)], C.c_int),
        "set_metadata": ([pointer, byte_pointer, C.c_int, byte_pointer, C.c_uint32], C.c_int),
        "open_stream": ([pointer, C.c_char_p, byte_pointer], C.c_int),
        "write_stream": ([pointer, byte_pointer], C.c_int),
        "status": ([], C.c_uint32),
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
        writer = b.open(names["original"], WRITE)
        report["existing_writer_blocks_guard_errno"] = attempt(
            lambda: a.close(a.open(names["original"], READ | DELETE, SHARE_READ)))
        b.close(writer)
        old = a.open(names["original"], READ | DELETE, SHARE_READ)
        old_identity = a.info(old)[:2]
        report["old_full_read_matches"] = a.read(old) == original
        old_security, stage_security = a.metadata(old, True), a.metadata(stage, True)
        report["security_descriptor_present"] = bool(old_security) and bool(stage_security)
        report["stage_inherited_security_matches"] = old_security == stage_security
        report["original_stream_info_hex"] = a.metadata(old, False).hex()
        report["stage_stream_info_hex"] = a.metadata(stage, False).hex()
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
        report["last_ntstatus"] = hex(library.probe_status())
    finally:
        a.disconnect()
        b.disconnect()
        report["fixture_prefix"] = prefix
    return report


def probe_backing_access(library):
    root = Path("/Users/Shared/tinymounter-m19-edit-fixture")
    shares = subprocess.run(["/usr/sbin/sharing", "-l", "-f", "json"],
                            capture_output=True, text=True, check=True)
    exported = json.loads(shares.stdout)["tinymounter-m19-edit-test"]
    if root.is_symlink() or exported["path"] != str(root) or not exported["smb_shared"]:
        raise ValueError("requires the approved disposable backing directory")
    name = "probe-" + uuid.uuid4().hex + "-local"
    old, changed, competing = b"old synthetic bytes", b"new synthetic bytes", b"competing file"
    report = {"fixture_prefix": name, "macos": platform.mac_ver()[0],
              "cache_state": "uncontrolled"}
    a, b = Client(library), Client(library)
    try:
        native_write(root / name, old, True)
        guard = a.open(name, READ | DELETE, SHARE_READ)
        identity = a.info(guard)[:2]
        report["before_matches"] = a.read(guard) == old
        report["local_write_errno"] = attempt(lambda: native_write(root / name, changed))
        report["guarded_read_changed"] = a.read(guard) == changed
        report["local_rename_errno"] = attempt(lambda: os.rename(root / name, root / (name + "-moved")))
        if report["local_rename_errno"] == 0:
            native_write(root / name, competing, True)
            report["guarded_rename_after_local_replacement_errno"] = attempt(
                lambda: a.rename(guard, name + "-recovery"))
            current = b.open(name)
            report["competing_path_preserved"] = b.read(current) == competing
            report["guard_identity_retained"] = a.info(guard)[:2] == identity
            report["guard_bytes_changed"] = a.read(guard) == changed
            report["recovery_exists"] = (root / (name + "-recovery")).exists()
            if report["recovery_exists"]:
                report["local_delete_guarded_recovery_errno"] = attempt(
                    lambda: os.unlink(root / (name + "-recovery")))
                report["guard_still_readable_after_unlink"] = a.read(guard) == changed
    except OSError as error:
        report["probe_errno"] = error.errno
    finally:
        a.disconnect()
        b.disconnect()
    return report


def deny_data_writes(security):
    if len(security) < 20 or security[0] != 1:
        raise ValueError("invalid fixture security descriptor")
    offset = struct.unpack_from("<I", security, 16)[0]
    if offset < 20 or offset + 8 > len(security):
        raise ValueError("fixture requires an explicit DACL")
    revision, _, length, count, _ = struct.unpack_from("<BBHHH", security, offset)
    if length < 8 or offset + length > len(security):
        raise ValueError("invalid fixture DACL")
    everyone = bytes.fromhex("010100000000000100000000")
    deny = struct.pack("<BBHI", 1, 0, 8 + len(everyone), WRITE) + everyone
    acl = struct.pack("<BBHHH", revision, 0, length + len(deny), count + 1, 0)
    acl += deny + security[offset + 8:offset + length]
    return struct.pack("<BBHIIII", 1, 0, 0x8004, 0, 0, 0, 20) + acl


def probe_metadata_exclusion(root, library, sharing=SHARE_READ):
    a, b = Client(library), Client(library)
    name = "probe-" + uuid.uuid4().hex + "-metadata"
    payload = b"unchanged synthetic contents\n" * 64
    report = {"fixture_prefix": name, "macos": platform.mac_ver()[0],
              "cache_state": "uncontrolled", "guard_sharing": sharing}
    try:
        native_write(root / name, payload, True)
        guard = a.open(name, READ | DELETE, sharing)
        before = a.info(guard)
        security = a.metadata(guard, True)
        report["security_descriptor_readable"] = bool(security)
        report["data_writer_denied_errno"] = attempt(lambda: b.close(b.open(name, WRITE)))

        def change_date():
            handle = b.open(name, 0x100)
            filetime = (before[5] + 1000000) * 10 + 116444736000000000
            b.set_metadata(handle, struct.pack("<QQQQII", 0, 0, filetime, 0, 0, 0), False)
            b.close(handle)
        report["competing_date_change_errno"] = attempt(change_date)
        report["date_changed_under_guard"] = a.info(guard)[5] != before[5]

        def change_permissions():
            handle = b.open(name, 0x20000 | 0x40000)
            b.set_metadata(handle, deny_data_writes(security), True)
            b.close(handle)
        report["competing_dacl_change_errno"] = attempt(change_permissions)
        report["dacl_changed_under_guard"] = a.metadata(guard, True) != security
        if report["dacl_changed_under_guard"]:
            a.close(guard)
            report["changed_dacl_denies_writer_errno"] = attempt(lambda: b.close(b.open(name, WRITE)))
            handle = b.open(name, 0x40000)
            b.set_metadata(handle, security, True)
            b.close(handle)
            report["restored_dacl_allows_writer_errno"] = attempt(lambda: b.close(b.open(name, WRITE)))
            guard = a.open(name, READ | DELETE, sharing)
            report["dacl_restored"] = a.metadata(guard, True) == security

        streams = a.metadata(guard, False)
        report["competing_stream_create_errno"] = attempt(lambda: b.close(b.create_stream(name)))
        after_streams = a.metadata(guard, False)
        report["streams_changed_under_guard"] = after_streams != streams
        offset = 0
        while offset + 24 <= len(after_streams):
            next_offset, name_size, size, _ = struct.unpack_from("<IIQQ", after_streams, offset)
            stream_name = after_streams[offset + 24:offset + 24 + name_size].decode("utf-16-le")
            if stream_name == ":m19-probe:$DATA":
                report["competing_stream_size"] = size
            if not next_offset:
                break
            if next_offset < 24:
                raise ValueError("invalid fixture stream information")
            offset += next_offset
        report["main_identity_unchanged"] = a.info(guard)[:2] == before[:2]
        report["main_contents_unchanged"] = a.read(guard) == payload
    except OSError as error:
        report["probe_errno"] = error.errno
        report["last_ntstatus"] = hex(library.probe_status())
    finally:
        a.disconnect()
        b.disconnect()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--check-backing-access", action="store_true",
                        help="also exercise server-local access to the disposable fixture")
    parser.add_argument("--authenticated-test-account", action="store_true",
                        help="use the separately approved disposable account's Keychain credential")
    parser.add_argument("--check-metadata-exclusion", action="store_true",
                        help="test competing SMB date, DACL and named-stream changes")
    parser.add_argument("--deny-all-sharing", action="store_true",
                        help="also deny read sharing in the metadata exclusion check")
    args = parser.parse_args()
    expected = Path("/Volumes/tinymounter-m19-edit-test")
    if args.fixture_root != expected or not os.path.ismount(expected):
        parser.error("requires the approved mounted M19 loopback fixture")
    mounts = subprocess.run(["/sbin/mount", "-t", "smbfs"], capture_output=True, text=True, check=True)
    accounts = ("_tinymounter_m19",) if args.authenticated_test_account else ("guest", "guest:")
    sources = tuple("//" + user + "@127.0.0.1/tinymounter-m19-edit-test on " + str(expected) + " ("
                    for user in accounts)
    if not any(line.startswith(sources) for line in mounts.stdout.splitlines()):
        parser.error("fixture must be the approved native loopback mount and account")
    if args.deny_all_sharing and not args.check_metadata_exclusion:
        parser.error("--deny-all-sharing requires --check-metadata-exclusion")
    library = load(args.library, args.authenticated_test_account)
    if args.check_metadata_exclusion:
        report = probe_metadata_exclusion(expected, library, 0 if args.deny_all_sharing else SHARE_READ)
    else:
        report = probe(expected, library)
    if args.check_backing_access:
        report["backing_access"] = probe_backing_access(load(args.library, args.authenticated_test_account))
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
