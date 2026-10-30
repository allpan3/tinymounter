# Folder-move catalog preparation

Date: 2026-10-30. M22 catalog support passes the required VM checks.
Folder rename and move remain unavailable in the app.

The catalog can snapshot a known subtree and commit a caller-proved move atomically. It keeps
item IDs, enumeration keys and file content versions, including the distinction between f1 and
e1. It updates native lookup IDs, records the root's departure from its old parent and computes
inherited keeps from the current destination. No catalog schema or Settings format changes.

Every known descendant needs identity evidence; each file also needs evidence that its complete
contents stayed unchanged. Missing or duplicate observations, changed rows, cycles, collisions
and invalid destinations refuse the whole commit. Exact replay writes nothing. The transaction
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

The SMB transaction, watch/handle draining, pending-path checks, receipt replay, overlapping
views, provider callbacks and signed Finder checks remain. These catalog APIs alone do not
authorize moving a folder or establish that its remote subtree was preserved.
