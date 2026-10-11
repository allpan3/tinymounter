# Native SMB and local staging: first NAS experiment

Measured 2026-10-10, approximately 21:32–21:35 US/Pacific (UTC records are dated 2026-10-11). This experiment covers native SMB and local staging only. File Provider, direct SMB libraries, competitor apps, and video playback were not measured.

## Outcome

Five interleaved pairs of 2 GiB reads gave a native read-to-sink median of **247.2 MB/s** and native read-to-local-staging median of **243.6 MB/s**. Staging retained **98.5%** of the native median throughput. On this setup and workload, buffered APFS staging did not impose anything like the previously reported 10–80 MB/s integrated-drive rates.

This supports proceeding to the File Provider experiment. It does not demonstrate 98.5% throughput through File Provider, establish a platform speed ceiling, or diagnose another application's slowdown.

## Setup and method

- Development VM: `macOS VM 1`, VirtualMac2,1, macOS 27.0.1 build 26A434, 8 GiB RAM, 9 virtual CPUs.
- NAS: user's UGREEN running Debian, existing native mount `/Volumes/<share>`. No NAS configuration, source content, mount options, signing, encryption, or network settings were changed.
- Source: one existing 37,605,946,781-byte MKV; the full local path is in the private results manifest. Directory enumeration and source reads only; no whole-video copy was retained.
- SMB: version 3.1.1. `SMB_CURR_ENCRYPT_ALGORITHM` reported `OFF`; `SMB_CURR_SIGN_ALGORITHM` reported `AES_128_GMAC`. The log also reports signing support. An algorithm/support field alone is not independent packet-level verification of signing enforcement; no packet trace was collected.
- Multichannel enabled, with one active connection observed. Client interface advertised 990 Mb/s and the server advertised 10 Gb/s. Measured throughput exceeded 990 Mb/s, so the VM's advertised interface speed is not treated as a throughput cap or proof of physical link speed.
- Release `transfer-bench` used one sequential POSIX stream, 1 MiB buffers, `F_NOCACHE`, offset zero, length 2,147,483,648 bytes. Native SMB's own request scheduling/readahead remained in place.
- Run order: sink/stage, stage/sink, sink/stage, stage/sink, sink/stage. Each CLI process reopened the source. Local staging used exclusive temporary APFS files, wrote every requested byte, and removed the file after completion. No APFS clone or server-side copy was used by the harness.
- Rates are decimal MB/s from transfer time, including staging setup/read/write/close and final source metadata validation. Source open is reported separately in raw JSON. Stage runs did not request `fsync`; these are buffered filesystem writes, not a physical-disk durability benchmark.
- No caches were flushed. The same range was reread and may have warmed the NAS cache. Server cache state remains **unknown**; these are not certified cold-cache measurements. Before/after SMB session counters establish that approximately the requested bytes were received over SMB on each run despite possible NAS caching.

## Samples

| Pair | Native read to sink (MB/s) | Native read to local stage (MB/s) |
| --- | ---: | ---: |
| 1 | 189.3 | 243.1 |
| 2 | 248.8 | 243.6 |
| 3 | 246.4 | 245.5 |
| 4 | 247.2 | 243.2 |
| 5 | 250.3 | 244.3 |
| Median | **247.2** | **243.6** |

The first 2 GiB sink run was slower. Later sink runs were 246.4–250.3 MB/s; all staging runs were 243.1–245.5 MB/s. Do not label the first run as a controlled NAS-cold measurement just because its rate resembles the user's 190 MB/s estimate.

First-read latency within these ten runs was 4.1–4.7 ms. Peak benchmark-process RSS was approximately 7.0 MiB, which excludes kernel buffers, the system page cache, and all other processes. Median benchmark-process CPU time per run was 0.151 s for sink and 0.308 s for staging.

Each run's SMB session RX delta was 2,147,648,926–2,147,652,390 bytes for a 2,147,483,648-byte payload. These counters include protocol overhead and any other traffic on that SMB session; they are not a packet trace or system-wide attribution.

## Initial-access pause

Before the paired series, a 256 MiB native preflight waited **9.569 seconds** for the first `pread` to return. Its total transfer time was 10.944 seconds, giving only 24.5 MB/s overall, while the remaining chunks averaged 194.7 MB/s. The subsequent first-read times were milliseconds.

Storage wake-up, uncached storage access, or another first-access delay are possible explanations. The test did not collect server telemetry and cannot choose between them. Keep first-byte/startup latency separate from sustained throughput when investigating video freezes or generic speed-test results.

## Correctness and cleanup

After the speed series, copied a 64 MiB range starting at byte 12,345 to an exclusive local stage, called `fsync`, and compared SHA-256 of the source/staged range outside the transfer timing. Hashes matched:

```text
6c48ded776f96aac4d5bc26ea9a74f0d59bba706f966aa01c023f0668879ed22
```

This verifies the sampled range, not every byte of the entire movie or a full series checksum. Metadata snapshots matched across the series. Both dedicated staging directories were empty after completion. All source handles were opened read-only; the NAS may independently update access metadata as part of normal reads.

## Evidence and reproduction

- [Summary JSON](../../results/native-20261010-213213/summary.json)
- [Ten instrumented samples](../../results/native-20261010-213213/series/samples.jsonl)
- [SMB settings](../../results/native-20261010-213213/series/smb-settings.txt)
- [Run manifest](../../results/native-20261010-213213/series/manifest.json)
- [Range verification](../../results/native-20261010-213213/verification.jsonl)

Raw results are intentionally under ignored `results/` and contain local paths and server information. Keep them for local review; sanitize before publishing. The measured binary's SHA-256 is in the manifest. The [series runner](../../Tools/run-native-series.py) records the same evidence for another file or physical-Mac run.

## Next experiment and signing

Run the same native source through the File Provider prototype and compare its first-read, range, and full-download behavior against this baseline. Test a small local fixture first to establish extension loading, shared bookmark access, and handoff correctness, then the NAS fixture. An identical reader and verified provider cache state are essential.

The VM currently has no valid code-signing identity. **Start with a free Apple Account / Xcode Personal Team**, not a paid enrollment: Apple's [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos) lists App Groups for free accounts. The prototype does not request the separate FileProvider Testing Mode entitlement. Actual extension loading and all required entitlement provisioning must still be verified. The CLI benchmark above required no developer account.

See [prototype setup](../prototype.md) for steps. Standard distribution/notarization is later work and uses the paid Apple Developer Program. Repeat the performance comparison on the physical Mac before claiming parity with its original 280 MB/s result.
