# SMB rename request encoding

Date: 2026-10-29. A correctness fix within the existing SMB transport scope.

A connection-free VM regression reproduced corruption of the file handle in the vendored SMB
rename encoder. The fix passes all six encoding cases and the full required checks. It changes
no provider capability or transport API. Signed SMB runtime behavior with the corrected library
remains unverified, and no physical-Mac installation occurred.

## Finding and fix

The libsmb2 6.3 SET_INFO encoder converted forward slashes to backslashes in the fixed request
header instead of the destination name. With a long enough name, a 16-bit FileId word equal to
0x002f became 0x005c. This changed the server handle sent with the rename. Bounds checks in the
buffer helpers prevented out-of-bounds access, but did not protect valid header offsets.

The app's existing callers already converted destination separators, which hid the missing
name conversion. That did not protect the FileId. The encoder now changes only the UTF-16 name
before copying it into the request body. Existing preconverted names encode as before. The
password-based test probe, which passed forward slashes, now receives the intended conversion.
Replacement remains disabled. Native reads and file uploads remain unchanged.

The vendor change has a dated source notice and an entry in its bundled local-change notes.
The existing distribution licence and relinking gates still apply.

## Verification

Setup: macOS VM 1, the development clone and its unsigned Release libTinyMounterSMB.dylib.
The test constructs packets in memory without connecting, queuing or sending them. It needs
no server, fixture or credentials. Cache state is irrelevant to these byte comparisons; no
performance measurement was made.

Tools/check-set-info-encoding.c compiled without warnings under -Wall, -Wextra and -Werror.
Against the previously built library it exited 1 with eight failed assertions, including changed
FileIds for long and preconverted names and unconverted forward slashes. After rebuilding with
the fix, all six cases passed. They cover short, long, preconverted and Unicode names, unchanged
header fields, disabled replacement, packet padding and an end-of-file request as a control.

Tools/run-checks.sh now runs the encoder regression against the library it builds. The complete
run passed 294 Swift tests with one optional native-fixture skip and no failures, project
generation, release CLI/benchmark validation, the unsigned app build and all six encoding cases.
No Swift warnings appeared. Existing unrelated vendor C and SDK metadata warnings remain.

VM evidence is in .local/phase4/m21-20261029/encoding-before-compile.log, encoding-before.log
and encoding-run-checks.log. The separate organization probe also passed syntax, synthetic
directory-entry parsing, malformed-input, name-normalization and path-guard checks in this VM;
it has not performed its SMB operations. Its evidence is organization-static.json.

No UI changed, so no before/after recording applies to this encoder fix. File-move admission,
signed Finder workflows and the remaining roadmap safety gates are still open. The disposable
server session remains pending fixture confirmation and cleanup.
