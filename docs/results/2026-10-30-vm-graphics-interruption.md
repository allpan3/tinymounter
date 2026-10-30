# VM graphics interruption during save checks

Date: 2026-10-30. The M23 callback experiment stopped before its first save checkpoint because
the VM graphical session froze. This attempt establishes no callback ordering or replay behavior.
Command execution still works, so source and core verification can continue.

The signed Currency test app used the checked production source plus isolated callback and
low-space hooks. Setup and arming the pre-publication checkpoint passed on the approved disposable
loopback SMB fixture. Finder opened the synthetic document in TextEdit. The display stopped
updating at about 02:03 local time during the first attempted edit and save. Cache state was
uncontrolled; this was a correctness experiment, with no performance claim.

VMPal repeatedly returned frame 3770 while guest command execution reported later times.
A TextEdit sample showed its main thread waiting in `SLSWindowServerClientSpaceCopyName`.
A WindowServer sample showed a wait through `CompositorMetal`,
`AppleParavirtGPUMetalIOGPUFamily` and `IOConnectCallMethod`. These observations locate the wait;
they do not establish its cause or connect it to a tinymounter defect.

The checkpoint watcher timed out. The task app subsequently exited after SIGTERM. At 02:13,
all five synthetic server files retained their initial identities, sizes and complete digests,
with no extra objects in the test folder. The provider processes and TextEdit remained running.
No VM or shared-daemon restart was performed. The fixture and test location remain for recovery
and eventual teardown; the original NAS was not written.

Private evidence is in the VM session `.local/phase4/m21-20261029`:

- `m23-currency-graphics-interruption.json` records the stopped app and server comparison.
- `m23-currency-prepared-stop-log.jsonl` retains the unsuccessful checkpoint observation.
- `m23-textedit-sample.txt` and `m23-windowserver-sample.txt` retain the process samples.

A VMPal diagnostics archive was collected locally and was not sent. The accepted roadmap
excludes VM and shared-daemon restarts from the fixture approval. A separate restart decision
is pending before resuming graphical checks. After recovery, inspect the saved hook state and
document contents before attempting another edit.
