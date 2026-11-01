import Darwin
import Foundation

// Times one coordinated full download for Tools/check-performance-regression.py; runbook there.
// Output is one JSON object without paths; error text can carry paths, so only domain/code leave.
let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: check-performance-regression FILE\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let policyType = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
let inheritedPolicy = getiopolicy_np(policyType, IOPOL_SCOPE_PROCESS)
guard inheritedPolicy >= 0,
      setiopolicy_np(policyType, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0 else {
    FileHandle.standardError.write(Data("cannot enable process hydration: errno \(errno)\n".utf8))
    exit(1)
}
let effectivePolicy = getiopolicy_np(policyType, IOPOL_SCOPE_PROCESS)
var coordinationError: NSError?
var accessorSeconds: Double?
let start = DispatchTime.now().uptimeNanoseconds
// Options [] request the complete file; the accessor does not read the payload.
NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in
    accessorSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}
let returnSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
let restored = setiopolicy_np(policyType, IOPOL_SCOPE_PROCESS, inheritedPolicy) == 0
var result: [String: Any] = [
    "inheritedHydrationPolicy": Int(inheritedPolicy), "effectiveHydrationPolicy": Int(effectivePolicy),
    "inheritedPolicyRestored": restored, "returnSeconds": returnSeconds,
]
if let accessorSeconds { result["accessorSeconds"] = accessorSeconds }
if let coordinationError {
    result["errorDomain"] = coordinationError.domain
    result["errorCode"] = coordinationError.code
}
let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data + Data([10]))
exit(accessorSeconds != nil && coordinationError == nil && restored ? 0 : 1)
