#!/usr/bin/env python3
"""Kill only the disposable M19 probe and check evidence-based recovery through SMB."""
import argparse
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import struct
import subprocess
import uuid


spec = importlib.util.spec_from_file_location("edit_probe", Path(__file__).with_name("check-edit-in-place.py"))
edit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(edit)
MOUNT = Path("/Volumes/tinymounter-m19-edit-test")
STOPS = ("stage", "backup", "moved", "first-chunk", "copied", "published")


def save_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())


def recover(library, receipt, pending):
    names = receipt["fixture_names"]
    old = edit.contents(b"old", receipt["old_size"])
    new = pending.read_bytes()
    result = {"passed": False, "checkpoint": receipt["checkpoint"]}
    clients = []
    try:
        a = edit.Client(library)
        clients.append(a)
        edit.require(result, "local_pending_complete", hashlib.sha256(new).hexdigest() == receipt["edit_sha256"])
        for key, contents in (("stage", new), ("backup", old)):
            if key + "_identity" not in receipt:
                continue
            h = a.open(names[key], edit.READ | edit.DELETE, 0)
            edit.require(result, key + "_identity", a.info(h)[:2] == receipt[key + "_identity"])
            edit.require(result, key + "_complete", a.read(h) == contents)
            a.close(h)

        found = {}
        for key in ("original", "work"):
            try:
                h = a.open(names[key], edit.READ | edit.DELETE, 0)
            except OSError as error:
                if error.errno != errno.ENOENT:
                    raise
                continue
            found[key] = (h, a.info(h)[:2], a.read(h))
        own = [(key, data) for key, data in found.items() if data[1] == receipt["original_identity"]]
        edit.require(result, "one_original_object", len(own) == 1)
        key, (h, identity, contents) = own[0]
        if "changed_permissions_digest" in receipt:
            actual = hashlib.sha256(edit.dacl(a.metadata(h, True))).hexdigest()
            edit.require(result, "current_permissions_retained", actual == receipt["changed_permissions_digest"])
        complete_new, complete_old = contents == new, contents == old
        if key == "original":
            result["action"] = "acknowledge" if complete_new else "unchanged" if complete_old else "retain"
        elif not complete_new and not complete_old:
            result["action"] = "retain"
        elif "original" in found:
            result["action"] = "retain_conflict"
        else:
            a.rename(h, names["original"])
            edit.require(result, "restored_identity_and_contents", a.info(h)[:2] == identity and a.read(h) == contents)
            result["action"] = "restore_new" if complete_new else "restore_old"
            key = "original"
        for h, _, _ in found.values():
            a.close(h)
        if "changed_permissions_digest" in receipt:
            stream = a.stream(names[key])
            edit.require(result, "attached_stream_retained", a.read(stream) == edit.STREAM_CONTENTS)
            a.close(stream)
        expected = {"stage": "unchanged", "backup": "unchanged", "moved": "restore_old",
                    "first-chunk": "retain", "copied": "restore_new", "published": "acknowledge"}
        edit.require(result, "recovery_matches_evidence", result["action"] == expected[receipt["checkpoint"]])
        observer = edit.Client(library, observer=True)
        clients.append(observer)
        for key in ("stage", "backup"):
            if key + "_identity" in receipt:
                denied = edit.publication.attempt(lambda: observer.close(observer.open(names[key])))
                edit.require(result, key + "_still_private", denied == errno.EACCES)
        result["passed"] = True
    except (OSError, ValueError) as error:
        result.update(error=type(error).__name__, errno=getattr(error, "errno", None))
    finally:
        for client in clients:
            client.disconnect()
    return result


def crash(args, library):
    case = args.evidence / ("crash-" + args.crash_at + "-" + uuid.uuid4().hex)
    case.mkdir(mode=0o700)
    pending = case / "pending.data"
    with pending.open("xb") as stream:
        stream.write(edit.contents(b"edit", 8 * 1024 * 1024))
        stream.flush()
        fcntl.fcntl(stream.fileno(), 51)
    pending.chmod(0o400)
    directory = os.open(case, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    command = ["/usr/bin/python3", str(Path(__file__).with_name("check-edit-in-place.py")),
               "--library", str(args.library), "--fixture-keychain", str(args.fixture_keychain),
               "--fixture-root", str(MOUNT), "--old-size", str(4 * 1024 * 1024),
               "--new-size", str(8 * 1024 * 1024), "--stop-at", args.crash_at]
    with (case / "stderr").open("wb") as errors:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors)
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        try:
            if not selector.select(480):
                raise TimeoutError("fixture checkpoint did not arrive")
            line = child.stdout.readline()
            receipt = json.loads(line)
            save_json(case / "receipt.json", receipt)
            if receipt.get("checkpoint") != args.crash_at:
                raise ValueError("fixture failed before requested checkpoint")
            os.kill(child.pid, signal.SIGKILL)
            code = child.wait(timeout=30)
        finally:
            selector.close()
            if child.poll() is None:
                child.kill()
                child.wait(timeout=30)
    result = recover(library, receipt, pending)
    result["probe_killed"] = code == -signal.SIGKILL
    result["passed"] = result["passed"] and result["probe_killed"]
    save_json(case / "recovery.json", result)
    return result


def ancestor(library):
    clients = []
    prefix = "probe-" + uuid.uuid4().hex
    parent, moved = prefix + "-parent", prefix + "-moved"
    child = parent + "/probe-child"
    name = child + "/probe-file"
    result = {"passed": False, "fixture_directories": [parent, child], "fixture_file": name}
    try:
        backing = Path("/Users/Shared/tinymounter-m19-edit-fixture")
        (backing / parent).mkdir(mode=0o755)
        (backing / child).mkdir(mode=0o755)
        a, b = edit.Client(library), edit.Client(library)
        clients.extend((a, b))
        edit.publication.native_write(MOUNT / name, b"synthetic ancestor payload", True)
        active = b.directory(parent, edit.DELETE, edit.ALL)
        blocked = edit.publication.attempt(lambda: a.close(a.directory(parent)))
        edit.require(result, "existing_rename_handle_blocks_guard", blocked in edit.SHARING_DENIED)
        b.close(active)
        guards = [a.directory(path) for path in ("", parent, child)]
        identities = [a.info(h)[:2] for h in guards]
        for index, path in enumerate((parent, child)):
            blocked = edit.publication.attempt(lambda: b.close(b.directory(path, edit.DELETE, edit.ALL)))
            edit.require(result, "ancestor_rename_denied_" + str(index), blocked in edit.SHARING_DENIED)
        blocked = edit.publication.attempt(lambda: os.rename(MOUNT / parent, MOUNT / moved))
        result["native_rename_errno"] = blocked
        edit.require(result, "native_ancestor_rename_denied", blocked in edit.SHARING_DENIED)
        h = a.open(name)
        edit.require(result, "original_path_and_contents", a.read(h) == b"synthetic ancestor payload")
        a.close(h)
        edit.require(result, "ancestor_identities_retained", identities == [a.info(h)[:2] for h in guards])
        result["passed"] = True
    except (OSError, ValueError) as error:
        result.update(error=type(error).__name__, errno=getattr(error, "errno", None))
    finally:
        for client in clients:
            client.disconnect()
    return result


def stream_names(data):
    result, offset = [], 0
    while offset + 24 <= len(data):
        next_offset, length, _, _ = struct.unpack_from("<IIQQ", data, offset)
        if length % 2 or offset + 24 + length > len(data):
            raise ValueError("invalid fixture stream information")
        result.append(data[offset + 24:offset + 24 + length].decode("utf-16-le"))
        if not next_offset:
            return result
        if next_offset < 24 + length:
            raise ValueError("invalid fixture stream offset")
        offset += next_offset
    raise ValueError("incomplete fixture stream information")


def cleanup(library, receipt_path):
    receipt = json.loads(receipt_path.read_text())
    names = receipt["fixture_names"]
    result = {"passed": False, "fixture_names": names}
    clients = []
    try:
        a, b = edit.Client(library), edit.Client(library)
        clients.extend((a, b))
        original = a.open(names["original"], edit.READ, 1)
        edit.require(result, "published_identity", a.info(original)[:2] == receipt["original_identity"])
        edit.require(result, "published_complete", a.read(original) == edit.contents(b"edit", receipt["new_size"]))
        stage = a.open(names["stage"], edit.READ | edit.DELETE, 0)
        edit.require(result, "stage_identity", a.info(stage)[:2] == receipt["stage_identity"])
        edit.require(result, "stage_complete", a.read(stage) == edit.contents(b"edit", receipt["new_size"]))
        edit.require(result, "stage_has_no_attached_data", stream_names(a.metadata(stage, False)) == ["::$DATA"])
        denied = edit.publication.attempt(lambda: b.close(b.open(names["stage"], edit.DELETE)))
        edit.require(result, "competing_stage_delete_denied", denied in edit.SHARING_DENIED)
        error = library.probe_delete(a.context, stage)
        if error:
            raise OSError(error, "delete proved fixture stage")
        a.close(stage)
        edit.require(result, "proved_stage_removed", edit.publication.attempt(
            lambda: a.close(a.open(names["stage"]))) == errno.ENOENT)

        b.close(b.create_stream(names["backup"]))
        backup = a.open(names["backup"], edit.READ | edit.DELETE, 0)
        edit.require(result, "backup_identity", a.info(backup)[:2] == receipt["backup_identity"])
        edit.require(result, "backup_complete", a.read(backup) == edit.contents(b"old", receipt["old_size"]))
        edit.require(result, "changed_artifact_detected", stream_names(a.metadata(backup, False)) != ["::$DATA"])
        a.close(backup)
        stream = a.stream(names["backup"])
        edit.require(result, "changed_artifact_retained", a.read(stream) == edit.STREAM_CONTENTS)
        a.close(stream)
        edit.require(result, "original_still_complete", a.read(original) == edit.contents(b"edit", receipt["new_size"]))
        result["passed"] = True
    except (OSError, ValueError) as error:
        result.update(error=type(error).__name__, errno=getattr(error, "errno", None))
    finally:
        for client in clients:
            client.disconnect()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-keychain", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--crash-at", choices=STOPS)
    choice.add_argument("--ancestors", action="store_true")
    choice.add_argument("--cleanup-report", type=Path)
    args = parser.parse_args()
    edit.validate_fixture()
    if not args.evidence.is_dir():
        parser.error("requires the approved M19 fixture and existing evidence directory")
    library = edit.publication.load(args.library, authenticated=True, keychain=args.fixture_keychain)
    if args.crash_at:
        result = crash(args, library)
    else:
        result = cleanup(library, args.cleanup_report) if args.cleanup_report else ancestor(library)
        name = "cleanup-" if args.cleanup_report else "ancestors-"
        save_json(args.evidence / (name + uuid.uuid4().hex + ".json"), result)
    print(json.dumps(result, sort_keys=True), flush=True)
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
