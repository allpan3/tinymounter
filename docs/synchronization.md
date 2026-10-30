# Synchronization between File Provider locations and server volumes

Date: 2026-10-11. Decision status: proposed. The user wants this model settled before deciding on
any guard against mounting the same folder both ways. Components follow
[architecture.md](architecture.md); identity and change discovery there (§7) remain the baseline.
Terms follow [ui-design.md §2](ui-design.md#2-terms).

## 1. The problem

One NAS folder can be visible in up to three ways at once:

- **A server volume on this Mac.** The macOS SMB client mounts the share. Every read and write goes
  straight to the NAS.
- **A File Provider location.** tinymounter's replica: metadata snapshots plus downloaded
  copies, served locally and offline.
- **Everyone else.** Other Macs, phones, media servers and anything else that writes to the share.

To a File Provider location, a change made through this Mac's server volume is no different from
a change made by another device. Both edit the source of truth behind its back. So the design never
asks which view is "right"; it makes the File Provider location converge on the NAS quickly and
safely. If that works, mounting a folder both ways needs no guard, as the user prefers.

## 2. Rules

1. **The NAS is the truth.** A File Provider location never invents remote state, and in the
   read-only phase it never writes to the NAS.
2. **Never show stale or mixed content as current.** A file is served only at a version the
   extension can still validate. Ranges from two versions are never combined.
3. **Uncertainty is never deletion.** A timeout, permission error or partial listing never
   removes items. Only a complete, successful listing that lacks an item is deletion evidence.
4. **"Available offline" means verified.** A kept file is available offline only after its
   current version is fully downloaded and checked. A kept file whose remote version changed shows
   "Update in progress", not "Available offline", until the new version is complete.
5. **Later, with writes: conflicts become copies.** Two edits are never silently merged, and the
   NAS copy is never overwritten when it changed since our base.

## 3. What a File Provider location tracks

Per item, in the planned per-domain database:

- Stable identity: an opaque UUID mapped to the remote path, plus identity evidence such as the SMB
  file ID where it proves stable. Stability across rename, replace and reconnect still needs
  testing on the user's Samba.
- A **remote fingerprint**: size, modification time, change time and file ID.
- The **content version** handed to File Provider, derived from that fingerprint.
- Per directory, the generation of the last complete listing.

## 4. Discovering changes

Use several triggers, each cheap. None is trusted alone.

| Trigger | Catches | Latency target (proposed) |
| --- | --- | --- |
| FSEvents on this Mac's server volume, for folders that also have a File Provider location | Changes made through the server volume on this Mac | ≤ 5 s |
| SMB `CHANGE_NOTIFY` on watched directories: enumerated, holding downloaded items, or pinned | Changes by other devices, if the server delivers them | ≤ 30 s |
| Revalidation on access: listing when Finder enumerates, fingerprint before serving a fetch | Anything the watches missed, at the moment it matters | immediate |
| Reconciliation on wake, reconnect and app launch | Everything that changed while offline or asleep | after reachability is proven |
| Periodic reconciliation with backoff; pinned trees on a slower budget | Silent servers, missed notifications | minutes |

Unverified assumptions, to test before relying on them: that FSEvents reports this Mac's own writes
on an SMB mount, and that Samba delivers `CHANGE_NOTIFY` for the user's share. Neither is relied on
for correctness; revalidation on access and reconciliation remain the safety net.

## 5. Applying changes

**New, renamed or deleted items.** Record the change in the database's change log, then signal the
affected container so the system enumerates the change. Match a rename by file ID plus fingerprint.
If identity is ambiguous, treat it as delete plus create; that's safe, though a pin on the old item
won't carry over automatically. Deletion follows rule 3.

**A file changed on the NAS.**

- **Not downloaded:** publish the new version; nothing else changes.
- **Downloaded, not pinned:** publish the new version. The old local copy is never served as
  current. Open it again and it downloads anew; the old copy is evicted.
- **Pinned:** publish the new version and download it eagerly. Show "Update in progress" until it's
  complete and verified, then "Available offline" again. If the network drops mid-update, the item
  isn't available offline. Whether the user can still open the old copy offline is an open question.
- **Partly downloaded:** the old ranges are invalid. Fetches use strict versioning and fail with
  "version no longer available" rather than mixing versions; the system then refetches.

**A file changing while it's read.** The extension checks the fingerprint when it opens the source
and after each range. A change detected mid-transfer fails that fetch and never publishes the
mixed bytes. A change that preserves size and timestamps can't be detected from fingerprints. That
limit is stated, not hidden: plain SMB has no immutable revisions to compare.

**A pinned file deleted on the NAS while this Mac was offline.** On reconnect, the deletion
follows the NAS. Open decision: delete the local copy outright, or keep it for a while in a "Removed
from NAS" holding area. The holding area is safer but costs disk space and adds a concept.

## 6. Writes, later

Writes through a File Provider location are a later phase
([architecture §8](architecture.md#8-writes-and-offline-editing-later)). The same model extends to
them:

- Every local change goes into a durable outbox with its **base fingerprint**.
- Before committing an edit, the uploader must validate the base and use a safe conditional
  publication operation. A `stat` followed by ordinary `rename` is not atomic compare-and-swap
  and is insufficient. The accepted [M18 plan](phase4-plan.md) starts with new files and folders,
  without replacing existing items. Its [native publication gate](results/2026-10-23-upload-publication.md)
  failed on the VM SMB fixture. M18 subsequently implemented exclusive creation with the
  user's accepted partial visibility of new uploads. Existing-file editing has an accepted
  [M19 design](phase4-plan.md#m19-online-editing) with an accepted SMB-only writer boundary
  after the exclusion [gate](results/2026-10-27-edit-publication.md). That replacement route
  subsequently failed concurrent metadata preservation. A
  [Mac-only revision](phase4-plan.md#revised-mac-only-save-proposal) was approved on 2026-10-28;
  its [CLI protocol gate](results/2026-10-28-same-object-save.md) passed on the disposable Samba
  fixture. Signed checks of editor saves, conflicts, recovery retention and local export pass.
  Partial work stays unresolved. The fixture is removed and original settings are verified.
  M18 does not authorize partial overwrites.
- If the NAS fingerprint differs from the base, the edit becomes a conflict copy, for example
  `Report (conflict, Mac, 2026-10-12 14.03).docx`. Both versions survive.
- Delete-versus-edit: if the NAS deleted a file this Mac edited, the edit is uploaded as a new file.
  The proposed [M26 offline scope](roadmap.md#m26-offline-editing) instead retains it for explicit
  recovery/export, without recreating the old pathname. That policy awaits roadmap acceptance;
  deliberate offline editing is not an implemented guarantee.
- Writes through a server volume need nothing: they're already on the NAS. To a File Provider
  location they're one more remote change, handled as in section 5.

## 7. Folders and multiple views

- A File Provider location can be rooted at any share subfolder. Two File Provider locations that
  overlap (`Media` and `Media/Movies`) would both download the same files. Proposal: warn, don't block.
- A server volume always covers a whole share. A server-volume location for one folder is the
  mounted share plus an alias into it, in the [Locations
  folder](ui-design.md#7-locations-folder-one-place-to-navigate).
- One folder can be a server volume and a File Provider location at the same time. Section 4's
  triggers keep the File Provider location consistent with the server volume.

## 8. What this can't promise

- Changes that preserve size and timestamps are invisible to fingerprints.
- If the server reuses file IDs or lacks stable ones, renames degrade to delete plus create.
- While offline, a File Provider location can't know about NAS changes; it reconciles on reconnect.
- How fast other devices' changes appear depends on `CHANGE_NOTIFY` support. The fallback is
  polling with backoff.

## 9. Tests before claiming it works

Run against an isolated, agreed scratch folder on the NAS; the current share is read-only for
testing. Each test should pass while the File Provider location is live, and again after offline
periods:

1. Create, rename, move and delete through the server volume; the File Provider location reflects
   each within the target.
2. Modify a downloaded file and a pinned file; the old content is never served, the pinned copy
   re-downloads and its hash matches.
3. Modify a file during a long partial read; no mixed bytes are published.
4. Make changes while this Mac is offline; reconnect; everything reconciles and nothing is lost.
5. Time out a listing, or fail it with a permission error; no items disappear.
6. With `CHANGE_NOTIFY` disabled or silent, revalidation and polling still converge.

## 10. What phase 2 implements

The [phase 2 plan](phase2-plan.md) builds a read-only subset of this model in M4 and M5. Its
signed VM browsing and reads passed [runtime checks](results/2026-10-14-catalog-browsing-reads.md).
Phase 3 extends that subset with verified offline status, folder keeps and change discovery.

- **Tracked per item:** section 3's fields, in one SQLite catalog per File Provider location. The
  content version is size, mtime and ctime (D1); each transfer still checks device and inode on
  its open descriptor.
- **Rules 1 and 3:** only the app writes the catalog, only from a complete listing of a verified
  mount, and only after `fstatat` showed each missing name gone. Timeouts, permission errors, a
  missing mount and a stopped app change nothing. A listing that would remove every child of a
  folder, remove a kept file or change a kind waits for a complete listing at least 15 s later
  (D5). There is no holding area: that listing deletes a kept file's local copy.
- **Rule 2, for fetches:** each fetch compares the file's fingerprint with the catalog row before
  it reads, and checks the snapshot again after. A change fails the fetch with
  `versionNoLongerAvailable` and updates the row. Ranges from two versions are never combined.
- **Triggers built:** revalidation on access, and reconciliation at app launch and after each
  share recovery. A folder is listed when the system enumerates it: before the first page if it
  was never listed, in the background if its last listing is over 60 s old. Launch and recovery
  list the materialized folders only, one at a time (D6). Each fetch checks the fingerprint.
- **Phase 3 additions:** M13 verifies local availability after provider synchronization; M14
  adds recursive folder requests and aggregate status. M15 adds native SMB directory watches
  through public Dispatch sources, periodic reconciliation and wake refresh. It covers listed
  materialized and kept folders and parents of kept files. Watches are bounded to 64 per session;
  scheduled listings run one at a time, due 60 s after success, with failure backoff. These are
  scheduling policies, not the latency targets proposed in section 4. See the
  [M15 plan](phase3-plan.md#m15-discover-nas-changes-while-the-app-runs) and
  [signed VM results](results/2026-10-19-nas-change-discovery.md).
- **Writes:** M18 adds new files/folders and receipt-backed initial folder naming. M19 adds
  content editing with complete pending copies, verified base receipts and
  conflict copies. Signed VM checks preserve item IDs, keep requests and an independent download.
  Uncertain partial work remains pending and exportable. General remote rename
  matching and local FSEvents integration remain unimplemented. An externally renamed item is
  still a delete plus a create; its keep request does not follow.

**The gap between relistings.** A downloaded copy can stay stale until the next successful
refresh, because the system opens it without asking the extension. Directory events can be
missed, and large sets or failures delay scheduled work. Unvisited unkept trees are not scanned.
Available offline covers the source version last observed by the app, not a continuous guarantee
of NAS freshness. The broader latency targets in section 4 remain proposed.

## 11. Open decisions

- Latency targets: the table in section 4 is a proposal.
- A pinned file deleted on the NAS: delete the local copy, or keep it in a holding area?
- A pinned file that changed remotely: can the user open the old local copy while the update is
  pending offline, clearly labelled?
- Conflict-copy naming, for the later write phase.
- Overlapping File Provider locations: warn or block.
- A scratch folder on the NAS for these tests: which path, and permission to write there.

## M20 known renames (accepted 2026-10-29)

A protected same-folder rename keeps each affected location's item ID, content version and
keep request. The app records those views before publication and updates them under the shared
namespace lock. This applies across saved accounts on the same server/share. Pending renames
block reconciliation and source removal for every recorded view until fresh evidence resolves
them. Unavailable overlapping catalogs or mismatched path spellings refuse a new rename.
External renames still follow the existing discovery rules. Signed VM interruption checks
preserve both overlapping catalogs and their downloaded copies; uncertain recovery blocks both
participants until evidence resolves it. See the [M20 results](results/2026-10-29-file-renaming.md).
