# Samba filenames, uploads and saves

## Outcome

The candidate is not ready for the physical Mac. The approved direct save-stage upload passes
required VM checks and 20 signed repeated saves while ext4 reuses the same stage file ID.
Unicode saves, sharing protection, read-only refusal and interrupted-save retention also pass.
Reads and ordinary new-file uploads remain native.

Two published saves still needed Retry to finish native confirmation. During a later native
upload, an empty file with quarantine metadata appeared at a completed transaction's old stage name.
Its origin is unresolved. These findings keep the Mac update withheld.

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
