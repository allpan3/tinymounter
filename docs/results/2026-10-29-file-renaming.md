# File renaming and one write mode

Date: 2026-10-29. Decision status: accepted; implementation verified in macOS VM 1.

M20 permits same-folder renaming of ordinary files with an existing M19 verified revision.
Signed Finder renaming, conflicts and interrupted recovery pass on the disposable SMB fixture.
The original NAS remains read-only during agent testing. The installed M19 build is unchanged.

## Write controls

The UI uses one Read only toggle. New locations default to writable setup;
duplicates inherit their original mode. Writable setup obtains the scoped grant and confirms
the SMB-only writer and temporary-save-file requirements. Existing read-only locations stay
read-only. Legacy creation-only locations keep their access and pending data while offering
Complete Write Setup. Confirmed grants are retained when Read only is selected, and source
changes require fresh authorization. Pending writes block enabling Read only.

Settings version 6 preserves identities, keep lists and grants while adding the mode. Older
builds must refuse this format: they would treat a retained inactive write grant as active.
Catalog creation/editing flags change together so Finder sees one permission change.

## Protocol gate

Setup: macOS VM 1 (27.0.1), disposable loopback-only Samba, authenticated encrypted SMB
connections and 65,792-byte synthetic files. Caches were reused and uncontrolled; this is a
behavior check with no performance claim. Tools/check-file-rename.py passed identity and
complete-content preservation, live permission and attached-stream preservation, existing
readers, source write/delete exclusion, racing destination creates, case and Unicode
collisions, ancestor protection, and changed/replaced source detection. Killing only the
probe process before the request and after remote completion left fresh evidence of the
original object and complete contents at the expected name.

A handle name query and a directory query for a literal name can echo the lookup spelling.
They cannot prove a case-only rename after reconnect. Enumerating the protected directory
returns the stored spelling and server identity, and passes the case-only recovery check.
M20 therefore needs that bounded metadata query during rename verification; its mutation
remains one no-replace handle rename. No copy/delete or temporary-name fallback was added.
The fixture's SMB directory creation produced mode 000 directories. Synthetic ancestor
setup uses the local disposable backing folder, as in M19, before the competing SMB checks.

Private evidence is in VM .local/phase2/m20-rename-20261029/protocol-5. Earlier probe results
retain the failed name-query assumptions and fixture setup diagnostics.

## App integration

Finder's filename-only callback now uses authenticated IPC and the app-owned rename transaction.
The private rename intent includes every affected open catalog. Publication updates each original
item ID and preserves its content version, enumeration key and keeps. Unavailable overlapping
catalogs refuse a new rename; uncertain publication defers reconciliation and prevents removing
any participant. The namespace groups the same server/share across accounts. Alias spellings of
location roots that cannot be matched exactly are refused before publication.

The pending-changes section includes renames and retries. Launch and reconnect also retry them.
Native reads resolve and open under the namespace lock; long legacy reads release that lock once
open. A failed old read cannot replace a newer renamed row's metadata.

## VM verification

Tools/run-checks.sh passes with 281 tests, one optional native-fixture skip, zero failures and
zero Swift warnings. Project generation, the release CLI checks, the unsigned app and the
personalized app build pass. Settings and catalog migration tests retain identities, versions,
keep requests and enumeration anchors. The signed app retains the existing test location.

Normal signed Finder checks pass repeated and case-only renames. The final comparison keeps
the renamed file's local inode, remote inode, full digest, item ID, verified content version
and Keep Downloaded request. An untouched neighbor also matches its original identity and
contents. These local reads forbid hydration. Unverified files refuse renaming without changing
the remote object. Switching Read only on removes creation, editing and rename capabilities;
switching it off restores them without another access picker or safety prompt.

Separate signed fixture instrumentation exercises the production transaction and controller:

- Interrupt before the request, after the server rename before receipt, and after the first
  overlapping catalog commit. Recovery completes each rename and preserves both catalogs'
  IDs, content versions, enumeration rows and keep requests.
- Move the source elsewhere through a competing SMB connection after intent is durable.
  Recovery retains the uncertain intent and blocks permission revocation and removal of both
  participants. Both downloaded copies remain readable. Restoring the exact original through
  SMB lets recovery complete, with both local inodes and full digests unchanged.
- Change source bytes while keeping size, modification time and native identity unchanged.
  Rename is refused and the competing bytes survive. Replacing the source with identical
  bytes is also refused; both the retained original and the replacement survive.
- A destination collision refuses replacement. Read-only access refuses rename. A pending
  content save blocks rename and retains a complete exportable local copy.

The pending-save fixture initially left its payload receipt after removing the verified test
copy. The app correctly blocked further changes. Guarded fixture cleanup removed that receipt
and its metadata; normal signed renames then completed. No product discard path was added.
Instrumentation is confined to an isolated signed archive; the production candidate has no hooks.

Signed checks found and fixed three integration defects. Directory continuation now retains
the wildcard pattern, matching libsmb2. The production-library regression scans 100 entries
over 51 pages twice and verifies matching identities. Verification uses the already admitted
native session for participants on that grant, so a slow handshake cannot reject its own
completion. Repeated Finder callbacks validate the verified content revision and parent while
using the metadata sequence for replay; harmless keep or rename metadata changes no longer
reject them. A completed old callback returns its receipt without repeating the remote rename.

## Recordings and limits

Matched Finder recordings start with the same verified file contents and the same rename keys,
then open the native SMB folder. The isolated M19 baseline retains the old remote name; M20
shows the new name. The baseline has a separate bundle/App Group and synthetic folder. The
M20 folder also contains the interruption-test files. The control recordings use the same
scroll steps and window bounds to show the separate M19 controls and the single M20 toggle.
This is a behavior comparison, with reused uncontrolled caches and no timing claim.

Fixture authentication takes about 20 seconds and can exceed the unchanged 15-second share
health threshold. A temporary Unresponsive status or notification can appear during successful
renames, and new requests can defer. No performance or broader-server compatibility claim
follows. Folder renaming, moves, deletion, Replace, unverified-file renaming and combined
rename/content saves remain unsupported. Physical-Mac M20 behavior and QSpace are unverified.
The physical Mac still runs M19; no M20 installation or publication was performed.

## Cleanup

The three synthetic locations and their keep lists are removed. A normal signed launch reports
zero locations, catalogs, domains, items, keeps and stages, with the original saved connection
retained. The original native SMB mount remains connected and the NAS stayed read-only.
Only the task's three Samba processes were stopped. The fixture mount, backing data, private
Samba database, disposable Keychain and all 20 temporary formulas are removed. Apple sharing
records, service overrides, guest settings and account lists match their saved originals.
Apple SMB remains unloaded; the Keychain search list is restored and its original default remains.

The test apps are closed and their extra copies removed. Obsolete VM builds and temporary
Homebrew files account for about 1.1 GiB in the cleanup's du inventories; this does not measure
host VM-image compaction. The normal verified candidate and useful evidence remain. The user's
Desktop window and Terminal are preserved. Automatic approval review rejected closing two
unidentified Finder windows because they may belong to the user; those windows remain open.
A server-list inspection included an unrelated private connection label in tool output. It is
excluded from retained results, which pass a private-value audit before copying to the host.

## Evidence

Evidence is retained locally in results/m20-renaming-20261029 and the VM session
.local/phase2/m20-rename-20261029. The latter includes protocol-5/result.json,
repeat-rename-checks.log, directory-after-fix.json, the signed interruption/refusal logs,
preservation-comparison.json and runtime-hooks.diff. Private settings snapshots remain in the
VM and must not be shared; the temporary credential is removed. The matched clips are
rename-before.mp4, rename-after.mp4, controls-before.mp4 and controls-after.mp4.
