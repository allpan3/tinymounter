# Finder feedback for Keep Downloaded, 2026-10-19

## Outcome

Kept full-file transfers now show Finder's native progress circle. A file reports transferred
bytes; kept ancestor folders show indeterminate progress while descendant transfers run. The
signed VM comparison showed the original cloud icon before and the circle after. All downloaded
fixture files matched the source with hydration forbidden. All 170 tests and required checks
passed, with no Swift compiler warnings.

The signed Mac update is ready but not installed. The user confirmed folder keeping works in
installed M14; this progress follow-up still needs physical-Mac installation approval. Nothing
was pushed or merged.

## Setup and method

- VMPal macOS VM 1, macOS 27.0.1, build 26A434; Xcode 27.0, build 27A266a.
- Normal signed sandboxed app and extension. The approved isolated VM File Sharing setup was
  reused with a disposable read-only guest share; guest login stayed off.
- Each test tree had a 64 MiB file, a 64 KiB file, an empty file and an empty folder. An independent
  file was 16 MiB. A fresh copy of the tree removed prior explicit-download state from the final
  comparison. The NAS stayed read-only.
- Both recordings right-click the same folder and select Keep Downloaded. The app's reader was
  briefly suspended in short intervals after recording the request in both runs, so the icon
  could be observed. It resumed afterward. Source, filesystem and provider caches were reused;
  these are correctness checks, with no performance claim.

## Implementation and decisions

The custom action still records retention, and macOS still schedules downloads through the
existing content and namespace policies. The extension publishes public Foundation Progress
objects during full-file transfers of kept items. File publications follow the transfer's byte
count. Kept ancestor folders share one indeterminate publication across concurrent descendants;
no folder percentage is inferred from an incomplete tree.

Completion, failure or cancellation releases that transfer's publication. A folder publication
stays while another descendant transfer still uses it. Extension invalidation clears all
publications, and a late URL response cannot publish a finished transfer. The URL comes from
the domain manager and its security scope ends when the publication ends. Partial-file reads
are unchanged. No settings format, entitlement or transfer policy changed.

The indicator starts when a full-file transfer starts, so initial folder enumeration can still
precede it. It can disappear between separate transfers. It is a read-only indicator; Pause
Downloads remains the control for background transfers. The icon does not establish Available
offline; Settings continues to verify that separately.

An explicit native download request succeeded inside the signed extension but did not show the
folder circle in the probe. That probe code was removed. The SDK says replicated providers'
item download flags are ignored. Public Progress publication produced the native circle
([research A13](../research.md#apple-file-provider)).

## Verification and limits

| Check | Observed result |
| --- | --- |
| Matched Finder comparison | Original build kept the cloud icon; final build showed the circle during the same folder action |
| Folder completion | Circle cleared after transfers ended; all three files in each tree matched source hashes with hydration forbidden |
| Keep a new file while paused | File stayed dataless and no active circle appeared; Resume downloaded it |
| Independent kept file | Complete bytes matched the source with hydration forbidden |
| Full VM checks | 170 tests, zero failures; project generation, benchmark checks, release CLI and unsigned app builds passed; no Swift warnings |
| Message-only log audit | 229 retained messages; zero tested private mounted-share values, signing-team values or path patterns |

Pause attempts during active copies completed after the copies had ended, so cancellation-time
icon removal was not verified at runtime. Fast file copies also did not establish an intermediate
percentage. Physical-Mac feedback, offline reads and restart persistence remain unverified.

Several registered test copies made an early comparison use the wrong extension. That recording
was discarded. The final comparison rebuilt the versions at the same path, checked the baseline
binary had no progress publisher, and restored Finder's registration before the final run.
Xcode's automatic signing rejected its saved account and identity. System certificate trust and
direct signing succeeded with the existing identity and unchanged sandbox entitlements.

## Cleanup and evidence

The fixture location, requests, downloads, server entry, mount, SMB share and source folder were
removed. Original share definitions matched the snapshot exactly. SMB was unloaded, SMB guest
access was disabled, and guest login stayed off. The original saved NAS connection remained.
Final diagnostics showed zero catalogs, kept items and stage files, with one share and session.
No VM restart or network change was made. Cairndex was untouched.

- VM `.local/phase2/m14-progress-final-checks.log`, `m14-progress-compile.log`,
  `m14-progress-final-hashes.json`, `m14-progress-verified.json`, `m14-progress-cleanup.json`,
  `m14-progress-final-diagnostics.json`, `m14-progress-runtime-messages.ndjson` and
  `m14-progress-log-audit.json`.
- Matched local recordings and inspected contact sheets:
  `results/keep-download-progress-20261019/{before,after}.mp4` and `{before,after}-contact.png`.
  The crops show only disposable fixture rows.
- Signed Mac build: `.build/xcode-personal/Build/Products/Release/TinyMounterPrototype.app`.
  Strict/deep signature verification passed with the installed bundle ID and entitlements.
  The ready copy's build registrations were removed; the installed M14 app and extension still
  run from Applications. Local evidence is `results/keep-download-progress-20261019/host-ready-state.json`
  and `host-signed-build.log`. The ready build was not installed or opened.

## Follow-up, 2026-10-19

The user approved installing the progress indicator together with the Settings status-refresh
fix. The signed update is installed and running from Applications; its extension matches the
ready build. The existing location and three keep requests remain. Physical-Mac feedback on
these fixes remains open. See the [status-refresh results](2026-10-19-keep-status-refresh.md).
