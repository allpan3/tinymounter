# VM graphics interruption during save checks

Date: 2026-10-30. The M23 callback experiment stopped before its first save checkpoint because
the VM graphical session froze. This attempt establishes no callback ordering or replay behavior.
An explicitly approved restart restored the display at 02:46. Source and core verification
can continue; the disposable SMB fixture needs recovery before further runtime checks.

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
No restart had been performed at that observation. The fixture and test location remain for recovery
and eventual teardown; the original NAS was not written.

Private evidence is in the VM session `.local/phase4/m21-20261029`:

- `m23-currency-graphics-interruption.json` records the stopped app and server comparison.
- `m23-currency-prepared-stop-log.jsonl` retains the unsuccessful checkpoint observation.
- `m23-textedit-sample.txt` and `m23-windowserver-sample.txt` retain the process samples.

A VMPal diagnostics archive was collected locally and was not sent. The user separately approved
restarting VM 1. The initial graceful request refreshed the display, showing the previously
queued synthetic edit, but did not reboot macOS. An administrator shutdown request then restarted
the VM; `kern.boottime` confirms 02:46:10. Finder's display resumed and process IDs changed.
This does not establish whether File Provider accepted the interrupted save.

The task SMB server and native mount did not survive the reboot. macOS loaded its built-in
SMB listener, which now occupies port 445. The fixture restart guard refused before making
changes. Temporarily unloading that shared service requires separate approval under the test
plan. `approved-restart-after.json` records the boot and blocked fixture restoration. Inspect
the saved hook state and document contents before attempting another edit.
