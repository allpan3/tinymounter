#!/usr/bin/env python3
"""Verify M20 no-replace renames on the approved disposable loopback SMB fixture."""
import argparse
import ctypes as C
import errno
import importlib.util
import json
import os
from pathlib import Path
import platform
import signal
import struct
import subprocess
import sys
import uuid

spec = importlib.util.spec_from_file_location("in_place", Path(__file__).with_name("check-edit-in-place.py"))
in_place = importlib.util.module_from_spec(spec)
spec.loader.exec_module(in_place)
publication = in_place.publication
READ, WRITE, DELETE = in_place.READ, in_place.WRITE, in_place.DELETE


class Client(in_place.Client):
    def name(self, handle):
        buffer = (C.c_ubyte * 4096)()
        count = C.c_uint32()
        error = self.library.probe_name(self.context, handle, buffer, len(buffer), C.byref(count))
        if error:
            raise OSError(error, "query fixture name")
        return bytes(buffer[:count.value]).decode().replace("\\", "/").lstrip("/")

    def entry_name(self, lookup, identity):
        directory = self.directory("")
        try:
            buffer = (C.c_ubyte * 65536)()
            count = C.c_uint32()
            error = self.library.probe_entry(self.context, directory, lookup.encode(), buffer, len(buffer), C.byref(count))
            if error:
                raise OSError(error, "query fixture directory entry")
            data = bytes(buffer[:count.value])
            offset = 0
            matches = []
            while offset < len(data):
                if offset + 80 > len(data):
                    raise ValueError("invalid fixture directory entry")
                next_offset = struct.unpack_from("<I", data, offset)[0]
                size = struct.unpack_from("<I", data, offset + 60)[0]
                if size % 2 or offset + 80 + size > len(data):
                    raise ValueError("invalid fixture entry length")
                file_id = struct.unpack_from("<Q", data, offset + 72)[0]
                birth = struct.unpack_from("<Q", data, offset + 8)[0] // 10 - 11644473600000000
                if [file_id, birth] == identity:
                    matches.append(data[offset + 80:offset + 80 + size].decode("utf-16-le"))
                if not next_offset:
                    break
                if next_offset < 80 + size or next_offset > len(data) - offset:
                    raise ValueError("invalid fixture entry offset")
                offset += next_offset
            if len(matches) != 1:
                raise ValueError("ambiguous fixture directory identity")
            return matches[0]
        finally:
            self.close(directory)


def require(report, key, condition):
    report[key] = bool(condition)
    if not condition:
        raise AssertionError(key)


def crash(args):
    intent = json.loads(args.crash_intent.read_text())
    assert args.crash_intent.name.startswith("rename-intent-")
    library = publication.load(args.library, True, args.fixture_keychain)
    client = Client(library)
    handle = client.open(intent["source"], READ | DELETE, 1)
    assert client.info(handle)[:2] == intent["identity"]
    if args.crash_at == "after":
        client.rename(handle, intent["destination"])
    os.kill(os.getpid(), signal.SIGKILL)


def probe(args):
    root = in_place.validate_fixture()
    library = publication.load(args.library, True, args.fixture_keychain)
    a, b = Client(library), Client(library)
    prefix = "probe-" + uuid.uuid4().hex + "-"
    report = {"macos": platform.mac_ver()[0], "cache_state": "uncontrolled", "passed": False}
    old = bytes(range(256)) * 257
    try:
        source, target = prefix + "original", prefix + "renamed"
        publication.native_write(root / source, old, True)
        reader = b.open(source, READ, 5)
        guard = a.open(source, READ | DELETE, 1)
        identity = a.info(guard)[:2]
        require(report, "source_identity_present", all(identity))
        report["source_writer_errno"] = publication.attempt(lambda: b.close(b.open(source, WRITE)))
        require(report, "source_writer_denied", report["source_writer_errno"] in in_place.SHARING_DENIED)
        report["source_delete_errno"] = publication.attempt(lambda: b.close(b.open(source, DELETE)))
        require(report, "source_delete_denied", report["source_delete_errno"] in in_place.SHARING_DENIED)
        b.close(b.create_stream(source))
        security = a.metadata(guard, True)
        metadata = b.open(source, 0x20000 | 0x40000)
        changed = publication.deny_data_writes(security)
        b.set_metadata(metadata, changed, True)
        b.close(metadata)
        require(report, "live_permission_change_observed", in_place.dacl(a.metadata(guard, True)) == in_place.dacl(changed))
        a.rename(guard, target)
        require(report, "protected_exact_name", a.entry_name(target, identity) == target)
        require(report, "same_original_object", a.info(guard)[:2] == identity)
        require(report, "complete_contents_preserved", a.read(guard) == old)
        require(report, "existing_reader_preserved", b.read(reader) == old)
        require(report, "live_permissions_preserved", in_place.dacl(a.metadata(guard, True)) == in_place.dacl(changed))
        stream = b.stream(target)
        require(report, "attached_stream_preserved", b.read(stream) == in_place.STREAM_CONTENTS)
        b.close(stream)
        b.close(reader)
        a.close(guard)
        reopened = a.open(target, READ | DELETE, 1)
        require(report, "reconnected_identity_and_name", a.info(reopened)[:2] == identity and a.entry_name(target, identity) == target)
        a.close(reopened)

        for label, destination in [("ordinary", prefix + "taken"), ("case", prefix + "TAKEN"),
                                   ("unicode", prefix + "caf\u00e9"), ("unicode-normalized", prefix + "cafe\u0301")]:
            source = prefix + label
            publication.native_write(root / source, old, True)
            if not (root / destination).exists():
                publication.native_write(root / destination, b"competitor", True)
            guard = a.open(source, READ | DELETE, 1)
            before = a.info(guard)[:2]
            code = publication.attempt(lambda: a.rename(guard, destination))
            require(report, label + "_collision_refused", code == errno.EEXIST)
            require(report, label + "_both_preserved", a.read(guard) == old and a.info(guard)[:2] == before
                    and (root / destination).read_bytes() == b"competitor")
            a.close(guard)

        source, destination = prefix + "mixed", prefix + "MIXED"
        publication.native_write(root / source, old, True)
        guard = a.open(source, READ | DELETE, 1)
        identity = a.info(guard)[:2]
        a.rename(guard, destination)
        require(report, "case_only_same_object", a.info(guard)[:2] == identity and a.read(guard) == old)
        require(report, "case_only_exact_name", a.entry_name(destination, identity) == destination)
        a.close(guard)
        guard = a.open(source, READ | DELETE, 1)
        report["handle_query_echoes_open_spelling"] = a.name(guard) == source
        require(report, "case_alias_directory_reports_actual_name", a.entry_name(source, identity) == destination)
        a.close(guard)

        source, destination = prefix + "writer", prefix + "writer-target"
        publication.native_write(root / source, old, True)
        writer = b.open(source, WRITE)
        code = publication.attempt(lambda: a.close(a.open(source, READ | DELETE, 1)))
        require(report, "preexisting_writer_refuses_protection", code in in_place.SHARING_DENIED)
        b.close(writer)
        reader = b.open(source, READ, 1)
        code = publication.attempt(lambda: a.close(a.open(source, READ | DELETE, 1)))
        require(report, "preexisting_reader_without_delete_share_refuses_protection", code in in_place.SHARING_DENIED)
        b.close(reader)
        guard = a.open(source, READ | DELETE, 1)
        publication.native_write(root / destination, b"created after guard", True)
        require(report, "destination_created_after_guard_refused",
                publication.attempt(lambda: a.rename(guard, destination)) == errno.EEXIST)
        require(report, "racing_destination_preserved", (root / destination).read_bytes() == b"created after guard")
        a.close(guard)

        folder = prefix + "parent"
        backing = Path("/Users/Shared/tinymounter-m19-edit-fixture")
        (backing / folder).mkdir(mode=0o755)
        directory = a.directory(folder)
        parent_identity = a.info(directory)[:2]
        code = publication.attempt(lambda: b.close(b.directory(folder, access=0x10081, sharing=7)))
        require(report, "ancestor_rename_denied", code in in_place.SHARING_DENIED)
        require(report, "ancestor_identity_retained", a.info(directory)[:2] == parent_identity)
        a.close(directory)

        source = prefix + "changed"
        publication.native_write(root / source, old, True)
        base = a.open(source)
        base_identity = a.info(base)[:2]
        a.close(base)
        publication.native_write(root / source, b"changed bytes")
        guard = a.open(source, READ | DELETE, 1)
        require(report, "same_object_content_change_detectable", a.info(guard)[:2] == base_identity and a.read(guard) != old)
        a.close(guard)
        os.rename(root / source, root / (prefix + "previous"))
        publication.native_write(root / source, old, True)
        guard = a.open(source, READ | DELETE, 1)
        require(report, "replacement_detectable_even_with_same_bytes", a.info(guard)[:2] != base_identity and a.read(guard) == old)
        a.close(guard)

        for checkpoint in ("before", "after"):
            source, destination = prefix + checkpoint, prefix + checkpoint + "-destination"
            publication.native_write(root / source, old, True)
            seed = a.open(source)
            identity = a.info(seed)[:2]
            a.close(seed)
            intent = args.evidence_dir / ("rename-intent-" + checkpoint + ".json")
            with os.fdopen(os.open(intent, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
                json.dump({"source": source, "destination": destination, "identity": identity}, output)
                output.flush()
                os.fsync(output.fileno())
            child = subprocess.run([sys.executable, __file__, "--library", str(args.library),
                                    "--fixture-keychain", str(args.fixture_keychain),
                                    "--evidence-dir", str(args.evidence_dir), "--crash-at", checkpoint,
                                    "--crash-intent", str(intent)], capture_output=True)
            require(report, checkpoint + "_process_interrupted", child.returncode == -signal.SIGKILL)
            fresh = Client(library)
            try:
                surviving = source if checkpoint == "before" else destination
                missing = destination if checkpoint == "before" else source
                recovered = fresh.open(surviving, READ | DELETE, 1)
                require(report, checkpoint + "_fresh_evidence", fresh.info(recovered)[:2] == identity
                        and fresh.read(recovered) == old and fresh.entry_name(surviving, identity) == surviving)
                require(report, checkpoint + "_other_name_absent",
                        publication.attempt(lambda: fresh.close(fresh.open(missing))) == errno.ENOENT)
            finally:
                fresh.disconnect()
        report["passed"] = True
    except (OSError, AssertionError) as error:
        report["failure"] = str(error) if isinstance(error, AssertionError) else type(error).__name__
        report["errno"] = getattr(error, "errno", None)
        report["ntstatus"] = hex(library.probe_status())
    finally:
        a.disconnect()
        b.disconnect()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-keychain", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--crash-at", choices=("before", "after"))
    parser.add_argument("--crash-intent", type=Path)
    args = parser.parse_args()
    in_place.validate_fixture()
    if args.crash_at:
        crash(args)
        return
    args.evidence_dir.mkdir(parents=True, exist_ok=False)
    result = probe(args)
    (args.evidence_dir / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
