#!/usr/bin/env python3
r"""Parent-operated M22 Finder evidence, prepared source only.

This driver creates one fixture, requests passive app snapshots and compares
evidence. It does not build, sign, install, register, launch, stop, mount, change
the server, perform Finder gestures or clean up. Use only macOS VM 1 in the
existing .local/phase4/m21-20261029 session. Main apps must not run concurrently.
Installation/update needs the parent's separate approval after build/signing.

Candidate hookup, owned by the parent
  Keep the normal TinyMounterApp and LocationController lifecycle. Append the
  Swift helper to LocationController.swift in an isolated candidate source tree
  so its extension can access private members. After launch reconciliation sets
  isReady, start Task { await self.runM22FinderFixture() } once. Do not await its
  command loop in launch(). The setup action calls the existing add API, which
  registers exactly one new task location. The Python driver never registers it.
  Enable SourceReaderBridge.folderOrganizationEnabled only in this candidate.

  Append the same Swift file to FileProviderExtension.swift in that candidate,
  with M22_FINDER_PROVIDER defined only for the provider target. Add these hooks:

  At the first line of modifyItem, shadow its completionHandler:
    let completionHandler = M22FinderProbe.mutation(
        domain: domain.identifier.rawValue, kind: "modify", item: item,
        base: version, fields: changedFields, contents: newContents != nil,
        options: UInt(options.rawValue), reply: completionHandler)
  At the first line of createItem, use the same expression with kind "create",
  item itemTemplate, base nil, fields fields, contents url != nil.
  At the first line of the private fetch method, shadow completion:
    let completion = M22FinderProbe.fetch(domain: domain.identifier.rawValue,
        item: identifier.rawValue, version: version, range: requested,
        reply: completion)
  In enumerator(for:request:), return the existing CatalogEnumerator.make result
  wrapped by M22FinderProbe.enumerator(result, domain: domain.identifier.rawValue,
                                      parent: containerItemIdentifier).
  Keep the original callbacks and their arguments intact. The observers forward
  each call and capture items, parent scopes, anchors, errors and fetch intervals.
  Also capture production modify result=folder_move/result=initial_name and app
  folder_move request/ok logs. A callback alone does not establish its XPC route.

  Review the candidate diff and run required VM checks. No production source or
  generator edits are supplied here. Preserve the signing identity, entitlements
  and sandbox. Do not read or print credentials. Treat any m22_finder_trace_failed
  log, missing hook or missing callback completion as incomplete evidence.

Run sequence
  Use one new uppercase UUID for RUN. EVIDENCE must be a new direct child of
  /Users/user/Developer/tinymounter/.local/phase4/m21-20261029. DEVICE=16777234
  and INODE=63266703 are pinned; the parent must recheck them before preparation.
  With the main app closed, as root:
    python3 Tools/check-folder-move-finder.py prepare --run RUN \
      --evidence EVIDENCE --fixture-device 16777234 --fixture-inode 63266703
  The driver checks the exact username-map and native user mapping. It creates
  probe-m22-finder-RUN with 11 files, each below 64 KiB. It never overwrites a run.

  After separate installation approval, the parent launches the only main app
  with --m22-finder setup RUN. The hook validates M21 Files, its exact record ID,
  loopback endpoint and explicit share-root write bookmark. It checks the remote
  marker, saves all original Settings privately and adds M22 Finder RUN. It
  refuses overlapping roots and preexisting saved keeps inside the new subtree.
  Inspect setup-started.json if setup fails; add can save a record before domain
  registration fails. Do not retry setup blindly or replace original Settings.

  CHANNEL is the actual app group's M22Finder-RUN directory under the VM user's
  Library/Group Containers. Keep it private. config.json holds only fixture IDs;
  original-settings.json with bookmarks stays in the app's private container.
  After config.json and M22Finder-active.json exist, open the fixture in fresh
  Finder windows so the parent enumerators receive the observation wrappers.
  Capture the candidate/build identity, macOS version and before/after screen
  recording in EVIDENCE. Record each gesture's time and result in a parent ledger.

  In Finder, browse every fixture directory to establish all catalog rows. Keep
  Source and Dest open in separate windows. Under Source/Tree, Keep Downloaded
  independent.txt and Inherited; Download Now plain.txt without keeping it.
  Download neighbor.txt too. Leave cold.txt unopened. Do not keep Tree, Source or
  Dest. Wait for downloads and callbacks to finish before the baseline snapshot.
  The expected inherited keep is Inherited/leaf.txt with no independent request.

  Request each snapshot as the VM user, leaving the main app running:
    python3 Tools/check-folder-move-finder.py request --run RUN \
      --channel CHANNEL --label LABEL
  Wait for the printed request's result file to say captured. Do not issue the
  next request or gesture first. A failed or interrupted request is evidence,
  never a reusable label. Snapshots inspect catalogs without listing the share.
  They resolve user-visible URLs, then disable dataless-file materialization on
  the hashing thread before lstat/open/full SHA-256. Dataless/unreadable files
  remain explicitly unverified. No snapshot downloads a file to make it pass.

  If VM command access cannot read the app group, use Finder to copy the entire
  channel into SESSION/m22-finder-captured-LABEL/. Pass its copied path with
  --channel-copy for request or audit, retaining --channel as the original path.
  A request is then written only into that copy; copy the new request file back
  with Finder. For audit, take a new complete copy after the result is captured.
  Keep the earlier copy separately; never overwrite evidence or bypass privacy.

  Capture baseline, then do exactly these parent-operated gestures in order:
    renamed          rename Source/Tree to Renamed
    moved            move Source/Renamed into Dest, preserving its name
    case             rename Dest/Renamed to renamed
    collision-folder attempt to name Dest/renamed Occupied; cancel any Replace
    collision-file   attempt to name Dest/renamed blocked.txt; cancel Replace
    relisted         browse old/new parents and every descendant again
    named            New Folder at the location root, then name it Named
    replay           optional real repeated callback/retry; otherwise leave open
  Take a snapshot and backing audit after each step. Collision dialogs may stop
  Finder before it sends a callback; record that as a missing provider case.
  The newly created folder must remain empty. Its create reply and subsequent
  naming callback must retain one ID. Verify the initial-name route separately.

  As root after each captured snapshot, run:
    python3 Tools/check-folder-move-finder.py audit --run RUN \
      --evidence EVIDENCE --fixture-device 16777234 --fixture-inode 63266703 \
      --channel CHANNEL --label LABEL
  Each audit checks the full task subtree against its original identities,
  modes, owners, file mtimes, xattrs and complete digests. Parent-directory mtimes
  and all ctimes may change during organization. It compares descendant IDs,
  versions, independent/inherited keeps and downloaded local inodes/digests.
  It reports callback/enumeration gaps separately. A catalog arrival or absence
  cannot satisfy a provider enumeration gate. No helper report proves a gesture.

Interpretation and remaining gates
  Keep baseline-to-relisted trace files, including fetches. Any affected fetch
  after baseline means this run cannot prove download preservation, even when
  final bytes match. The hash operation forbids hydration; the trace also exposes
  hydration that happened before hashing. Confirm no trace-failure logs and no
  active fetch at baseline. The initial downloads must have corresponding fetch
  traces, proving that the fetch hook was active. Matching files plus no later
  fetch and the same local inode support preserved copies. This is not a speed run.

  Require completed working-set updates for the moved folder and its known
  descendants, with their original IDs and new parent/name, plus the recording.
  Replicated extensions deliver moves through the working set; macOS ignores
  signals for other containers. Revisit both parents to check their contents.
  Reopening Finder or taking a second snapshot is not mutation replay. Replay
  needs a repeated real modify callback with the same request fields/base and a
  successful unchanged receipt, or stays unverified. Do not call moveFolder or
  core publish directly to substitute for a File Provider callback.

  Recovery/Tree/{preserved,changed}.txt and Recovery/Dest reserve two small files
  for a separate recovery action after the ordinary sequence. Its expected backing
  paths will no longer match this driver's organization audit; use a separate
  evidence report. This driver does not interrupt processes or alter these files.
  A real crash or one-view-only checkpoint needs a reviewed,
  run/item-bound injection and its own parent ledger. Ordinary app restart is
  not a crash, and one registered task location cannot prove two-view recovery.

  For stale edit publication, first establish both files' real downloaded edit
  bases through the provider and keep their editor documents open. At a proven
  post-move/pre-completion checkpoint, the parent may change only changed.txt in
  place after checking its recorded identity, then restart the task app. Require
  a new version and invalidation of the old local bytes for that child. Capture
  actual modifyContents callbacks and their base versions when saving both open
  documents: the preserved base must publish correctly, while the changed base
  must not overwrite the concurrent remote contents and must retain the accepted
  local edit or conflict. An editor reopening the new version is not a stale-base
  test. If a controlled checkpoint or genuine stale callback is unavailable,
  leave both publication gates open. This helper does not close them or the
  previously unavailable ambiguous-name gate. Saved keep-path rewrites were
  covered by the parent's app helper; no artificial saved keeps are added here.

  Keep a cleanup ledger with run/location/domain IDs, fixture.json, channel,
  private original-settings snapshot and any task outboxes. This helper removes
  nothing. After proof, the parent can remove only that task location using the
  normal API and remove proved task files. Never clear other outboxes, restore
  Settings wholesale over later edits, remove another run's active trace pointer,
  touch another share or undo server/mount state through this driver. A failed
  identity check leaves the artifacts for review. Parent updates the results log
  and README with verified and missing gates after the actual VM experiment.
"""

import argparse
import base64
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
GROUPS = Path("/Users/user/Library/Group Containers")
PINNED_ID = (16777234, 63266703)
STAGES = ("baseline", "renamed", "moved", "case", "collision-folder", "collision-file", "relisted", "named", "replay")
PREVIOUS = dict(zip(STAGES[1:], STAGES))
MATERIALIZED = ("neighbor.txt", "Source/Tree/plain.txt", "Source/Tree/independent.txt", "Source/Tree/Inherited/leaf.txt")


def require(value, label):
    if not value:
        raise RuntimeError(label)


def now():
    return datetime.now(timezone.utc).isoformat()


def checked_directory(path):
    require(path.resolve(strict=True) == path, "directory-alias")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode), "directory-required")
    return info


def load(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 4 << 20,
            "bounded-regular-report")
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
    os.link(temporary, path, follow_symlinks=False)
    current = temporary.lstat()
    require((current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino), "temporary-identity")
    temporary.unlink()


def environment(args, check_mapping=True):
    require(platform.system() == "Darwin", "macOS-VM-only")
    require(str(uuid.UUID(args.run)).upper() == args.run, "uppercase-run-UUID")
    user = pwd.getpwnam("user")
    require(user.pw_dir == "/Users/user", "native-user-mapping")
    require(os.geteuid() in (0, user.pw_uid), "fixture-user-or-root")
    checked_directory(SESSION)
    if check_mapping:
        mapping = SESSION / "server/username-map"
        require(mapping.resolve(strict=True) == mapping and stat.S_ISREG(mapping.lstat().st_mode), "map-alias")
        require(mapping.read_text().splitlines() == ["user = _tinymounter_m19", "nobody = _tinymounter_m19_observer"],
                "exact-username-map")
    return user


def fixture(args):
    user = environment(args)
    require(os.geteuid() == 0, "backing-audit-and-prepare-require-root")
    require((args.fixture_device, args.fixture_inode) == PINNED_ID, "session-identity-pin")
    info = checked_directory(FIXTURE)
    require((info.st_dev, info.st_ino) == PINNED_ID, "backing-root-identity")
    evidence = Path(args.evidence)
    require(evidence.is_absolute() and evidence.parent == SESSION, "private-session-evidence-child")
    return user, FIXTURE / ("probe-m22-finder-" + args.run), evidence


def channel(args):
    user = environment(args, check_mapping=False)
    path = Path(args.channel)
    require(path.is_absolute() and path.parent.parent == GROUPS
            and path.name == "M22Finder-" + args.run, "task-app-group-channel")
    if args.channel_copy:
        copied = Path(args.channel_copy)
        require(copied.is_absolute() and copied.parent.parent == SESSION
                and copied.parent.name == "m22-finder-captured-" + args.label
                and copied.name == path.name, "task-Finder-channel-copy")
        path = copied
    info = checked_directory(path)
    require(info.st_uid == user.pw_uid and stat.S_IMODE(info.st_mode) == 0o700, "private-channel-owner")
    config = load(path / "config.json")
    require(config["run"] == args.run, "channel-run")
    for key in ("location", "grant", "domain"):
        require(str(uuid.UUID(config[key])).upper() == config[key], "channel-UUID")
    return path, config


def payloads(run):
    paths = ["neighbor.txt", "Source/Tree/plain.txt", "Source/Tree/independent.txt", "Source/Tree/cold.txt",
             "Source/Tree/Inherited/leaf.txt", "Dest/Occupied/sentinel.txt", "Dest/blocked.txt",
             "Recovery/Tree/preserved.txt", "Recovery/Tree/changed.txt"]
    result = {path: ("m22-finder:" + run + ":" + path + "\n").encode() * 16 for path in paths}
    result["marker.txt"] = ("tinymounter-m22-finder:" + run + "\n").encode()
    result["Source/neighbor.txt"] = ("untouched-source-neighbor:" + run + "\n").encode()
    return result


def inventory(root):
    device = checked_directory(root).st_dev
    result, pending, file_count = {}, [root], 0
    while pending:
        path = pending.pop()
        require(len(result) < 96, "fixture-entry-bound")
        info = path.lstat()
        require(info.st_dev == device, "fixture-filesystem-bound")
        require(stat.S_ISDIR(info.st_mode) or (stat.S_ISREG(info.st_mode) and info.st_nlink == 1),
                "fixture-link-or-special-entry")
        entry = {"device": info.st_dev, "inode": info.st_ino, "mode": stat.S_IMODE(info.st_mode),
                 "uid": info.st_uid, "gid": info.st_gid,
                 "kind": "directory" if stat.S_ISDIR(info.st_mode) else "file"}
        entry["xattrs"] = extended_attributes(path)
        if entry["kind"] == "directory":
            with os.scandir(path) as children:
                for child in children:
                    require(len(pending) < 96, "fixture-directory-bound")
                    pending.append(Path(child.path))
        else:
            file_count += 1
            require(file_count <= 32 and 0 <= info.st_size <= 64 << 10, "fixture-file-bound")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino), "file-open-identity")
                data = stream.read((64 << 10) + 1)
                after = os.fstat(stream.fileno())
            require((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                    == (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                    and len(data) == info.st_size and path.lstat().st_ino == info.st_ino, "file-changed-during-hash")
            entry.update(size=info.st_size, mtime_ns=info.st_mtime_ns, digest=hashlib.sha256(data).hexdigest())
        result[path.relative_to(root).as_posix()] = entry
    return result


def extended_attributes(path):
    # macOS's bundled Python omits os.listxattr and os.getxattr.
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
        result[os.fsdecode(name)] = hashlib.sha256(value.raw[:size]).hexdigest()
    return result


def prepare(args):
    user, root, evidence = fixture(args)
    evidence.mkdir(mode=0o700, exist_ok=False)
    checked_directory(evidence)
    write_new(evidence / "prepare-started.json", {"run": args.run, "date": now(), "fixture": root.name})
    root.mkdir(mode=0o700, exist_ok=False)
    files = payloads(args.run)
    directories = {"Recovery/Dest"}
    for name in files:
        directories.update(str(path) for path in Path(name).parents if str(path) != ".")
    for name in sorted(directories, key=lambda value: (len(Path(value).parts), value)):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    for name, contents in files.items():
        fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
    before_ownership = inventory(root)
    for name, item in before_ownership.items():
        path = root if name == "." else root / name
        info = path.lstat()
        require((info.st_dev, info.st_ino) == (item["device"], item["inode"]), "chown-task-identity")
        os.chown(path, user.pw_uid, user.pw_gid, follow_symlinks=False)
    write_new(evidence / "fixture.json", {"run": args.run, "date": now(), "before": inventory(root),
        "fixture_device": PINNED_ID[0], "fixture_inode": PINNED_ID[1], "cache": "uncontrolled",
        "endpoint": "127.0.0.1/tinymounter-m19-edit-test", "file_count": len(files)})
    print(json.dumps({"prepared": True, "run": args.run, "files": len(files)}))


def request(args):
    path, _ = channel(args)
    require(not (path / (args.label + ".json")).exists(), "snapshot-label-already-used")
    for entry in path.glob("request-*.json"):
        previous = load(entry)
        require(previous["label"] != args.label, "request-label-already-used")
        result = path / ("result-" + previous["id"] + ".json")
        require(result.exists(), "previous-request-unfinished")
        require(load(result)["result"] == "captured", "previous-request-failed")
    token = str(uuid.uuid4()).upper()
    write_new(path / ("request-" + token + ".json"), {"run": args.run, "id": token, "label": args.label})
    print(json.dumps({"requested": args.label, "request": token, "wait_for": "result-" + token + ".json"}))


def moved_path(path, stage):
    target = "Source/Tree" if stage == "baseline" else "Source/Renamed" if stage == "renamed" else (
        "Dest/Renamed" if stage == "moved" else "Dest/renamed")
    original = "Source/Tree"
    return target + path[len(original):] if path == original or path.startswith(original + "/") else path


def rows_by_path(snapshot):
    rows = snapshot["rows"]
    require(len({row["id"] for row in rows}) == len(rows) and len({row["path"] for row in rows}) == len(rows),
            "duplicate-catalog-ID-or-path")
    return {row["path"]: row for row in rows}


def events_until(path, config, cutoff):
    events = []
    for index, entry in enumerate((path / "events").iterdir()):
        require(index < 20_000 and entry.suffix == ".json", "event-bound-or-incomplete-file")
        event = load(entry)
        require(event["run"] == config["run"] and event["domain"] == config["domain"], "event-scope")
        if event["time"] <= cutoff:
            events.append(event)
    return sorted(events, key=lambda event: (event["time"], event["call"]))


def callback_pairs(events, kind):
    starts = {event["call"]: event for event in events if event["kind"] == kind + "-begin"}
    return [(starts[event["call"]], event) for event in events
            if event["kind"] == kind + "-end" and event["call"] in starts]


def organization_pair(events, item, parent, name, succeeds):
    for begin, end in callback_pairs(events, "modify"):
        requested = begin["items"][0]
        if (requested["id"], requested["parent"], requested["name"]) != (item, parent, name):
            continue
        if begin["fields"]["contents"] != "false" or end["fields"]["ok"] != str(succeeds).lower():
            continue
        if not any(begin["fields"][key] == "true" for key in ("changesName", "changesParent")):
            continue
        if not succeeds and end["fields"].get("filenameCollision") != "true":
            continue
        if succeeds and (not end["items"] or any(end["items"][0][key] != value
                         for key, value in (("id", item), ("parent", parent), ("name", name)))
                         or end["fields"]["pendingFields"] != "0" or end["fields"]["fetchContent"] != "false"):
            continue
        return begin, end
    return None


def working_set_delivery(events, expected):
    terminal = {event["call"] for event in events if event["kind"] == "changes-end"
                and event["fields"].get("ok") == "true"}
    delivered = {}
    for event in events:
        if event["call"] not in terminal or event["fields"].get("parent") != "NSFileProviderWorkingSetContainerItemIdentifier":
            continue
        if event["kind"] == "deleted" and any(row["id"] in expected for row in event["items"]):
            return False
        if event["kind"] == "updated":
            delivered.update({row["id"]: row for row in event["items"]})
    return all(all(delivered.get(item, {}).get(key) == value for key, value in values.items())
               for item, values in expected.items())


def audit(args):
    _, root, evidence = fixture(args)
    checked_directory(evidence)
    manifest = load(evidence / "fixture.json")
    require(manifest["run"] == args.run and (manifest["fixture_device"], manifest["fixture_inode"]) == PINNED_ID,
            "manifest-scope")
    current = inventory(root)
    require(current["."] == manifest["before"]["."], "task-root-identity")
    require((root / "marker.txt").read_bytes() == payloads(args.run)["marker.txt"], "task-marker")
    path, config = channel(args)
    snapshot = load(path / (args.label + ".json"))
    baseline = load(path / "baseline.json")
    require(snapshot["config"] == baseline["config"] == config and snapshot["label"] == args.label,
            "snapshot-scope")
    require(snapshot["settingsPreserved"] and baseline["settingsPreserved"], "original-settings-changed")
    expected = {moved_path(name, args.label): value for name, value in manifest["before"].items()}
    if args.label in ("named", "replay"):
        require(current.get("Named", {}).get("kind") == "directory", "newly-named-folder-missing")
        expected["Named"] = (load(evidence / "named-audit.json")["backing"]["Named"]
                             if args.label == "replay" else current["Named"])
    require(current == expected, "backing-inventory-differs-from-expected-move")
    before, after = rows_by_path(baseline), rows_by_path(snapshot)
    require(set(before) == {"" if name == "." else name for name in manifest["before"]}, "baseline-catalog-incomplete")
    require(set(after) == {"" if name == "." else name for name in expected}, "after-catalog-paths")
    if args.label in ("named", "replay"):
        require(after["Named"]["kind"] == "directory" and after["Named"]["parent"] == after[""]["id"]
                and after["Named"]["id"] not in {row["id"] for row in before.values()}, "new-folder-catalog-binding")
    for name, row in before.items():
        target = after[moved_path(name, args.label)]
        require(all(row[key] == target[key] for key in ("id", "kind", "content", "keep", "requested", "size")),
                "catalog-identity-version-or-keep-changed")
        if name:
            parent_path = str(Path(moved_path(name, args.label)).parent)
            require(target["parent"] == after["" if parent_path == "." else parent_path]["id"], "catalog-parent")
    require(before["Source/Tree/independent.txt"]["requested"] and before["Source/Tree/Inherited"]["requested"]
            and before["Source/Tree/Inherited/leaf.txt"]["keep"]
            and not before["Source/Tree/Inherited/leaf.txt"]["requested"], "keep-fixture-not-established")
    require(not any(before[name]["keep"] for name in ("", "Source", "Dest", "Source/Tree", "Source/Tree/plain.txt")),
            "unexpected-parent-or-plain-file-keep")
    require(all(row["listed"] and row["complete"] for row in baseline["rows"] if row["kind"] == "directory"),
            "baseline-listings-incomplete")
    require(not any(move["state"] not in ("completed", "refused") for move in snapshot["moves"]), "pending-folder-intent")
    local_before = {row["item"]: row for row in baseline["local"]}
    local_after = {row["item"]: row for row in snapshot["local"]}
    preserved_names = set(MATERIALIZED) | {name for name, row in before.items()
        if row["kind"] == "file" and local_before.get(row["id"], {}).get("state") == "hashed-with-materialization-off"}
    for name in preserved_names:
        item = before[name]["id"]
        first, last = local_before[item], local_after[item]
        require(first["state"] == last["state"] == "hashed-with-materialization-off", "materialized-copy-unverified")
        require(all(first[key] == last[key] for key in ("device", "inode", "digest", "size")), "local-copy-changed")
        require(last["digest"] == manifest["before"][name]["digest"], "local-copy-differs-from-fixture")
    events = events_until(path, config, snapshot["ended"])
    affected = {row["id"] for name, row in before.items() if name.startswith("Source/Tree/") or name in preserved_names}
    fetches = [event for event in events if event["kind"] == "fetch-begin" and event["fields"]["item"] in affected]
    ended_fetches = {event["call"] for event in events if event["kind"] == "fetch-end" and event["time"] < baseline["started"]}
    gaps = ["parent must confirm before/after recordings and absence of trace-failure logs",
            "stale changed-base and preserved-base edit publication after recovery",
            "real crash and one-view-only interruption", "ambiguous names"]
    for kind in ("fetch", "modify", "create", "enumerate", "changes"):
        begins = [event["call"] for event in events if event["kind"] == kind + "-begin"]
        ends = [event["call"] for event in events if event["kind"] == kind + "-end"]
        if set(begins) != set(ends) or len(begins) != len(set(begins)) or len(ends) != len(set(ends)):
            gaps.append(kind + " trace has an unmatched or duplicate callback")
    baseline_fetches = {event["fields"]["item"] for event in events if event["kind"] == "fetch-end"
                        and event["time"] < baseline["started"] and event["fields"]["ok"] == "true"}
    if not {before[name]["id"] for name in MATERIALIZED}.issubset(baseline_fetches):
        gaps.append("initial required downloads lack completed fetch traces; hook coverage unproved")
    if any(event["time"] >= baseline["started"] or event["call"] not in ended_fetches for event in fetches):
        gaps.append("affected fetch overlaps preservation interval; matching hashes do not prove preserved downloads")
    previous = baseline if args.label == "baseline" else load(path / (PREVIOUS[args.label] + ".json"))
    require(previous["config"] == config and (args.label == "baseline" or previous["ended"] <= snapshot["started"]),
            "snapshot-order")
    interval = [event for event in events if previous["ended"] < event["time"] < snapshot["started"]]
    item = before["Source/Tree"]["id"]
    pair = None
    if args.label in ("renamed", "moved", "case", "collision-folder", "collision-file"):
        name = {"renamed": "Renamed", "moved": "Renamed", "case": "renamed",
                "collision-folder": "Occupied", "collision-file": "blocked.txt"}[args.label]
        parent = after["Source" if args.label == "renamed" else "Dest"]["id"]
        pair = organization_pair(interval, item, parent, name, not args.label.startswith("collision"))
        if pair is None:
            gaps.append("matching completed provider modify callback absent")
        else:
            old_row = next(row for row in previous["rows"] if row["id"] == item)
            if any(pair[0]["fields"].get(field) != base64.b64encode(old_row[key].encode()).decode()
                   for field, key in (("baseContent", "content"), ("baseMetadata", "metadata"))):
                gaps.append("modify callback base differs from the preceding snapshot; inspect intervening changes")
    if args.label == "moved":
        expected = {row["id"]: {"parent": row["parent"], "name": name.rsplit("/", 1)[-1],
                    "content": base64.b64encode(row["content"].encode()).decode()}
                    for name, row in after.items() if name == "Dest/Renamed" or name.startswith("Dest/Renamed/")}
        if not working_set_delivery(interval, expected):
            gaps.append("moved subtree delivery through completed working-set updates")
    if args.label == "relisted":
        require(all(row["listed"] and row["complete"] for row in snapshot["rows"] if row["kind"] == "directory"),
                "relisted-catalog-incomplete")
    if args.label == "named":
        new_id = after["Named"]["id"]
        created = [(begin, end) for begin, end in callback_pairs(interval, "create")
                   if begin["items"][0]["parent"] == after[""]["id"] and begin["fields"]["contents"] == "false"
                   and end["fields"]["ok"] == "true" and any(row["id"] == new_id for row in end["items"])]
        if not created or not organization_pair(interval, new_id, after[""]["id"], "Named", True):
            gaps.append("new-folder create and naming callbacks retaining the same ID")
        gaps.append("parent must record the new-folder naming route with the candidate capability state")
    if args.label == "replay":
        require(snapshot["moves"] == previous["moves"], "replay-folder-history-changed")
        repeated = False
        pairs = callback_pairs(events, "modify")
        for index, (begin, end) in enumerate(pairs):
            if (begin["time"] <= previous["ended"] or end["fields"]["ok"] != "true"
                    or begin["items"][0]["id"] != item or begin["fields"]["contents"] != "false"
                    or not any(begin["fields"][key] == "true" for key in ("changesName", "changesParent"))):
                continue
            repeated |= any(old["items"] == begin["items"] and old["fields"] == begin["fields"]
                            and reply["fields"]["ok"] == "true" and reply["items"] == end["items"]
                            for old, reply in pairs[:index])
        if not repeated:
            gaps.append("no repeated identical real modify callback and receipt")
    else:
        gaps.append("real repeated modify callback/replay")
    report = {"run": args.run, "date": now(), "label": args.label, "result": "automated-state-comparison-matches",
              "finder_gate_closed": False, "gesture_observed_by_helper": False, "cache": "uncontrolled",
              "cold_file_dataless": local_before[before["Source/Tree/cold.txt"]["id"]]["state"] == "dataless",
              "backing": current, "snapshot": snapshot, "matching_modify_call": pair[0]["call"] if pair else None,
              "events_through_snapshot": len(events), "gaps": gaps}
    write_new(evidence / (args.label + "-audit.json"), report)
    print(json.dumps({key: report[key] for key in ("run", "label", "result", "finder_gate_closed", "gaps")}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("prepare", "request", "audit"):
        command = sub.add_parser(name)
        command.add_argument("--run", required=True)
        if name != "request":
            command.add_argument("--evidence", required=True)
            command.add_argument("--fixture-device", type=int, required=True)
            command.add_argument("--fixture-inode", type=int, required=True)
        if name != "prepare":
            command.add_argument("--channel", required=True)
            command.add_argument("--channel-copy")
            command.add_argument("--label", choices=STAGES, required=True)
    args = parser.parse_args()
    try:
        {"prepare": prepare, "request": request, "audit": audit}[args.action](args)
    except Exception as error:
        label = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(json.dumps({"result": "failed", "error": label}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
