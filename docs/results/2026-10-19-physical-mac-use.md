# Physical-Mac browsing and playback, 2026-10-19

## Outcome

The user reports fast Finder navigation, quick video startup and responsive seeking on the
installed diagnostic build. The captured reads include partial-file streaming and read-ahead;
one earlier playback item also received a full-file callback later. A download button after
playback is consistent with a partly downloaded file, not evidence that no data was fetched.

The user reports that the supplied checks passed except a macOS restart and will continue daily
use. This includes sleep and wake and a network change as user-reported checks. It is not a
scripted verification of every phase 2 acceptance criterion. The original first-folder stall
did not recur, but its cause is still unknown. No performance change was made for this run.

## Setup and method

- Physical Mac, Apple M5 Max, macOS 27.0.1, build 26A434, on 2026-10-19, about 00:01 to
  00:40 US/Pacific. The signed diagnostic Release app ran from `/Applications`.
- The diagnostic update added operation timings only. The preceding run restarted the app and
  normally unmounted and reconnected the test share. SMB, NAS and persistent caches were not
  controlled. Existing locations refresh and warm the share at launch.
- Read the bounded subsystem log capture and recent unified logs. The user performed the
  browsing, playback and connection checks. No new read, eviction, mount or settings change
  was made while collecting this evidence. The user removed the earlier location and added a
  new one during their run; the agent did not restore or reset that later state.

## Data

| Observation | Evidence and limit |
| --- | --- |
| First child folder after Add | Five entries; 12.8 ms app total and 13.4 ms extension first-page wait at 00:01:16. |
| Next two new folders | 18 and 77 entries; 20.2 and 119.3 ms extension waits. These are different folders, not controlled cache repetitions. |
| Earlier playback item | 60 captured partial callbacks and a later full callback for about 2 GiB at 00:02:11. The full callback took 11.1 s. The trace does not identify whether Download Now, an app or a system fallback requested it. |
| Later partial reading | Seven captured partial callbacks for another item included two sequential reads and two speculative read-ahead completions. No full callback for that item appears in the captured records. |
| Connection recovery | Probes failed during an unavailable interval; a later mount succeeded at 00:39:35, the session returned to Connected and five folders relisted with no changes. The exact network actions are the user's report. |
| User's assessment | Browsing, startup and seeking were fast. The supplied checks passed except macOS restart. No timed first-frame or seek measurement was made. |

The download button describes whether macOS has a complete local file. Partial reads download
and cache requested ranges, and bounded read-ahead can fetch the next range. They do not imply
a request to finish downloading the whole video after the player closes. Cached ranges can
serve later reads while retained; missing ranges still require the NAS. Download Now requests
the complete file; Keep Downloaded requests a complete copy that macOS should retain.

## Correctness and limits

No checksums, retained-range map or item-specific Finder badge inspection were collected for
these playback attempts. The callback logs show bytes handed to macOS, not proof of which
ranges remained on disk when the user returned to Finder. The player and exact opening route
are uncertain, so this run cannot establish a change to Finder double-click behavior. Earlier
full-download-before-open observations apply to their measured VM configurations.

The source is read-only. The agent requested no new download and removed none of the user's
later downloads. macOS restart, persistence across that restart, and the full physical-Mac
performance acceptance series remain unverified.

## Evidence

Local evidence under `results/folder-navigation-20261018/` includes
`host-user-run-live-snapshot.json`, `host-user-playback-log.json` and
`host-user-playback-summary.json`. The summary groups completed callbacks by opaque item ID.
The live capture ended after its bounded observation window; recent logs cover later events.

This follow-up changes documentation only. `Tools/run-checks.sh` passed in the VM with 156
tests, zero failures and the required builds, with no Swift compiler warnings. Its log is
`.local/phase2/physical-use-checks.log`.

## Next step

Continue the user's daily-use observation and record the macOS restart when they perform it.
If the first-folder pause returns, capture the diagnostic operation timings before resetting
anything. Do not attribute the improvement to a code fix or generalize these reads into a
fully cold performance result.
