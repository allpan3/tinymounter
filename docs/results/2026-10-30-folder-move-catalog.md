# Folder-move catalog preparation

Date: 2026-10-30. M22 catalog support passes the required VM checks.
Folder rename and move remain unavailable in the app.

The catalog can snapshot a known subtree and commit a caller-proved move atomically. It keeps
item IDs, enumeration keys and file content versions, including the distinction between f1 and
e1. It updates native lookup IDs, records the root's departure from its old parent and computes
inherited keeps from the current destination. No catalog schema or Settings format changes.

The all-preserved commit requires identity evidence for every known descendant and complete
unchanged-content evidence for each file. Missing or duplicate observations, changed rows, cycles,
collisions and invalid destinations refuse the whole commit. Exact replay writes nothing. The transaction
caller must exclude concurrent catalog reconciliation until local completion is durable.

Review found that identity evidence does not prove directory membership. The commit therefore
clears every moved directory's listing-complete flag. A fresh listing must discover any child
that arrived during the move before the folder can be Available offline. Known downloaded files
keep their versions. A second review found that keep and pause changes could strand recovery;
the commit now preserves current explicit keeps instead of requiring the admission-time policy.
Namespace, content, native fingerprint and listing evidence must still match.

Focused tests cover populated and empty folders, case-only rename, departure pagination,
synthetic pathname-derived native IDs, unchanged versions after relisting, keep and pause changes,
new child discovery, stale descendants, replay and refusal without writes. Tools/run-checks.sh
passes in macOS VM 1 with no failures or Swift warnings, including project generation, release
CLI validation, the unsigned app build and six encoder cases. Evidence:
.local/phase4/m21-20261029/m22-catalog-checks.log. Test data is synthetic, cache state is
uncontrolled, and no performance claim follows.

## Changed descendants during a folder move

A directory move must release handles below the directory, so another client can change its
children before protection is reacquired. A separate atomic settlement API now accepts explicit
outcomes for the known subtree. Proved unchanged files keep their versions. A changed file must
retain its server identity and have different complete contents; a fresh receipt gives it a new
content version even when size and timestamps are unchanged.

A missing or replaced child becomes a tombstone only with a complete listing of its proved
parent. This ends its old catalog binding; it does not claim that the server object was deleted.
A replaced directory requires explicit removal of all its known descendants. New occupants
enter through ordinary reconciliation with new item IDs after settlement. Directory listings
remain incomplete until that discovery finishes. Exact settlement replay changes nothing.

The caller must durably store changed receipts before committing the catalog and block ordinary
reconciliation until local completion is durable. Runtime integration also needs targeted
stale-edit checks for invalidated versions, while preserving legitimate M23 save replay.
Signed checks must establish that File Provider invalidates old local bytes before accepting
the changed version as an editing base. This API enables no runtime folder operation.

Ten added tests cover changed contents with identical timestamps, receipt reuse, incomplete or
contradictory listings, missing/replaced subtrees, pagination, replay and stale catalog rows.
Source review found no blocking defect. Tools/run-checks.sh passes on the integrated candidate
in macOS VM 1: 414 tests, one optional skip, no failures or Swift warnings, project generation,
release CLI validation, unsigned app build and six encoder cases. Evidence:
.local/phase4/m21-20261029/m22-settlement-checks.log. This is catalog evidence only.

The SMB transaction, watch/handle draining, pending-path checks, receipt replay, overlapping
views, provider callbacks and signed Finder checks remain. These catalog APIs alone do not
authorize moving a folder or establish that its remote subtree was preserved.

## Folder transaction core

Folder intents now share the durable rename inventory. Older file-only readers refuse folder
records, including completed history. The transaction records admission evidence before
releasing descendant handles, verifies the moved root by identity, and stores a settlement
before local catalog work. Every retry reloads the durable record. Overlapping views must agree
on each physical descendant's outcome, contents and native lookup evidence.

Completion is tracked per location after its catalog, keeps and replay data are durable.
Completed folder history remains until all participating locations are removed; removing a
non-owner location preserves the owner's completed replay. There is no catalog or Settings
format change. Review strengthened directory-sync retry and agreement across complete listings
and filename aliases. A pre-existing test fixture now admits all participating views at once,
because changing an already saved intent's participants correctly fails.

All required VM checks pass: 472 tests, one optional skip, no failures or Swift warnings,
project generation, release CLI validation, unsigned app build, six encoder cases and 57
SMB-status callback cases. The 31 folder transaction tests include a failure after publishing
the checkpoint file but before syncing its directory; retry cannot proceed until that sync
succeeds. Evidence: .local/phase4/m21-20261029/m22-folder-core-checks-02.log. The first run's
fixture failure remains in m22-folder-core-checks.log. These are simulated-remote checks.

At this checkpoint the core had no runtime adapter or provider wiring. Children changing after
settlement and partial catalog completion caused replay to refuse. The next change addresses
that recovery case before folder moves can be enabled.

## Recovery after partial catalog completion

The transaction now retains its original admission, directory identity and first settlement,
plus one expected and one target state per participating catalog. A fresh protected observation
can replace that bounded recovery plan. Each catalog either applies its expected state to the
target atomically or proves it already matches the target. An untouched catalog can go directly
to the fresh target. Earlier completion markers cannot skip this catch-up.

Changed contents or modification times require fresh edit receipts. Reverting to earlier bytes
also receives a new version. A missing or replaced descendant's old catalog binding stays
retired, even if the same object later reappears. A bounded immutable witness records the first
complete-listing proof, or the retirement of its parent; it does not claim server deletion.
The original moved root can never retire, and replacing it leaves recovery unresolved.

Older readers reject an active `recovering` state. Completed replay remains a no-op; callers
must never apply the original settlement again. Runtime integration must store new receipts
durably before exposing their versions and retain protection through local completion.
Source review found no blocking defect. Tests cover repeated recovery, partial commits,
mtime-only changes, permanent retirement, root replacement, collisions and interruption.
VM compilation and checks are pending. There is no catalog or Settings format change.

## Saved keep paths

Settings now has a caller-invoked folder-path rewrite for pending and saved Keep Downloaded
requests on the affected share. It moves the selected folder's request and typed descendants,
preserves descendant spelling, and leaves other shares and neighboring names unchanged.
Case and Unicode aliases use the existing NameKey comparison. The rewrite is idempotent and
refuses overlapping or overlong destinations before changing Settings. There is no format
change or runtime caller yet. Three focused tests cover aliases, typed descendants, replay,
Settings reload and refusal without partial changes. All required VM checks pass with 475
tests, one optional skip, no failures or Swift warnings, six encoder cases and 57 SMB-status
cases. Evidence: `.local/phase4/m21-20261029/m22-keeps-checks.log`.
