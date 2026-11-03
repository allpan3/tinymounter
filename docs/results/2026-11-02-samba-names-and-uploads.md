# Samba filenames, uploads and saves

## Outcome

The candidate remains VM-only. Signed checks now pass for interrupted-upload continuation,
local recovery export, and Finder copying and Keep Both from read-only locations. Changed
upload prefixes and replaced server files are refused. Repeated saves, Unicode content,
conflict preservation and interrupted-save recovery also pass. Build 08 passes the required
VM checks with 621 tests and one optional skip. Production adoption and physical-Mac
installation remain undecided.

Five read-only 2 GiB downloads, including File Provider handoff, reached a median 222.43 MB/s
against 166.74 MB/s for native staging in this VM. Linux page cache was verified empty before
each sample, and all content hashes matched. Partial reads reached 95.46 MB/s against
194.07 MB/s, below the unchanged 90% target. After removing a duplicate transfer, five writable
full downloads reached 195.30 MB/s against 190.82 MB/s for native staging.
The app refuses network destinations for recovery exports. This prevents the observed export
interaction but does not establish safety for arbitrary external writes through the remaining
native mount. The physical Mac and original NAS remain unchanged.

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
can resume after complete identity and prefix verification, as checked below. The save transaction
retains protected handles, complete content verification, close/reopen checks and retained recovery copies. Initial direct reads
verify and stage serially; no performance result is claimed. Catalog IDs now use SMB IDs, so the
candidate requires a fresh domain and separate bundle. It must not open earlier prototype data.

Focused host package checks passed 61 tests with one optional fixture skip and no failures.
They include interrupted direct uploads, reused IDs with changed birth time, damaged payloads,
short reads, invalid read counts and post-read validation failures. Subsequent VM compilation,
required checks and signed runtime results are recorded below.

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
it still refuses a listing that never stabilizes. The signed follow-up uploaded and acknowledged
a 2,400,000-byte file with matching server contents. Retry Pending Changes then acknowledged
the first upload, and Settings no longer showed pending uploads.

The first read-only 2 GiB fetch transferred the complete remote payload but failed its final
metadata check. That attempt is excluded from successful downloads and performance results. A probe
observed reported creation time changing on the first enumeration of Linux-created directories,
with the other metadata unchanged. The candidate now reads one byte through its protected file
handle before capturing a read version. It permits only creation time to change across that
initial read; file ID, size, link count, attributes, modification time and change time must match.
Later version, receipt and transfer checks remain unchanged. Five fresh file probes confirmed
that only creation time changed on the first read, then stayed stable. The signed update fetched
a fresh Linux-created 2 GiB file successfully, and the Finder-exported payload matched its
independent generation hash. Finder reported a permission error while copying it to the Desktop;
the exported file had all expected bytes and inherited read-only permissions and the immutable
flag. That copy warning remains unresolved.

An offline conflict test preserved the competing server revision and published the complete local
edits as a separate conflict copy. A second test stopped Samba after detecting a stage upload.
The server retained a 196,608-byte partial stage and the untouched original. Retry Pending Changes
published the complete 4,456,513-byte save with the original file ID. The older attempt remained
retired, visible and exportable; its exported bytes matched the completed server file.

That retired record exposed an unrelated-operation bug: the share-wide settlement check blocked
listings, folder creation and file renaming even though the old save could never publish again.
The follow-up permits durably retired saves through that check. It still checks the complete
pending inventory, blocks unsettled publications and preserves path-specific mutation checks.
Retained artifacts and local recovery copies remain protected. Regression assertions cover
durable retirement, blocked active publication and failed retirement with a damaged successor.
Required checks and signed build 04 validate the fix: listings resume, an unrelated folder is
created and named, an ordinary file is renamed, and a 4,194,712-byte upload is acknowledged with
matching server contents while the retired save remains retained. Read-only Finder paste creates
no server item, and its context menu exposes no rename or write action.

A new 64 MiB upload was interrupted after the server received 589,824 bytes. Retry did not
overwrite or acknowledge that partial file. Finder retained the complete pending item under a
second name beside the partial server item. Exporting the pending item produced all 64 MiB with
the original hash. This is a preservation pass, not automatic upload-recovery completion.

During the recovery-export check, the save panel first exported to the native-mounted test share.
The complete exported file arrived, but an empty file with quarantine metadata then appeared at
the completed successor's old stage name. The intended Desktop export subsequently matched the
server contents. The timing and metadata are consistent with the native cache mechanism already
reproduced above; this run did not trace the individual native request. Both artifacts remain for
inspection. This is an unresolved native-mount interaction, not a claim that all mixed-client
cache problems are fixed.

#### Read measurements, 2026-11-03

Signed Release build 04 ran in macOS VM 1 against the encrypted Samba 4.19.5/ext4 fixture in
TinyMounter Samba Test, which has 3.8 GiB RAM. The fixture was a non-sparse 2 GiB random file.
Both tree connections used SMB 3.1.1 with full encryption and signing. Native negotiated
AES-128-GCM/GMAC; direct SMB negotiated AES-128-CCM/CMAC. No security setting was reduced.

Native samples used the existing Release `transfer-bench`, 1 MiB reads, `F_NOCACHE` and a local
APFS staging file. Finder Remove Download preceded each provider sample; every correlated app
request then read 2 GiB plus one metadata-stabilizing byte from SMB. Provider rates use callback
entry to completed staging, before final system handoff. Native rates include open and staging.
Neither is a Finder copy-duration measurement. Server, native-client and local filesystem cache
residency were unverified; the provider copy was evicted through Finder. No builds or hashes ran
during timing. The final native hash check ran after its timer, before the last provider sample.

Order was N1, P1, P2, N2, N3, P3, P4, N4, N5, P5. Rates are decimal MB/s.

| Round | Native staging | Provider callback |
| --- | ---: | ---: |
| 1 | 180.17 | 207.66 |
| 2 | 243.76 | 204.56 |
| 3 | 197.88 | 221.46 |
| 4 | 199.44 | 216.80 |
| 5 | 210.55 | 227.60 |
| Median | 199.44 | 216.80 |

The provider/native median ratio was 1.087. The first and final downloaded exports matched the
independent fixture-generation hash; native source/staging verification also matched. Finder's
read-only export warning recurred. Keep Both in the already-populated export directory failed;
copying to a new empty directory produced all expected bytes with the permission warning.
These preliminary rates do not pass the complete performance gate: controlled cache states,
coordinated handoff timing, writable-mode reads, fully local reads and partial File Provider
throughput remain unmeasured for this build.

A separate direct-library correctness probe read five disjoint 512 MiB ranges of the 3 GiB
fixture, with 64 MiB gaps. All five hashes matched independent Linux reads. Payload traffic was
exactly the requested ranges plus one initial byte. The handle's identity and content metadata
remained stable after the initial read. This verifies bounded transport reads, not File Provider
read-ahead, seek latency or player behavior. The signed build's legacy `source_nocache=true` log
field does not describe direct SMB; source now labels that path `transport=direct_smb` instead.

Private evidence is in `results/single-client-20261103/` on the VM. The initial background log
stream stopped early, so the twenty-save transaction count was recovered with `log show --info`.
A foreground stream records subsequent tests. `full-download-comparison.json` contains all
native samples and correlated provider/direct-read lines. `partial-read-probe.json` records the
range checks. Linux JSON audits record payloads, identities, connections and interrupted stages.
Those initial log streams and interruption monitors stopped. Samba remained running, and pending
records, partial server files and exported copies remained intact. The continuation below resolves
the copy warning and app export interaction and measures end-to-end and partial reads.

#### Recovery and Finder follow-up, 2026-11-03

Signed build 07 ran on the same isolated VMs, with the sandbox unchanged. All required checks
passed with 621 package tests and one optional skip. These are correctness checks with
uncontrolled caches, not performance measurements.

| Case | Observed result |
| --- | --- |
| Original interrupted 64 MiB upload | Retry completed the recorded server file, retained its identity, matched the complete local hash and cleared the pending upload. |
| Fresh upload interrupted at 512 KiB | A changed prefix was refused without modifying it. Replacing the file with another identity was also refused. Restoring the original identity and prefix let Retry finish all 64 MiB with the expected hash. |
| Recovery export to Desktop | The 4,456,513-byte export matched the retained synthetic save and had no immutable flag. |
| Recovery export to the disposable native share | The app refused before creating the destination. Linux confirmed its absence and unchanged private recovery artifacts. |
| Read-only Finder copy and Keep Both | Both copies completed without the earlier warning or error 0. Each had all 104,448 expected bytes, mode 0400 and no immutable flag. |
| Read-only editing | The capability trial refused TextEdit Save, including after Unlock. The final context menu has no Rename or Delete. Provider and app write guards remain enabled. |

An acknowledged upload now reopens the recorded file with exclusive SMB sharing, compares its
identity and every existing byte with the complete retained payload, and appends only missing
bytes. Unknown create replies remain unresolved. Completion still requires flush, close and
reopen verification. Finder retry naming does not change the recorded publication name.

Recovery export checks the destination volume before exclusive creation and again through the
open file before copying. The first implementation tried to open the parent directory, which
the save-panel sandbox grant did not permit. The final implementation uses `statfs` for the
first check and `fstatfs` for the second, without adding entitlements. Existing files are never
replaced.

On this macOS build, removing both write and rename capabilities makes read-only provider files
immutable, and Finder carries that flag into exported copies. Read-only regular files now
advertise write capability but keep read-only POSIX permissions and read-only parent folders.
Both mutation guards still refuse remote changes. A writable-mode-only trial did not fix Keep
Both; a rename-capability trial did, but exposed an inappropriate Rename action. Neither trial
remains in production code.

Evidence includes `runtime-05.log` through `runtime-08.log`, `checks-07.log`,
`copy-final-07.json`, `recovery-export-06.json` and the Linux prefix, replacement, restored-upload
and export-refusal audits. Retired save stages and complete recovery exports remain preserved.

#### Coordinated and partial reads, 2026-11-03

Build 07 used the same encrypted Samba/ext4 share. macOS VM 1 had 8 GiB RAM and nine vCPUs;
the Linux VM had 3.8 GiB RAM. The existing Swift measurement helper ran in an ad-hoc-signed
sandboxed app with user-selected read access. Its Open panel granted only the selected test
file. Selection preceded timing. It did not grant shell access to a provider domain or private
app storage.

Full samples used the non-sparse 2 GiB fixture. Finder Remove Download preceded each provider
sample, and the helper verified zero allocation and the dataless flag before timing. After
coordination returned, it verified 2 GiB allocation and the expected SHA-256 with hydration
disabled. Native controls used 1 MiB reads, `F_NOCACHE`, APFS staging and sync. Their source and
staging checksums ran outside timing. Every Linux file-cache eviction used a read-only descriptor
and `POSIX_FADV_DONTNEED` on the test file only; `mincore` verified zero resident pages before
each sample. Network counters showed about 2.246 GB per provider full read and 4.492 GB per
native sample including its separate verification read. Virtual block counters showed about
2 GiB read per sample. Host and virtual-disk device caches were uncontrolled.

Order was P2, N2, N3, P3, P4, N4, N5, P5, P6, N6. Two picker attempts accidentally reused the
downloaded provider copy because the automation had not activated Remove Download. Their
nonzero initial allocation and absent network traffic identified them as local controls;
they are preserved separately and excluded. A preceding pilot is also separate. No builds
ran during measurements. Rates below are decimal MB/s, including open/handoff overhead.

| Round | Native staging | Provider full download |
| --- | ---: | ---: |
| 2 | 143.18 | 88.45 |
| 3 | 166.74 | 226.43 |
| 4 | 179.93 | 246.54 |
| 5 | 163.61 | 213.96 |
| 6 | 208.98 | 222.43 |
| Median | 166.74 | 222.43 |

The median ratio is 1.334. The first valid pair remains in the series despite being slower.
This passes the read-only full-download comparison for this VM/cache setup, not the complete
performance gate. A warming attempt left only 490,567 of 524,288 pages resident, so it is not
reported as a fully hot-cache result.

Partial samples used five fresh 512 MiB extents of the 3 GiB fixture, separated by 64 MiB gaps.
The helper used 1 MiB `pread` calls and `F_NOCACHE`; native controls used matching reads to a
sink. Linux residency was zero for each requested extent before each arm. Read-ahead beyond
the requested extent was not included in that residency assertion. Order alternated by round.
All provider range hashes matched the independent Linux audits. Each sample allocated 528 MiB,
about 1.031 times the requested bytes, with no whole-file fallback.

| Round | Native sink MB/s | Provider MB/s | Provider first read, s |
| --- | ---: | ---: | ---: |
| 1 | 190.62 | 104.39 | 0.190 |
| 2 | 196.96 | 95.46 | 0.766 |
| 3 | 194.07 | 92.44 | 0.759 |
| 4 | 231.82 | 94.96 | 0.700 |
| 5 | 180.40 | 96.36 | 0.782 |
| Median | 194.07 | 95.46 | 0.759 |

The median ratio is 0.492, below the unchanged 90% target. This is close to the earlier
45.2% seek-priority result, but not a matched old/new-build comparison or a 20-seek/player
latency pass. Evidence is `cold-full-summary.json`, `partial-summary.json`, the individual
provider/native JSON files, `runtime-08.log`, and the Linux cache and counter snapshots.

A writable 2 GiB pilot took 24.243 s and fetched 4 GiB plus two stabilization bytes. The
prototype now stages a protected full read once, verifies its complete local content and
block proof, then rechecks server identity, metadata and security before accepting the
version. Partial verification is unchanged.

Signed build 08 passed all required VM checks with 621 package tests, one optional skip,
no Swift warnings, six SET_INFO cases, 94 edit-status cases, 18 folder-create cases and
7,205 CCM cases. Five interleaved writable full-download pairs used a separate 2 GiB copy of
the same random bytes, the same verified empty Linux file cache, and the same picker/native
methods. The verified edit base survived the app restart for installation. Each provider
sample fetched 2 GiB plus one stabilization byte, allocated the whole file and matched the
expected hash. Order was P1, N1, N2, P2, P3, N3, N4, P4, P5, N5.

| Round | Native staging MB/s | Writable provider MB/s |
| --- | ---: | ---: |
| 1 | 240.78 | 184.40 |
| 2 | 192.51 | 195.30 |
| 3 | 108.59 | 180.45 |
| 4 | 190.23 | 197.34 |
| 5 | 190.82 | 199.15 |
| Median | 190.82 | 195.30 |

The median ratio is 1.023. The native outlier remains included. This passes the writable full
comparison for this VM/cache setup. The earlier single pilot identifies duplicate traffic;
it is not a five-pair speedup baseline. Evidence is `writable-full-summary.json`, the individual
JSON results, `checks-08.log`, `runtime-09.log` and the matching Linux cache/counter snapshots.

Stopping Samba after 140,509,185 payload bytes caused the full-read callback to fail. The helper
received `serverUnreachable` after 1.056 s, with zero allocated bytes and no checksum or success
result. Samba restarted after five seconds. The next complete read succeeded in 10.793 s and
matched the original hash. The failed request therefore did not expose its partial stage as a
complete file. Evidence is `writable-interrupted-08.json`, `writable-recovered-08.json` and the
Linux `tinymounter-read-interruption-08.json` audit.

A competing direct client requested write access without writing any bytes during another signed
full download. The server rejected 48 opens with `STATUS_SHARING_VIOLATION`; opens before and
after the read succeeded. The provider returned the complete expected hash. This checks both
protection during the new read path and release afterward. Evidence is
`competing-write-open-08.json`, its script, and `protected-full-08.json`.

Five fresh 1 MiB reads, 256 MiB apart, then exercised the writable file's retained block proof.
Each requested extent had verified empty Linux page cache. Reader times were 0.795, 0.804,
0.863, 0.869 and 0.821 s. Each allocated 16 MiB and fetched 32 MiB plus one stabilization byte,
covering protected verification and staging. All five hashes matched independent Linux reads.
After a separate app restart and eviction, the first 1 MiB miss again fetched only 32 MiB plus
one byte, completed in 0.770 s and matched the same hash. This confirms use of persisted proof
without another full download. These diagnostic seeks are not a 20-seek/player latency pass.
Evidence is
`writable-seek-01.json` through `writable-seek-05.json`, `runtime-10.log` and the Linux seek audit.
The restart sample is `writable-seek-restart-08.json`, with `protection-runtime-08.log`.

Five fully local 2 GiB reads used the downloaded provider file and its Finder-exported APFS copy,
alternating order with 1 MiB reads and `F_NOCACHE`, without a local cache flush. The provider
times were 0.159, 0.114, 0.109, 0.112 and 0.127 s; the local APFS control took 0.810, 0.825,
0.794, 0.851 and 1.022 s. Both copies had the expected complete hash, and no fetch callback
occurred during the local series. These cache conditions show no local-read penalty; they do
not measure physical SSD throughput. Evidence is `local-summary.json`, the individual JSON
samples and the Desktop checksum record.

The signed update remains installed only in macOS VM 1. Samba is running, diagnostic processes
are stopped, and recovery artifacts and exported copies remain intact. The original NAS and
physical-Mac installation were not changed. Remaining validation limits are fully hot server
cache, the unmet partial-throughput and player-seek targets, broader server/editor compatibility,
and physical hardware. Production adoption requires a separate decision. The single-client
catalog uses different remote identities and needs Start Fresh rather than migration; pending
physical-Mac changes must be completed or exported before any installation.
