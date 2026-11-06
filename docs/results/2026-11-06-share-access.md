# Share access and automatic connection

Date: 2026-11-06. Decision status: accepted. Initial share selection now retains read and write
permission. Add connects a disconnected saved share before creating the location. These changes
are for the next version; the installed 0.1.0 app and original NAS were not changed.

Read sessions still use a read-only bookmark. Each location's Read only control gates mutations.
An optional share-level write bookmark preserves existing settings without a reset. Earlier
settings reuse a location's permission only for the same grant; otherwise they ask once and
retain it for that share. Account, mount identity and containment checks remain in place.

## Verification

Signed Release app in VMPal `macOS VM 1`, macOS 27.0.1 (26A434), isolated application identity,
and a new subtree on the disposable Samba VM. Cache state was uncontrolled; no performance
claim is made. Required VM checks passed: 520 tests, one optional fixture skip, no failures or
Swift compiler warnings, and all CLI, app-build and SMB checks.

- An existing 0.1.0 location read verified contents and uploaded matching contents after update.
- Duplicate reused its permission without a picker. Read only refused a write with `EACCES`;
  the file was absent on the server. Re-enabling writes required no picker and uploaded correctly.
- Cancelling an older grant's write prompt preserved the draft. Selecting a subfolder as the
  share root was rejected. Select Again captured both permissions without existing locations.
- With the share disconnected, Add connected and created a writable location without another
  permission picker. Its uploaded contents matched on the server.
- After app relaunch, another location reused the share permission without a picker.
- With Samba stopped, Add reported failure and retained the draft without adding a location.
  Samba was restored afterward.

The released comparison build initially stalled in NetAuthSysAgent. Restarting that VM-only
service allowed setup to continue. This pre-existing authentication-service limitation is not
fixed by the permission change. Wrong-account reuse has unit coverage; a separate live account
was not provisioned for this run.

## Finder visibility

Explicit Connect and automatic Add created a `nobrowse` mount. Finder's Computer view did not
list the SMB volume, while its sidebar showed the test File Provider locations. This does not
hide the NAS from Network or make `/Volumes` inaccessible. An existing visible mount can also be
reused without changing its flags. A read-only host check found `nobrowse` on the user's mount;
the user's reported extra Finder entry was not reproduced or conclusively identified.

Raw logs, upload/read evidence and illustrative Add recordings are private under
`results/share-access-20261106/`. The recordings use different initial location states and are
not the matched recordings required for a UI PR. Test locations and the new remote subtree were
removed after validation. Temporary host signing bundles were removed immediately after packaging.

## Setup wording follow-up

The location form now shows only the implemented File Provider path. The unavailable Server
volume radio option and its Connection Mode section were removed. The Servers pane explains
that Add connects automatically and that Disconnect takes locations offline while retaining
downloaded files. It still warns that an existing Finder connection is also disconnected.

Required VM checks passed again (520 tests, one optional skip, no Swift warnings). The signed
app displayed the shorter form and updated server instructions. Matched recordings use the same
saved share, draft, window size and steps: view the location, select Servers, return to the draft.
[Before](../media/setup-flow/before.gif) · [After](../media/setup-flow/after.gif).
Raw evidence is in `results/share-access-ui-20261106/`. No location was added and no server
content changed in this UI follow-up. The temporary test app was removed after inspection.
