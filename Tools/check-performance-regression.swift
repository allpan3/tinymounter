import AppKit
import CryptoKit
import Darwin
import Foundation

// Times one coordinated full download for Tools/check-performance-regression.py; runbook there.
// Output is one JSON object without paths; error text can carry paths, so only domain/code leave.
let arguments = CommandLine.arguments
let choosing = arguments.count > 1 && ["--choose-file", "--choose-range"].contains(arguments[1])
let partial = arguments.count == 4 && arguments[1] == "--choose-range"
guard arguments.count == 2 || partial,
      arguments.count < 2 || arguments[1] != "--choose-range" || partial else {
    FileHandle.standardError.write(Data("usage: check-performance-regression FILE | --choose-file | --choose-range OFFSET LENGTH\n".utf8))
    exit(2)
}
let url: URL
if choosing {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate()
    let panel = NSOpenPanel()
    panel.title = "TinyMounter Read Check"
    panel.message = "Choose the disposable benchmark file. Results contain no filenames or paths."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let selected = panel.url else { exit(2) }
    url = selected
} else {
    url = URL(fileURLWithPath: arguments[1])
}
let scoped = choosing && url.startAccessingSecurityScopedResource()
defer { if scoped { url.stopAccessingSecurityScopedResource() } }
func fileState() -> [String: Any] {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return ["errno": errno] }
    return ["size": value.st_size, "allocatedBytes": value.st_blocks * 512,
            "dataless": value.st_flags & UInt32(SF_DATALESS) != 0]
}
let before = choosing ? fileState() : [:]
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
var firstReadSeconds: Double?
var byteCount: Int64 = 0
let offset = partial ? Int64(arguments[2]) : 0
let length = partial ? Int64(arguments[3]) : (before["size"] as? Int64)
if partial, offset == nil || length == nil || offset! < 0 || length! <= 0 { exit(2) }
let start = DispatchTime.now().uptimeNanoseconds
// Options [] request the complete file; the accessor does not read the payload.
if partial {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd >= 0 {
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
           offset! <= info.st_size, length! <= info.st_size - offset!, fcntl(fd, F_NOCACHE, 1) == 0 {
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while byteCount < length! {
                let count = pread(fd, &buffer, min(buffer.count, Int(length! - byteCount)), offset! + byteCount)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                if firstReadSeconds == nil {
                    firstReadSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                }
                byteCount += Int64(count)
            }
            if byteCount == length! { accessorSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
        }
    }
    if accessorSeconds == nil { coordinationError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
} else {
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in
        accessorSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}
let returnSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
var digest: String?
if choosing, accessorSeconds != nil, let length, let offset,
   setiopolicy_np(policyType, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd >= 0 {
        defer { close(fd) }
        var hash = SHA256(), read: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while read < length {
            let count = pread(fd, &buffer, min(buffer.count, Int(length - read)), offset + read)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            hash.update(data: buffer.prefix(count))
            read += Int64(count)
        }
        if read == length { digest = hash.finalize().map { String(format: "%02x", $0) }.joined() }
    }
}
let restored = setiopolicy_np(policyType, IOPOL_SCOPE_PROCESS, inheritedPolicy) == 0
var result: [String: Any] = [
    "inheritedHydrationPolicy": Int(inheritedPolicy), "effectiveHydrationPolicy": Int(effectivePolicy),
    "inheritedPolicyRestored": restored, "returnSeconds": returnSeconds,
]
if let accessorSeconds { result["accessorSeconds"] = accessorSeconds }
if choosing {
    result["before"] = before
    result["after"] = fileState()
    result["offset"] = offset
    result["length"] = length
    result["sha256"] = digest
    result["mode"] = partial ? "partial" : "full"
    if let firstReadSeconds { result["firstReadSeconds"] = firstReadSeconds }
}
if let coordinationError {
    result["errorDomain"] = coordinationError.domain
    result["errorCode"] = coordinationError.code
}
let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data + Data([10]))
exit(accessorSeconds != nil && coordinationError == nil && restored && (!choosing || digest != nil) ? 0 : 1)
