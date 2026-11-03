# Samba filenames, uploads and saves

## Outcome

The candidate is not ready for the physical Mac. The approved direct save-stage upload passes
required VM checks and 20 signed repeated saves while ext4 reuses the same stage file ID.
Unicode saves, sharing protection, read-only refusal and interrupted-save retention also pass.
Reads and ordinary new-file uploads remain native.

Two published saves still needed Retry to finish native confirmation. During a later native
upload, an empty file with quarantine metadata appeared at a completed transaction's old stage name.
November 3 probes reproduce both symptoms through stale native SMB caches after direct
mutations. They establish the failure mechanisms, but do not reconstruct the earlier app
events. No fix is verified. These findings keep the Mac update withheld.

## Setup and method

Checks ran on 2026-11-02 in VMPal's macOS VM 1, macOS 27.0.1, and TinyMounter Samba Test,
Ubuntu 24.04.5 with Samba 4.19.5 on ext4. The signed app used the development bundle
`dev.tinymounter.orgcheck`. Test build 05 contained the upload-confirmation fix; build 06 also
contained the close-response fix. Only the temporary test build enabled folder organization.
Normal build gates, sandbox entitlements and deletion policy stayed unchanged.

The original NAS was not modified. The fresh save fixture had plain and accented filenames,
one accented parent folder, U+2126 OHM SIGN and U+F900 CJK COMPATIBILITY IDEOGRAPH. These last
two names had no canonically equivalent twins. A separate test share exposed the fresh fixture
because the earlier share's pending transactions correctly blocked adding another location.

Finder opened files in TextEdit; TextEdit edited and saved them. The Linux backing audit checked
bytes, file IDs and private artifacts independently. Automation access to the new File Provider
location was refused by automatic approval review, so the native consent prompt was declined.
No sandbox or privacy protection was disabled.

The protocol probes ran outside the app with its existing encrypted SMB adapter/library.
Native metadata caches remained warm across repeated creates and deletes. Server and VM disk
caches were uncontrolled. These are correctness checks, with no physical-Mac speed claim or
completed native/direct throughput comparison.

## Findings

### Filename and metadata fixes

Outgoing paths use the native client's composed spelling, with the macOS normalization exclusion
ranges preserved. Server/catalog comparisons follow the same rule. This preserves characters such
as OHM SIGN and compatibility ideographs instead of changing them through unrestricted NFC.

Upload confirmation now records the protected open file's native fingerprint and verified SMB
revision together. A cached directory listing can still contain timestamps from before upload
completion and is not sufficient evidence that the upload failed.

Samba can finalize write timestamps when a handle closes, after a flush. The adapter requests
`SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB`, then reopens and verifies complete identity, content and
metadata equality against that reply. Missing or inconsistent close evidence fails safely.
Stage, backup and publication receipts retain the verified version; artifact cleanup keeps its
exact comparisons. The existing rename verification is unchanged.

| Signed case | Result |
| --- | --- |
| New plain, accented/nested, empty and 2 MiB uploads, build 05 | Correct server bytes; no duplicate Finder items |
| First plain-file save, build 06 | Completed, same server file ID, no retained recovery artifacts |
| Second plain-file save | Failed before stage content write; first saved server version preserved |
| Accented-file save | Completed, same server file ID, correct bytes |
| Unique U+2126 filename | Opened correctly; save hit the staging-open failure and remained local |
| Unique U+F900 filename | Opened and saved correctly; original server file ID preserved |
| Nested fixture after pending stage failures | Listing blocked by pending work; no successful nested-save claim |

The app logs confirm three completed transactions with `conflict=0` and `recovery=false` in the
fresh fixture. Two failed transactions retain empty private stages and complete local saves.
TextEdit showing edited text did not establish that the server received it.

### Native opens after file-ID reuse

The first isolated probe created a protected file through direct SMB, opened it through the
native mount, then deleted it through direct SMB. The first native open passed; the next 19
returned `ENOENT`. Re-listing the folder did not repair them. Native exclusive-create attempts
returned `EEXIST`, confirming that the name existed despite the failed opens. An open with
`O_CREAT` also failed and is not a proposed fix.

Keeping all 20 files alive until the end made all 20 native opens succeed. A further probe
recorded server IDs: after the first successful open of a fresh ID, deleting and reusing that ID
made the next native open fail. Even opening the deleted pathname to observe `ENOENT` did not
prevent the failure on reuse. This isolates file-ID reuse as a trigger. It does not establish
the installed kernel's exact internal cause or all conditions that expire its cached state.

The direct-handle probe then wrote, flushed, closed, reopened and read back 20 separate 2 MiB
stages while ext4 reused the same file ID. All 20 matched the expected digest and retained the
same identity within each transaction. All close-response metadata matched the reopened file.
The probe removed its completed stages. Its competing native opens returned `ENOENT`, so those
attempts do not count as proof of sharing-mode protection.

### Required checks

`Tools/run-checks.sh` passed in macOS VM 1 after the close-response fix: 610 Swift tests, one
optional skip, no failures and no Swift warnings. The suite also passed six SET_INFO cases,
73 edit-status cases, 18 folder-create cases and 7,205 encryption cases. These checks include
malformed/missing close-response handling; they do not replace signed interruption tests.

## Limits and retained state

The follow-up below verifies repeated saves, read-only refusal, fresh nested saves and a
competing edit. Accented rename/move workflows and competing changes specifically during
close/reopen still require signed verification. Earlier pending records and private recovery
files remain intact. Test shares remain available for recovery. No physical-Mac installation
or publication occurred.

NFD-stored names are unsupported by the tested native mount and this adapter on the byte-exact
fixture. This is not a claim about every SMB client. Canonically colliding server names also
cannot be treated as independently representable APFS names. The fresh save fixture avoids
that ambiguity; passing it does not establish general NAS compatibility.

## Evidence

Raw evidence is private under `results/org-checks-20261102/` and the corresponding VM directory
`~/Developer/tinymounter/.local/phase4/org-checks-20261102/`:

- `run-checks-upload-fix.log`, `run-checks-close-fix.log`, `build-05.log`, `build-06.log`.
- `upload-fix-expected.json`, `upload-fix-replica.json`, `upload-fix-runtime.log`.
- `timestamp-probe.json`, `close-info-probe.json`, `close-fix-runtime.log`.
- `native-stage-visibility.json`, `native-stage-no-reuse.json`,
  `native-stage-checked-deletion-fresh.json` and their reproduction scripts.
- `direct-stage-probe.c`, `direct-stage-probe.py`, `direct-stage-results.json`.

Linux audits are `/tmp/tinymounter-close-before.json`,
`/tmp/tinymounter-close-after-plain.json` and `/tmp/tinymounter-close-after-unicode.json`.
The scripts contain disposable fixture paths only; credentials are separate and excluded from
the evidence archive. Reproduce only against a dedicated fixture, with cached test credentials.

## Proposed next step

Decision status: accepted on 2026-11-02; implemented and tested below.

Upload private save-stage contents through the existing direct SMB handle, then retain the
current flush, close-response, full-content verification and recovery transaction. The stage
can keep an exclusive sharing mode throughout upload, instead of admitting a native writer.
This removes the native pathname reopen that failed after server ID reuse. Reads and ordinary
new-file uploads stay native; no new library or server component is proposed.

The existing `Vendor/libsmb2/COPYING` assigns LGPL-2.1-or-later to the library and headers.
The proposal uses that same dynamic library and adds no dependency or licence. Release linkage,
relinking and distribution review remain required as documented in architecture section 5.

After acceptance, implement bounded writes with validated reply counts, progress and cancellation,
then run required checks and signed repeated-save, conflict, interruption and cleanup tests.
Recover or export pending fixture saves before removing their test state. Install on the Mac
only after the candidate passes and the user's pending changes are safe.

## Accepted implementation, 2026-11-02

The user approved the scoped transport change. Private save stages now use their existing SMB
handle for bounded 64 KiB writes, with no native reopen and no second verifier handle. Stages
and backups both retain exclusive sharing protection. Short replies advance by their confirmed
count; zero, oversized, missing and lost replies fail without acknowledging completion.
The existing transaction, full verification, close-response checks and cleanup rules remain.
Required VM checks and signed app results follow; the physical-Mac candidate is still withheld.

## Signed app verification, 2026-11-02

Build 07 used the accepted implementation on the same macOS/Samba/ext4 setup. Its fresh
`tinymounter-stage` share points to a separate disposable fixture. Native metadata caches stayed
warm, and disk caches were uncontrolled. These are correctness checks, not speed measurements.
The required VM checks passed with 610 Swift tests, one optional skip, no failures or Swift
warnings, six SET_INFO cases, 88 edit-status cases, 18 folder-create cases and 7,205 encryption cases.

| Signed case | Result |
| --- | --- |
| 20 successive plain-file saves | All 20 versions reached the server, retaining the original identity. All 20 stages reused one ext4 file ID. No stage or backup remained at the end of the series. |
| Accented, unique U+2126, unique U+F900 and accented-parent saves | Correct bytes and original identities, with cleanup complete. |
| Save an existing file as empty | Zero bytes on the original identity, with cleanup complete. |
| First save of a 2 MiB file after appending a line | Correct published bytes, but native confirmation returned `ENOENT`. Retry completed confirmation and cleanup. |
| Four further saves of that larger file | Completed without intervention; original identity retained. |
| Ordinary native upload, then three saves | Accented new filename and correct bytes on the server; subsequent saves preserved its identity. A separate empty file at an old stage name appeared during the native upload. |
| Read-only mode | TextEdit read the saved content. Unlock followed by Save was refused for lack of permission; server bytes and identity stayed unchanged. Write access was restored afterward. |
| Another SMB client changes the original before publication | The original kept the other client's bytes. The local edit became a separate conflict copy; native confirmation initially returned `ENOENT`, then completed on Retry. |

The conflict check suspended the app after TextEdit had opened the original. TextEdit saved a
local edit, a separate native SMB writer changed the server file, and the app resumed. This
checks preservation of both complete versions; it does not test every close/reopen race.

### Interrupted stage and sharing protection

Isolated test build 08 added a pause after the first acknowledged 64 KiB write, restricted to
the disposable share and an explicit test environment variable. The production source has no
pause hook. While the signed app held the stage, a separate SMB connection attempted read,
write and delete opens. All three received `STATUS_SHARING_VIOLATION`, rather than the native
`ENOENT` seen in the earlier probe.

The app was terminated at that pause. The server still had the unchanged original and a
64 KiB partial stage. After relaunch, macOS resent the complete local edit. A newer transaction
published all 2,240,000 bytes on the original identity. The older partial stage and its complete
local copy remained retained, with the UI reporting that the older save would not upload.
Export through the app produced the full expected size and digest. Build 07 was restored and
its signature verified. No protection or recovery comparison was relaxed.

The two pending build-06 saves were also exported through the app and checked against their
expected text. Their records and remote artifacts remain available. All exports stayed in the
VM's local `Desktop/TinyMounter-retained-build06` folder.

### Remaining failures and next work

Native confirmation happens after direct verification and publication. Both the first larger
save and the conflict publication returned `ENOENT` at this stage and completed on Retry.
Their correct server contents did not by themselves make the initial save successful.
A probe retaining a native metadata-only handle before acquiring exclusive SMB protection
received a sharing violation, so that approach was not adopted.

At 23:32:12 local time, during the ordinary native upload, a new zero-byte file appeared at the
stage name of the larger save completed at 23:29:21. Its ext4 birth time is 23:32:12, and it
carries a quarantine stream but no private-stage ACL xattr. The completed transaction is not
pending, and no SMB open remained on that file when inspected. The evidence does not identify
which client operation created it or prove that file-ID reuse caused it. Preserve this file
and trace the actual create and metadata requests before changing cleanup behaviour.

Next, isolate native confirmation after publication and the operation that recreates the old
stage pathname. Keep exact identity, timestamp and content checks. No wider transport change
has been approved. After resolving these findings, repeat the affected signed cases and finish
the outstanding filename organization checks before preparing a normal Mac build.

Additional private evidence in `results/org-checks-20261102/` includes
`run-checks-direct-stage.log`, `build-07.log`, `build-08.log`, `build-08-fixture.patch`,
`direct-stage-runtime.log`, `native-event-guard.json`, `signed-stage-sharing.json`,
`interruption-expected.json`, `interruption-export-verification.json`, `direct-stage-summary.json`,
`quarantine-stage-stat.txt` and the
`tinymounter-stage-*.json` Linux audits. The runtime audit records all 20 distinct saved
versions and the reused stage identity. Unified-log queries also sampled transaction outcomes
during the run; the final log extraction does not retain every earlier Info event.

## Native cache investigation, 2026-11-03

The same macOS 27.0.1 and Samba 4.19.5/ext4 VMs ran isolated probes in fresh directories on
the disposable stage share. Each probe deliberately warmed native name and file-ID caches;
disk caches were uncontrolled. These are correctness results, not throughput measurements.
Production code and installed build 07 stayed unchanged.

### Recreated stage name

The probe created a private stage through SMB, inspected it through the native mount, and
deleted it through its protected SMB handle. A native exclusive create at a new name then
received the same server file ID. Writing a quarantine attribute through that new descriptor
recreated the deleted stage pathname in all ten trials.

A server syscall trace shows the native client's connection creating the old pathname and
writing its quarantine stream. Linux independently found the correct payload at the new name
and a different, empty inode at the old name. A subsequent native metadata open of the new
name returned size zero while reporting the new file's ID. The probe explicitly wrote the
quarantine attribute; it does not identify the exact automatic request in the earlier app run.

A control that closed the private handle and deleted through the native mount passed all ten
trials despite immediate file-ID reuse. Every new file had the correct native size, and no old
name reappeared. That control is not a production cleanup design: releasing protection before
a pathname deletion would lose the existing identity and race guarantees.

Apple's published SMB code keys cached nodes by server file ID and removes the node from that
table before native deletion, explicitly citing immediate Samba/NetApp ID reuse. Direct deletion
bypasses this native operation. The source supports the probe's explanation; it is not proof
of the installed kernel's exact implementation. See [research W18](../research.md#native-smb-caches-2026-11-03).

### Confirmation after rename

A second probe renamed a protected file to a temporary name, let the native client cache that
name, and renamed it back. The direct client reopened the final name successfully. Native
`getattrlistbulk`, using the app's requested attributes and options, still returned the temporary
name in all ten trials. Native `O_EVTONLY` opens of the final name returned `ENOENT`.

For the last file, listing and open still failed at the one- and five-second checkpoints. At
35 seconds the listing returned the final name and the open succeeded. This is not a universal
cache-expiry bound. Relisting does not guarantee a fresh namespace, so adding a short retry
would not establish correctness.

The signed app's additional large-file save completed with `recovery=false`. Its filesystem
trace shows a successful final native `openat`; the earlier app failure was not reproduced in
that save. The original file identity remained unchanged. The existing empty quarantine file,
retired partial stage and exported recovery copies remain intact.

### Single-client transport experiment

Decision status: accepted on 2026-11-03. The user authorized all work needed in the VM.
Build a separate VM-only prototype in which the existing SMB client
owns remote listing, metadata, reads and writes. Keep the File Provider architecture, scoped
access, sandbox, exact verification and recovery rules. Use a fresh disposable location and
separate test bundle so existing pending records need no migration or removal.

First repeat these cache probes and the signed save, conflict, interruption and new-file cases.
Then compare full downloads, partial reads and uploads with the same VM's native baseline using
the existing benchmark plan. Existing throughput gates stay unchanged; the current serial SMB
helpers do not establish that this design can meet them. Adoption and Mac installation
remain later decisions. No server change or additional library is proposed. The existing
`Vendor/libsmb2/COPYING` still specifies LGPL-2.1-or-later; distribution review remains open.

This experiment extends the private-stage exception within the authorized VM scope.
The installed apps remain unchanged. The `single-smb-client-prototype` branch now routes
catalog listings, file metadata, payload reads and uploads through the existing SMB adapter.
Native mounts still supply the scoped grant, cached credentials, mount lifecycle and directory
change hints. Native root descriptors remain in write admission and deletion settlement; this
experiment does not yet remove the mount infrastructure.

New uploads use exclusive creation and persist file ID plus birth time before writing. A retry
only verifies an already-created file. The save transaction retains protected handles, complete
content verification, close/reopen checks and retained recovery copies. Initial direct reads
verify and stage serially; no performance result is claimed. Catalog IDs now use SMB IDs, so the
candidate requires a fresh domain and separate bundle. It must not open earlier prototype data.

Focused host package checks passed 61 tests with one optional fixture skip and no failures.
They include interrupted direct uploads, reused IDs with changed birth time, damaged payloads,
short reads, invalid read counts and post-read validation failures. App compilation, required VM
checks and signed runtime validation remain pending.

Private evidence is in `results/org-checks-20261102/native-probes-20261103.tar` and
`native-trace-linux-20261103.tar`. The archives contain the probe scripts and results, signed
save logs, server syscall trace and backing-file audits. The final enumeration probe is
`native-rename-bulk-confirm.json`; the quarantine reproduction and native control are
`native-path-quarantine.json` and `native-path-native-delete.json`. Apple source excerpts are
in `apple-smb-cache-excerpts-20261103.txt`; `final-probe-audit.json` confirms the final rename
contents and the native control's metadata placement. All diagnostic processes have stopped; fixture
files remain for inspection, and no server configuration changed.

#### Initial single-client VM check, 2026-11-03

Required VM checks pass: 619 package tests, one optional skip, the Release CLI, project
consistency, warning-free Swift app compilation, six SET_INFO cases, 94 edit-status cases,
18 folder-create cases and 7,205 CCM cases. The separately signed
`dev.tinymounter.singleclient` app runs in macOS VM 1 with fresh state. Its new Samba share
requires encryption for both native and direct clients; earlier fixtures remain intact.

Twenty consecutive signed TextEdit saves of a 2 MiB fixture produced exactly the expected
server contents, retained the original file ID and left no transaction artifacts. During the
last nineteen saves the server audit observed 57 private transaction names using three file
IDs. A Unicode filename/content save also passed. The first upload delivered the complete
payload but failed its post-upload directory refresh, leaving a duplicate pending item in
Finder. It is not an upload acceptance pass. The candidate now discards a listing whose
directory metadata changes during enumeration and retries a complete scan up to three times;
it still refuses a listing that never stabilizes. That follow-up awaits signed validation.

Private evidence is in `results/single-client-20261103/` on the VM. The initial background log
stream stopped early, so the twenty-save transaction count was recovered with `log show --info`.
A foreground stream records subsequent tests. The Linux fixture holds independent payload and
file-ID audits. Interruption, read-only, broader workflow and throughput checks remain pending.
