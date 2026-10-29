#!/usr/bin/env python3
"""Probe the approved same-object save on the disposable M19 loopback fixture."""
import argparse
import ctypes as C
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import signal
import struct
import subprocess
import uuid


spec = importlib.util.spec_from_file_location("publication", Path(__file__).with_name("check-edit-publication.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
READ, WRITE, DELETE = publication.READ, publication.WRITE, publication.DELETE
ALL, HANDLE = publication.ALL, publication.HANDLE
LIMIT = 16 * 1024 * 1024
STREAM_CONTENTS = b"competing synthetic stream\n"
SHARING_DENIED = (errno.EACCES, errno.EBUSY, errno.ETXTBSY, errno.EAGAIN)


def credential(account, keychain):
    result = subprocess.run([
        "/usr/bin/security", "find-internet-password", "-s", "127.0.0.1", "-a", account,
        "-r", "smb ", "-p", "/tinymounter-m19-edit-test", "-w",
    ] + ([str(keychain)] if keychain else []), capture_output=True)
    if result.returncode:
        raise OSError(errno.EACCES, "fixture credential unavailable")
    return result.stdout.rstrip(b"\n")


class Client(publication.Client):
    def __init__(self, library, observer=False):
        if not observer:
            super().__init__(library)
            return
        self.library, self.handles = library, []
        error = C.c_int()
        password = credential("_tinymounter_m19_observer", library.fixture_keychain)
        self.context = library.probe_connect_observer(password, C.byref(error))
        if not self.context:
            raise OSError(error.value, "connect fixture observer")

    def directory(self, name, access=0x81, sharing=3, create=False):
        handle = HANDLE()
        error = self.library.probe_open_directory(self.context, name.encode(), access, sharing, create, handle)
        if error:
            raise OSError(error, "open fixture directory")
        self.handles.append(handle)
        return handle

    def private(self, name, security, access=READ | WRITE | DELETE, sharing=0):
        handle = HANDLE()
        data = (C.c_ubyte * len(security)).from_buffer_copy(security)
        error = self.library.probe_open_private(self.context, name.encode(), access, sharing, data, len(data), handle)
        if error:
            raise OSError(error, "create private fixture file")
        self.handles.append(handle)
        return handle

    def copy(self, source, target, size, stop_after=None):
        key = (C.c_ubyte * 24)()
        error = self.library.probe_resume_key(self.context, source, key)
        if error:
            raise OSError(error, "obtain fixture resume key")
        offset = 0
        while offset < size:
            count = min(1024 * 1024, size - offset)
            response = (C.c_ubyte * 12)()
            error = self.library.probe_copy_chunk(self.context, target, key, offset, offset, count, response)
            if error:
                raise OSError(error, "copy fixture contents")
            if struct.unpack("<III", bytes(response)) != (1, 0, count):
                raise OSError(errno.EIO, "incomplete fixture copy")
            offset += count
            if stop_after is not None and offset >= stop_after:
                return offset
        return offset

    def size(self, handle, size):
        error = self.library.probe_set_size(self.context, handle, size)
        if error:
            raise OSError(error, "set fixture length")

    def stream(self, name):
        handle = HANDLE()
        error = self.library.probe_open_read_stream(self.context, name.encode(), handle)
        if error:
            raise OSError(error, "open fixture stream")
        self.handles.append(handle)
        return handle


def sid(security, field):
    if len(security) < 20 or security[0] != 1:
        raise ValueError("invalid fixture security descriptor")
    offset = struct.unpack_from("<I", security, field)[0]
    if offset < 20 or offset + 8 > len(security):
        raise ValueError("missing fixture SID")
    length = 8 + security[offset + 1] * 4
    if offset + length > len(security):
        raise ValueError("invalid fixture SID")
    return security[offset:offset + length]


def dacl(security):
    offset = struct.unpack_from("<I", security, 16)[0]
    if offset < 20 or offset + 8 > len(security):
        raise ValueError("missing fixture DACL")
    length = struct.unpack_from("<H", security, offset + 2)[0]
    if length < 8 or offset + length > len(security):
        raise ValueError("invalid fixture DACL")
    return security[offset:offset + length]


def private_security(owner=None):
    ace = struct.pack("<BBHI", 0, 0, 8 + len(owner), 0x1F01FF) + owner if owner else b""
    acl = struct.pack("<BBHHH", 2, 0, 8 + len(ace), int(bool(owner)), 0) + ace
    return struct.pack("<BBHIIII", 1, 0, 0x9004, 0, 0, 0, 20) + acl


def contents(tag, size):
    pattern = (tag + bytes(range(256)))
    return (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]


def require(report, key, value):
    report[key] = bool(value)
    if not value:
        raise ValueError("gate failed: " + key)


def checkpoint(report, point, stop_at):
    if point == stop_at:
        report["checkpoint"] = point
        print(json.dumps(report, sort_keys=True), flush=True)
        os.kill(os.getpid(), signal.SIGSTOP)
        raise RuntimeError("stopped fixture must be killed, not resumed")


def probe(root, library, old_size, new_size, scenario, foreign_owner=False, stop_at=None):
    clients = []
    report = {"macos": platform.mac_ver()[0], "cache_state": "uncontrolled", "scenario": scenario,
              "old_size": old_size, "new_size": new_size, "foreign_owner": foreign_owner,
              "passed": False}
    prefix = "probe-" + uuid.uuid4().hex + "-"
    names = {key: prefix + key for key in ("original", "stage", "backup", "work")}
    report["fixture_names"] = names
    old, edit = contents(b"old", old_size), contents(b"edit", new_size)
    report["old_sha256"], report["edit_sha256"] = hashlib.sha256(old).hexdigest(), hashlib.sha256(edit).hexdigest()
    try:
        a = Client(library)
        clients.append(a)
        b = Client(library)
        clients.append(b)
        observer = Client(library, observer=True)
        clients.append(observer)
        if foreign_owner:
            observer.close(observer.open(names["original"], READ | WRITE | DELETE, create=True))
        publication.native_write(root / names["original"], old, not foreign_owner)
        seed = a.open(names["original"])
        original_security = a.metadata(seed, True)
        report["original_identity"] = a.info(seed)[:2]
        a.close(seed)
        public = observer.open(names["original"])
        require(report, "observer_reads_public_file", observer.read(public) == old)
        observer.close(public)

        stage = a.private(names["stage"], private_security(), READ | DELETE | 0x40000, 3)
        created_security = a.metadata(stage, True)
        require(report, "stage_initially_private", dacl(created_security) == dacl(private_security()))
        require(report, "empty_stage_denies_observer", publication.attempt(
            lambda: observer.close(observer.open(names["stage"]))) == errno.EACCES)
        owner = sid(created_security, 4)
        if foreign_owner:
            require(report, "stage_owner_differs_from_original", owner != sid(original_security, 4))
        security = private_security(owner)
        a.set_metadata(stage, security, True)
        require(report, "stage_private_acl", dacl(a.metadata(stage, True)) == dacl(security))
        report["stage_identity"] = a.info(stage)[:2]
        # An independent account must be denied before any private payload is written.
        denied = publication.attempt(lambda: observer.close(observer.open(names["stage"])))
        report["observer_stage_errno"] = denied
        require(report, "observer_stage_denied", denied == errno.EACCES)
        publication.native_write(root / names["stage"], edit)
        verifier = a.open(names["stage"], READ, 1 | 4)
        require(report, "stage_complete", a.read(stage) == edit)
        checkpoint(report, "stage", stop_at)

        reader = b.open(names["original"])
        blocked = publication.attempt(lambda: a.close(a.open(names["original"], READ | WRITE | DELETE, 0)))
        require(report, "existing_reader_blocks_save", blocked in SHARING_DENIED)
        b.close(reader)
        writer = b.open(names["original"], WRITE)
        blocked = publication.attempt(lambda: a.close(a.open(names["original"], READ | WRITE | DELETE, 0)))
        require(report, "existing_writer_blocks_save", blocked in SHARING_DENIED)
        b.close(writer)
        original = a.open(names["original"], READ | WRITE | DELETE, 0)
        identity = a.info(original)[:2]
        report["original_identity"] = identity
        require(report, "base_complete", a.read(original) == old)
        denied = publication.attempt(lambda: b.close(b.open(names["original"], WRITE)))
        require(report, "competing_main_write_denied", denied in SHARING_DENIED)
        denied = publication.attempt(lambda: (root / names["original"]).read_bytes())
        report["native_read_errno"] = denied
        require(report, "native_read_denied_during_save", denied in SHARING_DENIED)
        backup = a.private(names["backup"], security)
        require(report, "backup_private_acl", dacl(a.metadata(backup, True)) == dacl(security))
        report["backup_identity"] = a.info(backup)[:2]
        a.copy(original, backup, old_size)
        a.size(backup, old_size)
        a.flush(backup)
        require(report, "backup_complete", a.read(backup) == old)
        checkpoint(report, "backup", stop_at)

        a.rename(original, names["work"])
        require(report, "normal_name_absent", publication.attempt(lambda: b.close(b.open(names["original"]))) == errno.ENOENT)
        checkpoint(report, "moved", stop_at)
        b.close(b.create_stream(names["work"]))
        changed_security = publication.deny_data_writes(original_security)
        metadata = b.open(names["work"], 0x20000 | 0x40000)
        b.set_metadata(metadata, changed_security, True)
        b.close(metadata)
        require(report, "competing_permissions_changed", dacl(a.metadata(original, True)) == dacl(changed_security))
        report["changed_permissions_digest"] = hashlib.sha256(dacl(changed_security)).hexdigest()

        copied = a.copy(stage, original, new_size, 1024 * 1024 if scenario == "interrupted" or stop_at == "first-chunk" else None)
        report["copied_bytes"] = copied
        checkpoint(report, "first-chunk", stop_at)
        if scenario != "interrupted":
            a.size(original, new_size)
            a.flush(original)
            require(report, "edited_contents_complete", a.read(original) == edit)
            checkpoint(report, "copied", stop_at)
        else:
            require(report, "interrupted_before_completion", 0 < copied < new_size)
            report["copied_before_interruption"] = copied

        require(report, "original_identity_retained", a.info(original)[:2] == identity)
        require(report, "permissions_retained", dacl(a.metadata(original, True)) == dacl(changed_security))
        stream = b.stream(names["work"])
        require(report, "competing_stream_retained", b.read(stream) == STREAM_CONTENTS)
        b.close(stream)
        require(report, "backup_still_complete", a.read(backup) == old)
        if scenario == "collision":
            publication.native_write(root / names["original"], b"competing file", True)
            require(report, "publish_collision", publication.attempt(lambda: a.rename(original, names["original"])) == errno.EEXIST)
        elif scenario == "normal":
            a.rename(original, names["original"])
            require(report, "published_complete", a.read(original) == edit)
            checkpoint(report, "published", stop_at)

        for client in clients:
            client.disconnect()
        a = Client(library)
        clients.append(a)
        observer = Client(library, observer=True)
        clients.append(observer)
        recovered_name = names["original"] if scenario == "normal" else names["work"]
        recovered = a.open(recovered_name, READ | DELETE, 0)
        require(report, "reconnected_identity", a.info(recovered)[:2] == identity)
        expected = edit if scenario != "interrupted" else edit[:copied] + old[copied:]
        require(report, "reconnected_contents", a.read(recovered) == expected)
        require(report, "reconnected_permissions", dacl(a.metadata(recovered, True)) == dacl(changed_security))
        a.close(recovered)
        stream = a.stream(recovered_name)
        require(report, "reconnected_stream", a.read(stream) == STREAM_CONTENTS)
        a.close(stream)
        backup = a.open(names["backup"])
        require(report, "reconnected_old_copy", a.read(backup) == old)
        a.close(backup)
        stage = a.open(names["stage"])
        require(report, "reconnected_new_copy", a.read(stage) == edit)
        a.close(stage)
        require(report, "backup_private_after_disconnect", publication.attempt(lambda: observer.close(observer.open(names["backup"]))) == errno.EACCES)
        require(report, "stage_private_after_disconnect", publication.attempt(lambda: observer.close(observer.open(names["stage"]))) == errno.EACCES)
        if scenario == "collision":
            competitor = a.open(names["original"])
            require(report, "competing_file_preserved", a.read(competitor) == b"competing file")
            a.close(competitor)
        report["passed"] = True
    except (OSError, ValueError) as error:
        report["error"] = type(error).__name__
        report["errno"] = getattr(error, "errno", None)
        report["last_ntstatus"] = hex(library.probe_status())
    finally:
        for client in clients:
            client.disconnect()
    return report


def validate_fixture():
    expected = Path("/Volumes/tinymounter-m19-edit-test")
    if not os.path.ismount(expected):
        raise ValueError("requires the approved mounted M19 fixture")
    mount = subprocess.run(["/sbin/mount", "-t", "smbfs"], capture_output=True, text=True, check=True)
    prefix = "//_tinymounter_m19@127.0.0.1/tinymounter-m19-edit-test on " + str(expected) + " ("
    if not any(line.startswith(prefix) for line in mount.stdout.splitlines()):
        raise ValueError("requires the authenticated native loopback fixture")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--fixture-keychain", type=Path,
                        help="read only the disposable test credentials from this Keychain")
    parser.add_argument("--old-size", type=int, default=8192)
    parser.add_argument("--new-size", type=int, default=4096)
    parser.add_argument("--scenario", choices=("normal", "collision", "interrupted"), default="normal")
    parser.add_argument("--foreign-owner", action="store_true")
    parser.add_argument("--stop-at", choices=("stage", "backup", "moved", "first-chunk", "copied", "published"))
    args = parser.parse_args()
    expected = validate_fixture()
    if args.fixture_root != expected:
        parser.error("requires the approved fixture mount")
    if not 0 <= args.old_size <= LIMIT or not 0 <= args.new_size <= LIMIT:
        parser.error("fixture files are limited to 16 MiB")
    if args.scenario == "interrupted" and args.new_size <= 1024 * 1024:
        parser.error("interruption requires more than one chunk")
    library = publication.load(args.library, authenticated=True, keychain=args.fixture_keychain)
    report = probe(expected, library, args.old_size, args.new_size, args.scenario, args.foreign_owner, args.stop_at)
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
