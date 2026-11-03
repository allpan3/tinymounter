# Folder organization on Linux Samba

Date: 2026-11-03. Status: integration in progress; normal-build folder capabilities remain off.

The first enabled Finder rename moved the server folder and preserved its catalog IDs,
content versions, downloaded bytes and keep selections, but did not complete. Samba changed
the parent directory's reported creation time when the child moved. The completion check
then treated that parent as a different object and retained the verified pending intent.

## Setup and evidence

The signed single-client candidate runs in macOS VM 1, macOS 27.0.1, against Samba 4.19.5
on the TinyMounter Samba Test VM. The share requires encryption and uses ext4 with
`acl_xattr` and `streams_xattr`. Caches were uncontrolled; this is a correctness check.
The original NAS and physical-Mac installation were untouched.

`Tools/prepare-folder-candidate.py` prepares a separate VM checkout from committed source.
It reuses the existing Finder callback and materialization probes, enables organization only
when requested, and exports fixture evidence through an explicit local folder-picker grant.
It preserves the normal app lifecycle and sandbox. App/provider sources in that checkout are
generated test instrumentation, not production edits.

The fixture has 11 small files. Four complete local copies were hashed with materialization
disabled, including an independently kept file and a file kept through its parent folder.
The unopened child stayed dataless. The disabled baseline sent real rename callbacks that
returned Cocoa error 513. Finder's Undo restored its original name. On candidate replacement,
macOS replayed that original-name callback successfully before the next rename gesture.
Matched recordings capture the refused and enabled rename attempts.

The enabled attempt renamed the directory on the server but returned File Provider error
-2005. The exported intent is `verified`, with no finished domain. Its parent file ID is
unchanged; the reported creation time changed from 1793708655571160 to 1793709053817444
microseconds since the Unix epoch. Independent Linux `stat` shows an unchanged actual birth
time and inode. The SMB value follows the new directory modification time.
[Samba's documentation](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html#FAKEDIRECTORYCREATETIMES)
describes this directory creation-time behavior. No server setting was changed to suppress it.

Raw evidence stays in the VM's `results/folder-single-20261103/`: exported `baseline/`
snapshots/events, before recordings, build/check logs and `parent-identity-after.json`.
Linux inventories remain under `/tmp/tinymounter-folder-<run>/`. An earlier interrupted
fixture setup remains preserved separately; it never registered a location. The first setup
also exposed two initial SMB connection failures followed by successful ordinary retries.

## Parent evidence checkpoint

The repair records updated parent creation times at the durable `moved` checkpoint, before
closing the original protected parent handles. Paths, names and file IDs must remain unchanged.
After this checkpoint, parent evidence is immutable again. A fresh connection cannot accept
a changed creation time just because the pathname or file ID matches.

The focused package check passes 93 folder catalog/transaction tests on the host. Three added
tests cover checkpoint/retry, refusal after protection is lost, and refusal of replacement
directories or later evidence changes. Signed verification of the repair is next.

A lost connection between the remote rename and this checkpoint can still leave an operation
unresolved on a server with changing creation times. The earlier pending move remains intact;
the repair does not manufacture missing historical evidence. This boundary and the remaining
Finder, crash and overlapping-view checks still gate enablement.
