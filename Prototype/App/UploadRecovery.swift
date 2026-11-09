import Foundation

/// Which upload failures TinyMounter retries without the user.
enum UploadRecovery {
    /// The panel lists a failure that retries by itself as a waiting transfer, not as failed.
    static func retriesByItself(_ error: Error) -> Bool { false }
}
