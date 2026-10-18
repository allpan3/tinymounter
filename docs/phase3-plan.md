# Phase 3: offline and NAS changes you can trust

Date: 2026-10-18. Decision status: M11 done in the VM on 2026-10-18
([M11 results](results/2026-10-18-reconnect-restart.md)). The user approved its behaviour on
2026-10-18: the app connects the share again by itself, and it starts again after a crash but not
after the user quits it. The design below is the agent's. The rest of phase 3 is not planned yet.

This is phase 3 of [architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria).
It starts with M11, because in M9 macOS dropped the Finder connection after a 70 s outage, and an
app crash stopped every location until the user opened the app again
([M9 results](results/2026-10-18-exit-validation.md)). Evidence tags are those of the
[phase 2 plan](phase2-plan.md).

## 1. Reconnection

When a share that has locations is not mounted, the app asks macOS to mount it with
`NetFSMountURLAsync`, at the grant's address, with no UI. macOS uses the password that the user
saved in the Keychain; the app never reads, asks for or stores it. The mount is the same as
Finder's, so the saved grant matches it and a session starts [V: spike, 2026-10-18].

- **When.** At launch, at once when macOS unmounts the share (`didUnmount`), and at each
  mount-table poll (10 s) while the share is not mounted. Wake and a network change make the next
  try immediate.
- **Not after an eject.** An eject, from Finder or `diskutil unmount`, posts `willUnmount` first.
  macOS's own unmount after an outage posted only `didUnmount` [V: M9, M11]. After
  `willUnmount`, the app doesn't mount the share until someone mounts it again or the app
  launches again.
- **Retries.** A network failure (such as ETIMEDOUT or EHOSTUNREACH) waits 10 s, then twice as
  long each time, up to 5 min. Any other failure, such as a missing Keychain password, stops the
  tries until the share is mounted again, the Mac wakes or the network changes, so that a wrong
  password is not sent again and again. One try runs at a time.
- **Shares without locations** are not mounted.

The user can still connect in Finder at any time; the app's messages say so already.

## 2. Restart after a crash

The extension starts the app again after a crash, and only then. Quit and Force Quit leave the app
stopped.

- **Run state.** The app keeps an 8-byte state in `RunState` in the App Group, and its launch
  time on the next line. At launch it writes `running`. `applicationWillTerminate`, which runs for
  Quit, logout and shutdown, writes `stopped`. A handler for SIGSEGV, SIGBUS, SIGILL, SIGTRAP,
  SIGABRT and SIGFPE writes `crashed` with `pwrite` to a descriptor opened at launch, resets the
  signal to its default action and raises it again, so the crash report stays the same. It resets
  the action itself, because macOS ignores `SA_RESETHAND` for SIGILL and SIGTRAP: the handler then
  ran again and again, and a Swift trap hung a thread instead of ending the app [V: M11].
- **Force Quit** ends the app with a signal that it can't handle, so the state stays `running`
  and nothing restarts it. A kill by the system for memory is the same.
- **Who restarts it.** When an extension loses the app's reader, and when an extension starts, it
  reads the state. If it is `crashed`, it waits until Launch Services no longer lists the crashed
  app, up to 5 s, then opens the containing app without activating it. Asked sooner, Launch
  Services didn't start the app and showed "The application is not open anymore" in 2 of 9
  restarts [V: M11]. With the wait, the app ran again 58–67 ms after the crash. A new extension
  waits up to 5 s for the reader, so the request that started it can still succeed.
- **No loop.** If the app crashed less than 60 s after its launch, the extension doesn't restart
  it, and reads fail until the user opens it. Only a new extension process restarts it then, once
  60 s have passed since that launch [V: M11].
- **The crash alert.** macOS still shows "quit unexpectedly". Its Reopen button brings the
  restarted app forward with its Settings window, and starts no second instance [V: M11].
- At launch the app logs the previous state, such as `previous_run=crashed`.

## 3. Checks (M11)

In the signed app in the VM:

1. Remove the share with a forced unmount, as macOS does after an outage: a session starts
   again without the user. Measure the time.
2. A 70 s outage: after macOS unmounts the share, the app mounts it when the NAS answers again.
3. Eject with `diskutil unmount`: the share stays unmounted for 2 min. Mount it in Finder: the
   session starts, and a later forced unmount is followed by a mount.
4. Launch with the share not mounted: the app mounts it.
5. `kill -SEGV`, `kill -TRAP` and `kill -ABRT` of the app during a read: the app runs again within
   seconds, and a new read matches the share. Twice within 60 s: the second crash doesn't restart
   it.
6. `kill -9` (as Force Quit does) and Quit: the app stays stopped, also when Finder opens a file
   in a location.
7. No mount and no stage file leaks.

Not testable in the VM: sleep and wake, a network change, and a Keychain without the password.
All 7 checks passed on 2026-10-18, also with SIGILL; the run found and fixed the two restart
defects in §2.

## 4. Milestones

| # | Milestone | Question it answers | Needs |
| --- | --- | --- | --- |
| M11 | The app comes back by itself | Does the share come back after macOS drops it, and the app after a crash, with no change after an eject or a Quit? | M9 |

The rest of phase 3, in [architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria)
order, is planned after M11: verified offline status for kept files, kept folders, NAS change
discovery while the app runs, and cache pressure.
