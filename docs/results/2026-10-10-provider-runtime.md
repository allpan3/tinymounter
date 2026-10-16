# Signed File Provider runtime experiment

## Outcome

The sandboxed, Personal Team-signed prototype registers a Finder location, lists its fixture,
fetches partial content, and downloads a complete local file. Two nonzero-offset reads matched
the original bytes. Keep Downloaded triggered a full fetch; the 32 MiB SHA-256 matched with
automatic hydration disabled, including after quitting/relaunching the main app.

**NAS-backed hydration is blocked before transfer.** The document-scoped source bookmark
resolves, but the extension's read-only source open returns `EPERM`. macOS logs explicitly
identify a Network Volumes privacy denial: this extension point cannot prompt. Reopening the
saved bookmark in the foreground app succeeded, but did not grant the extension access.
There is no File Provider SMB throughput measurement from this experiment.

## Setup and method

- Local date: 2026-10-10, approximately 22:53–23:18 US/Pacific; raw timestamps also use UTC.
- VMPal `macOS VM 1`, macOS 27.0.1 (26A434), Xcode 27.0, arm64 Release builds.
- Development signing uses the configured Personal Team; both targets retain App Sandbox.
- A 32 MiB random local APFS fixture and the previously authorized 37,605,946,781-byte NAS
  video. NAS: UGREEN/Debian through the user's existing Finder SMB mount, SMB 3.1.1.
  Settings/counters were captured; no mount, server, network, or global SMB setting changed.
- Partial fetch preference: 4 MiB; transfer buffer: 1 MiB; maximum concurrent fetches: two.
- Local provider started dataless with zero allocated blocks. NAS provider also started with
  zero blocks and remained unhydrated after the failed reads. NAS/client cache state is unknown.
- Granted the normal, domain-specific prompt for the benchmark host to read managed files.
  No Full Disk Access, App Data access, privacy database reset, or sandbox exception was added.

Runtime fixes tested:

1. macOS App Group identifier uses `<team-id>.<bundle-id>`. The original `group.…` identifier
   signed but was denied by the group-container service in this configuration.
2. The selected source uses a read-only document-scoped bookmark. Its `.scope` owning document
   stays at a stable inode in the shared App Group, independently of atomic `.json` pin updates.
   App-scoped bookmarks initially failed in the extension with Cocoa error 259.
3. Finder reveal starts/stops access to the security-scoped URL returned by File Provider.
4. `transfer-bench --allow-hydration` explicitly enables only the benchmark process's public
   dataless-file I/O policy. The command runner otherwise inherits OFF and returns `EDEADLK`.
5. Materialization changes the local placeholder's ctime. The opt-in benchmark skips that one
   field only for files initially local and dataless; identity, size and mtime remain checked.
   The extension's actual source, native SMB, and ordinary local files retain strict checks.
6. Capture the fixture fingerprint after bookmark setup. An earlier local setup fingerprint
   failed the source-change check; local source ctime changed during setup. The exact system
   actor responsible was not isolated. Content SHA-256 remained unchanged.
7. Foreground saved-bookmark preflight and Network Volumes usage strings were tested. The
   app's NAS open succeeded; the extension's separate privacy denial persisted.

## Data

These are individual correctness probes, not a throughput series or median performance claim.

| Local operation | Request/result | Provider callback before handoff |
| --- | --- | ---: |
| First range | 256 KiB at offset 12,345; supplied 4 MiB from offset 0 | 12.252 ms |
| Second, previously uncached range | 256 KiB at offset 16,789,561; supplied 4 MiB from offset 16,777,216 | 7.028 ms |
| Pin after metadata update | Full 33,554,432 bytes | 17.115 ms |

The second range took **604.518 ms** in the reader's transfer measurement despite the short
provider callback. This single observation includes scheduling/materialization/reader resumption
outside the callback; it does not identify an unavoidable OS latency or a network speed ceiling.
It is a reason to instrument handoff and resume before claiming streaming performance.

NAS attempts requested 64 MiB, then 256 KiB, at offset 8 GiB. Both failed before source reads
with `source-open / NSPOSIXErrorDomain / 1`; each produced zero successful benchmark records.
The foreground-preflight retry reproduced the explicit TCC refusal at 23:18:17.

## Correctness and limits

- Local whole-file SHA-256:
  `b0ee04757f353f338da004ddc10d7a7fc208b0b8487cc2152a8bb1b595d2432c`.
- First 256 KiB range SHA-256:
  `1dc420e9bfa6c3b6a2f01c9927e5133eaeb6d801715eb207d079b6681d7986cc`.
- Second 256 KiB range SHA-256:
  `8d677517fa03f95d89d2b8dfcd3b5ebde9bd391a6d4b216da4ca1175fc96d18b`.
- Pinning rewrote configuration metadata without breaking the owning document's source access.
  The finished file had 65,536 allocated 512-byte blocks and no dataless flag.
- Initial range attempts include harness failures and are retained as evidence. The first
  successful partial callback preceded the ctime-aware CLI change; its bytes were independently
  verified afterward. The second range passed the corrected CLI and original-source comparison.
- Nine core tests, Release CLI/local checks, signed build/strict signature verification, and the
  unsigned Xcode build passed. No Swift compiler warnings; existing App Intents/signing notices.
- Offline disconnect/reboot, eviction retention, real video playback, physical-Mac speed,
  and production permission/lifecycle behavior remain unverified. Disabling hydration for an
  already downloaded local file is narrower than a full offline test.
- No successful NAS download exists to assess against the proposed 90%-of-native target.
  Earlier 247.2/243.6 MB/s native/staging results remain separate experiments.

## Evidence

- [Local evidence](../../results/provider-local-20261010-225342/): manifest, initial error traces,
  `partial-correctness.json`, `uncached-range.jsonl`, `local-fetch-success.json`,
  `pin-full-correctness.json`, and `after-app-relaunch.json`.
- [NAS evidence](../../results/provider-nas-20261010-231244/): binary hashes/setup, SMB settings
  and counters, failed CLI output, `nas-source-permission-errors.json`,
  `foreground-retry-errors.json`, and `outcome.json`.
- `.build/runtime-swift-test.log`, `.build/runtime-unsigned-build.log`,
  `.build/personal-signing-build.log`. Raw evidence is ignored/private and contains local paths.
- Reproduce with the setup in [prototype.md](../prototype.md), using a fresh local fixture/domain
  and an uncached range with `--allow-hydration`; compare against the original outside timing.

## Next step

Decision status: **proposed**. Test a minimal source-reader broker owned by the foreground app.
The app already has working read-only NAS access. It would validate the requested fixture/range,
read through native SMB, and produce same-volume staging content for the extension over an
authenticated XPC connection. The extension would keep enumeration, materialization and handoff.

Limit the spike to the existing one-file experiment, with the main app kept running. Use opaque
fixture/request IDs, bounded requests and cancellation, validate source versions, and transfer
staging ownership exactly once. Do not accept arbitrary paths or general file operations over
IPC. XPC authorization, group-file handoff, failure cleanup and unchanged-source checks are
runtime gates. A production background helper/launch lifecycle is a separate decision.

First prove one NAS range and compare its bytes. Then interleave five matched native/provider
runs with ingress counters, measure callback-to-reader delays, and investigate extent sizes.
The performance target is unchanged. This changes component ownership, so obtain the user's
decision under the repository's “Decide before you build” rule before implementing the broker.
