# Existing-file publication gate

Date: 2026-10-27. Decision status: M19 design accepted; protocol gate pending.

The user approved online editing with conflict preservation and the temporary absence of the
original filename during publication. The fixture-only protocol probe compiles in macOS VM 1.
It has not run against SMB: fresh permission to configure the disposable writable fixture is
pending. Editing remains unsupported in the app.

## Preparation and checks

The probe uses the existing vendored libsmb2 dynamic library and a native loopback mount.
It checks native upload under a direct handle's replacement protection, denial of competing
writes/renames/deletes, two exclusive renames, full readback, identities after reconnect,
protected cleanup and a competing create between the two renames. The client is restricted
to the synthetic M19 loopback share, and the runner verifies the exact mount before starting.
The planned probe leaves its synthetic files for inspection and controlled cleanup.

VM compilation completed without compiler output. Tools/run-checks.sh passed: 232 tests
executed, one optional writable-fixture test skipped, no failures, and successful project,
release CLI, benchmark-validation and unsigned app checks. There were no Swift warnings.
No performance measurement was made; caches were reused and uncontrolled.

The VM's SMB service is unloaded and SMB guest access and guest login are off. No M19 fixture,
sharing change, remote mutation or app installation was performed. The original NAS remains
read-only for agent testing. The physical-Mac installation is unchanged.

## Evidence and next step

Sources are Tools/check-edit-publication.c and Tools/check-edit-publication.py. VM build and
check logs are .local/phase2/m19-probe-build.log and m19-protocol-required-checks.log.
The [accepted design](../phase4-plan.md#m19-online-editing) defines the implementation and
signed-runtime gates after this protocol check. Editor behavior, conflicts, interruptions and
matched recordings remain unverified. No push, publication or physical-Mac install occurred.
