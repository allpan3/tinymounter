# Location changes and removal, 2026-10-22

Decision status: verification of accepted behavior under the user's "Install, then go onto the
next step" instruction. The production source did not change.

The signed VM run passed rename, a rejected source change, recovery after interrupted Apply
and Remove, and File Provider off/on across relaunch. A second location's kept copy retained its
file identity and source hash throughout. Re-adding restored the saved keep request; its bytes
matched after an explicit read. Automatic download completion for that re-add remains unverified.
Temporary locations and downloads are removed. Tools/run-checks.sh passed all 192 tests,
project generation, release CLI verification and the unsigned app build, with no Swift warnings.

## Setup

The run used macOS VM 1 on macOS 27.0.1, with two temporary full-share locations on the existing
read-only SMB grant. One existing 73 B file was read and kept in each location. Its contents,
name, folder and connection values are omitted from this log. No source content, sharing,
native mount or network setting changed. Cache state was uncontrolled; no speed is claimed.
Hash verification prohibited hydration. Initial reads and one final read explicitly allowed it.
macOS access prompts were allowed.

Normal checks ran the signed M16 build. The interruption build came from a separate archive
with the same source except two test-only stops, immediately after successful removal of the
old domain in Apply and Remove. It logged an opaque marker and stopped its own app process.
The stopped process was killed, then the same signed test app was opened normally. Shared
system services were never stopped. Strict/deep signatures passed, with unchanged entitlements.
The normal signed build was restored before the provider-switch and final cleanup checks.

## Results

| Check | Result |
| --- | --- |
| Two kept copies | Both matched the source with hydration forbidden. Each had a separate local file identity. |
| Rename A | The renamed location retained its local folder and file identities. B retained its folder/file identities and hash. |
| Apply a nonexistent folder | The app showed an error. Both original copies and their identities remained. Revert cleared the rejected edit. |
| Interrupt Apply into a subfolder | The old domain was removed before the stop. Relaunch reported two records, three catalogs, one registered domain and no failed sequence; reconciliation left two catalogs/domains. B's kept copy stayed intact. |
| Interrupt Apply back to the full share | Relaunch again finished reconciliation. The kept request returned, its copy matched, and B retained its original identity/hash. The restored request used the existing Download Now prompt. |
| Disable File Provider | Both location records stayed. The app showed File Provider is off. Reopening the app kept it off. |
| Enable File Provider again | Both copies matched without hydration and retained their identities. No location was re-added. |
| Interrupt Remove with Save the Keep Downloaded list | Relaunch finished removal, leaving one catalog/location and one kept copy. B's copy retained its original identity/hash. |
| Re-add the removed source | A new location logged one restored pending request, then the catalog held two keeps across the two locations. A stayed unmaterialized after Download Now and the privacy prompt; a later explicit read matched. B was unchanged. Automatic completion is not established by this trial. |
| Normal Remove without saving | A was removed and B's kept copy remained readable with the same identity/hash. Final removal of B left no provider location or download. |

The run found no defect in the tested location-update ordering or isolation behavior. It does
not prove immediate completion of restored downloads. The app correctly showed Requested during
the re-add check. A positive offline state still requires File Provider synchronization, version
and materialization checks. No gate or deadline was changed.

## Cleanup and limits

Final diagnostics show zero catalog files, open catalogs, kept requests, items and stage files,
with the original one share/session retained. No TinyMounter CloudStorage folder or test-path
descriptor remains. Both final removals cleared Save the Keep Downloaded list, and the saved
request from the interrupted removal had already been consumed by the re-add. The provider is
on. Clipboard test text and the temporary private path-selection file were removed. The normal
signed M16 app runs in the VM; Cairndex was untouched. The VM was not restarted.

The message-only audit found no signing, connection, source-path or selected-file name matches
in 334 retained messages. Private evidence stays under VM .local/phase2 and the ignored host
directory results/location-lifecycle-20261022. It includes m17-*-app.json, hydration-forbidden
hash records, filtered provider-switch UI text, cleanup counts and message-only logs. Required
check output is VM .local/phase2/m17-final-checks.log. A final clean relaunch reported zero
records, catalogs and registered domains, with no unknown domain or failed sequence.

A full macOS restart, physical-Mac offline hashes, OS eviction under real system-volume
pressure, broader multi-location load, other accounts/shares and QSpace remain unverified.
M17 does not close those phase 3 gates or authorize writes. Disk-full retry-record pruning
across a location replacement was not exercised; these locations had no blocked downloads.
