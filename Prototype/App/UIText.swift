import FileProvider
import Foundation

/// All UI text, in ASD-STE100 (docs/ui-design.md §8), so the STE checker reads one file.
enum UIText {
    static let appName = "TinyMounter"

    // Sidebar
    static let locations = "Locations"
    static let settings = "Settings"
    static let general = "General"
    static let storage = "Storage"
    static let servers = "Servers"
    static let about = "About"
    static let search = "Search"
    static let notAdded = "Not added"
    static let newLocation = "New Location"
    static let duplicate = "Duplicate"
    static let showInFinder = "Show in Finder"
    static let removeLocationMenu = "Remove Location…"
    static let settingsMenu = "Settings…"

    static let connectionMode = "Connection Mode"
    static let fileProvider = "File Provider"
    static let serverVolume = "Server Volume"
    static let nativeVolumeHint = "Opens the whole share directly in Finder. Files stay on the server and are unavailable offline. Access follows the server's permissions."
    static let modeSwitchHint = "To switch modes, remove this share's existing locations first."
    static let shareModeConflict = "This share already uses another mode, or already has a server volume. Remove its existing locations before adding a different mode."
    static let nativeMountUnavailable = "macOS reused a hidden connection. Disconnect this share in Servers, then try again."
    static let volumeBusy = "This server volume is in use. Close its open files and windows, then try again. The location has not been removed."
    static let removeServerVolumeHint = "Disconnect this server volume and stop reconnecting it automatically. Files on the server do not change. Close files that are open on the share first."

    // Location pane
    static let access = "Access"
    static let readOnly = "Read only"
    static let confirmWriteSetup = "Confirm Write Access"
    static var writeModeHint: String {
        let base = "Read only prevents changes to files on the server. Turn it off to create items, edit files, and rename or move ordinary files within this location."
        if SourceReaderBridge.deletionEnabled {
            return base + " Deletion permanently removes items from the server. Finder Replace can remove the old file before the new upload finishes. TinyMounter cannot restore deleted or replaced contents."
        }
        if SourceReaderBridge.permanentDeletionEnabled {
            return base + " To delete one file or folder, right-click it in Finder and choose Delete Permanently…. This removes it from the server and cannot be undone. Finder Replace remains unavailable."
        }
        guard SourceReaderBridge.deletionEnabled else {
            return base + " Folder moves, deleting and replacing items remain unavailable."
        }
        return base + " Deletion permanently removes files and folders from the server. TinyMounter cannot restore deleted items."
    }
    static let exportEdit = "Export Local Copy…"
    static let localRecoveryDestination = "Choose a folder on this Mac for the recovery copy."
    static let retryPending = "Retry Pending Changes"
    static let waitingToUpload = "Waiting to upload"
    static let editTargetUnavailable = "This save cannot update the original file. Export a local copy."
    static let stopUploading = "Stop Uploading"
    static func stopUploadingTitle(_ path: String) -> String {
        "Stop the upload of “\((path as NSString).lastPathComponent)”?"
    }
    /// macOS sends a stopped item again when its metadata changes, and a new item in a folder changes it.
    static func stopUploadingMessage(_ kind: CatalogRow.Kind) -> String {
        kind == .folder ? """
            The folder and its contents stay on this Mac and are not uploaded. If you change the folder or put an \
            item in it, TinyMounter tries to upload the folder again.
            """
            : "The file stays on this Mac and is not uploaded. If you change the file, TinyMounter tries to upload it again."
    }
    static let stopRefused = "TinyMounter cannot stop this item, because the server can have it. Use Retry Pending Changes to check the server."
    static let stopEditMessage = """
        Save a copy of the changes that did not upload. TinyMounter then stops the upload and updates \
        this location to match the server. If the file was deleted, it is removed from this location.
        """
    static let stopEditRefused = "TinyMounter did not stop the upload. The local save is retained."
    /// The default name of a stopped save's copy, such as "Report (not uploaded 2026-11-02).txt".
    static func stoppedEditName(_ path: String, date: Date) -> String {
        let name = URL(fileURLWithPath: path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
        return name.deletingPathExtension().lastPathComponent + " (not uploaded \(formatter.string(from: date)))" + suffix
    }
    static func editPending(_ path: String) -> String { "Edited file: \(path)" }
    static func deletionPending(_ path: String) -> String { "Permanent deletion: \(path)" }
    static let deletionEffect = "Deletion permanently removes items from the server and its locations. TinyMounter cannot restore deleted items."
    static let deletionWaiting = "Waiting to continue deletion"
    static let deletionActive = "Deletion in progress"
    static let deletionSettlement = "Waiting to update the locations"
    static let deletionUnconfirmed = "The deletion result is unconfirmed."
    static let deletionDetails = "Item results"
    static let deletionRetry = "Retry"
    static let deletionRetryHint = "Retry uses the recorded items. It does not add items to this request."
    static var deletionNewRequestHint: String {
        SourceReaderBridge.permanentDeletionEnabled
            ? "To delete an item that remains, right-click it in Finder and choose Delete Permanently…."
            : "To delete an item that remains, select it again in Finder."
    }
    static let deletionStatusUnavailable = "Cannot read deletion status. Keep this location until its status is available."
    static let stopDeleting = "Stop Deleting"
    static let stopDeletingMessage = "Items already deleted cannot be restored. A request already sent to the server can still delete its item."
    static func stopDeletingTitle(_ path: String) -> String {
        "Stop deleting “\((path as NSString).lastPathComponent)”?"
    }
    static let dismissDeletionTitle = "Dismiss this deletion notice?"
    static let dismissDeletionMessage = "This hides the notice. It does not restore deleted items or confirm an uncertain result."
    static func deletionSummary(_ record: PendingDeletion) -> String {
        "Items confirmed deleted: \(record.summary[.deleted] ?? 0) of \(record.plan.nodes.count)."
    }
    static func deletionFailed(_ reason: DeletionFailure, at date: Date) -> String {
        "\(deletionFailure(reason)) Last try: \(date.formatted(date: .abbreviated, time: .shortened))."
    }
    static func deletionFailure(_ failure: DeletionFailure) -> String {
        switch failure {
        case .changed: "The item changed on the server."
        case .replaced: "Another item is now at this name."
        case .moved: "The item moved on the server."
        case .parentChanged: "A parent folder changed on the server."
        case .unsupported: "TinyMounter cannot delete this type of item or this folder."
        case .sharingViolation: "Another program has this item open. Close it before a new deletion request."
        case .accessDenied: "The server does not give permission to delete this item."
        case .cannotDelete: "The server refused to delete this item."
        case .directoryNotEmpty: "The folder still contains items."
        case .unconfirmed: "TinyMounter cannot confirm the deletion result."
        case .connection: "There is no connection to the server."
        case .authentication: "The server did not accept the sign-in."
        case .pendingChanges, .busy: "Other changes on this share must finish first."
        case .readOnly: "TinyMounter has no write access for this deletion."
        case .cancelled, .stopped: "Deletion was stopped."
        case .storage: "There is not sufficient space on this Mac."
        case .unknown: "TinyMounter could not finish the deletion. Retry to check the recorded request."
        }
    }
    static func deletionItemStatus(_ item: DeletionItemProgress) -> String {
        switch item.outcome {
        case .deleted?: "Permanently deleted"
        case .unconfirmed?: deletionUnconfirmed
        case .stopped?: "Not attempted. Deletion was stopped."
        case .changed?: deletionFailure(.changed)
        case .replaced?: deletionFailure(.replaced)
        case .moved?: deletionFailure(.moved)
        case .parentChanged?: deletionFailure(.parentChanged)
        case .unsupported?: deletionFailure(.unsupported)
        case .sharingViolation?: deletionFailure(.sharingViolation)
        case .accessDenied?: deletionFailure(.accessDenied)
        case .cannotDelete?: deletionFailure(.cannotDelete)
        case .directoryNotEmpty?: deletionFailure(.directoryNotEmpty)
        case nil: item.mayHaveBeenRequested ? deletionUnconfirmed : "Not yet attempted"
        }
    }
    static func unnamedPending(_ count: Int) -> String { "Other pending changes: \(count)" }
    static func renameDescription(_ rename: RenameIntent) -> String {
        switch rename {
        case .file(let record):
            return record.views.contains(where: { $0.targetParent != $0.parent })
                ? pendingMove(from: record.oldName, to: record.destination)
                : pendingRename(from: record.oldName, to: record.name)
        case .folder(let record):
            let moved = RelativePath(record.source)?.components.dropLast()
                != RelativePath(record.destination)?.components.dropLast()
            return moved ? pendingMove(from: record.oldName, to: record.destination)
                : pendingRename(from: record.oldName, to: record.name)
        }
    }
    static func newFolderPending(_ path: String) -> String { "New folder: \(path)" }
    static func newFilePending(_ path: String) -> String { "New file: \(path)" }
    static func createFailed(_ reason: String, at date: Date) -> String {
        "Did not upload: \(reason) Last try: \(date.formatted(date: .abbreviated, time: .shortened))."
    }
    static func uploadFailure(_ error: Error) -> String {
        if let upload = error as? UploadError {
            switch upload {
            case .pendingWrites: return "Other changes on this share must finish first."
            case .readOnly: return "TinyMounter has no write access to this share."
            case .collision: return "An item with this name is already on the server."
            case .unresolved: return "TinyMounter cannot confirm the result on the server."
            case .invalidRequest: return "TinyMounter cannot create this item in this folder."
            case .editConflict: return "The item changed on the server."
            case .excluded: return "The upload was stopped."
            }
        }
        if let failure = error as? FolderMutationFailure {
            if failure.mayHaveChanged { return uploadFailure(UploadError.unresolved) }
            switch SourceFailure.classify(errno: failure.code, context: .listing) {
            case .serverUnreachable: return "There is no connection to the server."
            case .notAuthenticated: return "The server did not accept the sign-in."
            default: return "The server refused the change: \(String(cString: strerror(failure.code)))."
            }
        }
        // A system error comes from the share; the Mac's own space check throws a Cocoa error.
        let system = error as NSError
        if system.domain == NSPOSIXErrorDomain, [Int(ENOSPC), Int(EDQUOT)].contains(system.code) {
            return "There is not sufficient space on the server."
        }
        if DownloadSpace.isFull(error) { return "There is not sufficient space on this Mac." }
        switch SourceFailure.classify(error, context: .listing) {
        case .serverUnreachable, .notConnected: return "There is no connection to the server."
        case .notAuthenticated: return "The server did not accept the sign-in."
        case .noPermission: return "The server does not give write access."
        default:
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain, let code = Int32(exactly: failure.code) {
                return "The upload failed: \(String(cString: strerror(code)))."
            }
            return "Error \(failure.domain) \(failure.code)."
        }
    }
    static let editPreparing = "Local save not yet confirmed. Keep the document open."
    static let editNeedsRecovery = "Recovery needed. The local save is retained."
    static let editInterrupted = "Upload not finished. The file on the server has not changed. The local save is retained."
    static let editConflict = "Conflict. The local save is retained."
    static let publishedRecovery = "Saved on the server. Recovery files still need attention."
    static let conflictRecovery = "Saved as a conflict copy. Recovery files still need attention."
    static func savedChangeBytes(_ bytes: Int64) -> String {
        "Local saved copies: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    static let savedChangeSpace = "New saves stop when there is not enough space above the 2 GiB reserve. Saved copies are retained."
    static let retiredEdit = "Older save kept for recovery. It will not upload. Newer saves can continue."
    static let pendingStatusUnavailable = "Cannot read pending change status. Local copies are retained."
    static let systemPendingIncomplete = "macOS has not supplied the complete pending list. More items may be waiting."
    static let systemPendingWaiting = "Waiting for macOS to finish this change."
    static func systemPendingReason(_ error: NSError?) -> String {
        guard let error else { return systemPendingWaiting }
        if SourceReaderBridge.isRefusedOrganization(error) {
            return SourceReaderBridge.refusedOrganizationError.localizedDescription
        }
        if error.domain == NSFileProviderErrorDomain, error.code == NSFileProviderError.cannotSynchronize.rawValue {
            return "macOS could not synchronize this change. Select Retry Pending Changes to check again."
        }
        return error.localizedDescription
    }
    static func systemPending(_ path: String) -> String { "Pending in macOS: \(path)" }
    static func pendingOriginalPath(_ path: String) -> String { "Last known server path: \(path)" }
    static let pendingOrganizationUndo = "To undo a refused rename or move, restore this name and folder in Finder. After it clears, you can try the change again."
    static let renameNeedsRecovery = "File change pending or needs recovery. Keep this location until it finishes."
    static func pendingRename(from: String, to: String) -> String { "Rename \(from) to \(to)" }
    static func pendingMove(from: String, to: String) -> String { "Move \(from) to \(to)" }
    static let conflictSaved = "Saved as a conflict copy"
    static let dismissEditNotice = "Dismiss Notice"
    static let writeGrantMessage = "Select this share once to allow changes. TinyMounter will remember this permission for its locations."
    static let pendingUploadHint = "Keep this location and its source until the changes finish. Pending content stays on this Mac. An interrupted change may need recovery."
    static let uploadAccessError = "Select this share again. Read only cannot be enabled while changes are pending."
    static func pendingUploads(_ count: Int) -> String { "Pending changes: \(count)" }
    static let source = "Source"
    static let server = "Server"
    static let share = "Share"
    static let folder = "Folder"
    static let name = "Name"
    static let fullShare = "Full share"
    static let select = "Select…"
    static let addShare = "Add Share…"
    static let addServer = "Add Server…"
    static let addServerTitle = "Type the address of the server."
    static let addServerDescription = "For example, smb://server. Choose a share when you add a location."
    static let addressPlaceholder = "smb://server"
    static let noServer = "No server"
    static let connect = "Connect"
    static let disconnect = "Disconnect"
    static let noShare = "No share"
    static let locationFinderHint = "Finder shows this location under Locations. Files download when you open them."
    static let keepDownloaded = "Keep Downloaded"
    static let requested = "Requested"
    static let availableOffline = "Available offline"
    static let updateInProgress = "Update in progress"
    static let notSufficientSpace = "Not sufficient space"
    static let lowSpaceHint = "Free space on this Mac. Kept downloads resume automatically."
    static let notOnServer = "Not on the server"
    static let keepHint = "To keep a file or folder downloaded, right-click it in Finder. Then click Keep Downloaded."
    static let draftKeepHint = """
        TinyMounter downloads these items after you click Add. If an item is not in the folder, TinyMounter \
        shows “Not on the server”.
        """
    static let removeLocationDescription = "Remove this location from this Mac. The files on the server do not change."
    static let draftBar = "Finder does not show this location until you click Add."
    static let applyBar = """
        If you change the source or the connection mode, TinyMounter removes the downloaded copies of this \
        location. The files on the server do not change.
        """
    static let add = "Add"
    static let cancel = "Cancel"
    static let apply = "Apply"
    static let revert = "Revert"
    static let removeItem = "Remove"

    // Location state
    static let connected = "Connected"
    static let notConnected = "Not connected"
    static let removalNotComplete = "The removal is not complete."
    static let connectInLocation = "Open this location in TinyMounter Settings. Then click Connect."
    static let clickConnect = "Not connected. Click Connect."
    static let selectShareAgain = "Select the share again. Click Select Again… in the location."
    static let folderNotOnShare = "This folder is not on the share."
    static let catalogUnavailable = "TinyMounter cannot read the data for this location. Remove the location. Then add it again."
    static let turnedOff = "File Provider is off."
    static let enableFileProvider = "In Extensions, open TinyMounter. Then turn on File Provider."
    static let openSystemSettings = "Open System Settings…"
    static let problem = "Problem"

    static func cannotConnect(_ host: String) -> String {
        "TinyMounter cannot connect to \(host). Make sure that \(host) is on. Make sure that this Mac is on the same network."
    }

    static func cannotDisconnect(_ share: String) -> String {
        "TinyMounter cannot disconnect “\(share)”. Close the files that are open on it. Then try again."
    }

    static func downloaded(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))% downloaded"
    }

    static func joined(_ parts: String...) -> String { parts.joined(separator: " · ") }

    static func source(host: String, share: String, folder: String) -> String {
        [host, share, folder.isEmpty ? fullShare : folder].joined(separator: " › ")
    }

    // Confirmations
    static func removeTitle(_ name: String) -> String { "Remove “\(name)” from this Mac?" }
    static let removeMessage = """
        The files on the server do not change. TinyMounter removes the downloaded copies of this location \
        from this Mac.
        """
    static func removeStops(_ items: [String]) -> String {
        "These items did not upload. macOS keeps them on this Mac in a folder. TinyMounter shows the folder in "
            + "Finder after the removal.\n" + list(items)
    }
    static func removeBlockedTitle(_ name: String) -> String { "TinyMounter cannot remove “\(name)” now" }
    static func removeBlockedMessage(_ items: [String]) -> String {
        "These changes can be on the server. Review their recovery actions in Settings. Then remove the location "
            + "again.\n" + list(items)
    }
    private static func list(_ items: [String]) -> String {
        let shown = items.prefix(10).map { "• " + $0 }
        let more = items.count > shown.count ? ["\(items.count - shown.count) more"] : []
        return (shown + more).joined(separator: "\n")
    }
    static let saveKeepList = "Save the Keep Downloaded list"
    static let removeLocation = "Remove Location"
    static func applyTitle(_ name: String) -> String { "Change the source of “\(name)”?" }
    static func downloadTitle(_ count: Int) -> String {
        count == 1 ? "Download 1 kept file now?" : "Download \(count) kept files now?"
    }
    static func downloadMessage(_ name: String) -> String {
        """
        TinyMounter found items of the saved Keep Downloaded list in “\(name)”. They are in folders that you \
        did not open in Finder. They download only when you open these folders.
        """
    }
    static let downloadNow = "Download Now"
    static let notNow = "Not Now"

    // Errors
    static let settingsUnreadable = """
        TinyMounter cannot read its settings file. You cannot add or change a location. If an earlier \
        version made the file, click Start Fresh in General.
        """
    static let startFresh = "Start Fresh"
    static let startFreshMenu = "Start Fresh…"
    static let startFreshTitle = "Remove all locations and start fresh?"
    static let startFreshMessage = """
        TinyMounter cannot read the data of an earlier version. Start Fresh removes all locations from \
        this Mac. Then you add them again. The files on the server do not change. Changes that did not \
        upload are kept in a folder that opens in Finder.
        """
    static let domainsUnreadable = "TinyMounter cannot read its locations from macOS. Quit TinyMounter. Then open it again."
    static let providerTranslocated = "Quit TinyMounter. Use Finder to drag the app into Applications, then open it from there. macOS cannot enable its File Provider from this temporary location."
    static let wrongFolderPath = "This folder path is not correct. Type a path in the share."
    static let wrongName = "This name is not correct. Type a different name."
    static let notVolumeRoot = "This folder is not a share. Select the share, not a folder in it."
    static let notSMBShare = "This volume is not an SMB share. To add a share, click Add Share…."
    static let addressRejected = "TinyMounter cannot use the address of this share."
    static let otherShare = "This is a different share. To add it, click Add Share…."
    static let otherAccount = "This share is connected through another account. To use this account, eject the other connection. Then click Add Share… again."
    static let wrongAddress = "This address is not correct. Type an address such as smb://server/share."
    static func passwordNotAccepted(_ host: String) -> String {
        "\(host) did not accept the password. Type the password again."
    }
    static let tooManyItems = "This folder has more than 100,000 items. TinyMounter cannot show it."
    static let cannotShow = "Finder cannot show this location."
    static let shareInUse = "A location uses this share. Remove the location first."
    static func cannotDo(_ code: String) -> String { "TinyMounter cannot do this (\(code))." }

    // Panels
    static let selectShareMessage = "Click Open to give TinyMounter access to this share. Use Read only in a location to prevent changes."
    static let selectFolderMessage = "Select a folder in the share."

    // Servers
    static let selectAgain = "Select Again…"
    static let notResponding = "Cannot connect"
    static let selectShareAgainShort = "Select the share again."
    static func accountAndShare(_ account: String, _ share: String) -> String { "\(account) · \(share)" }
    static let serversDescription = """
        TinyMounter can use these shares. To add a share, add a location and select the share there.
        """
    static let noServers = "No shares. To add a share, add a location."
    static let noShares = "No shares"
    static func usedBy(_ names: [String]) -> String { "Used by " + names.joined(separator: ", ") }
    static let notUsed = "Not used"
    static let forget = "Forget"
    static let forgetUsedHelp = "A location uses this share. Remove the location first."
    static func forgetShareTitle(_ share: String) -> String { "Forget the share \(share)?" }
    static let forgetShareMessage = """
        TinyMounter disconnects the share and forgets its access. The files on the server do not change. \
        To use the share again, add a location and select the share.
        """
    static let useShare = "Use Share"
    static let useOtherAddressTitle = "Use the connection at this other address?"
    static func useOtherAddress(_ address: ShareAddress, server: String) -> String {
        "Use \(address.host) / \(address.share), connected as \(address.account), with \(server)? Forget in Servers ejects this connection from this Mac."
    }
    static let connectAnotherShare = "Connect Another Share…"
    static let chooseShareDescription = """
        These shares are already connected on this Mac. To use one, select it and click Use Share. \
        To connect another share, click Connect Another Share. macOS asks for the password if necessary. \
        Select “Remember this password in my keychain”, so that TinyMounter can connect again.
        """
    static func chooseShareTitle(_ host: String) -> String { "Choose a share for \(host)." }
    static func mountedShare(_ address: ShareAddress) -> String {
        "\(address.host) / \(address.share) · \(address.account)"
    }
    static func serverAddress(_ server: ServerRecord) -> String {
        server.account.map { "\($0)@\(server.host)" } ?? server.host
    }
    static let cannotRemoveServer = "TinyMounter cannot forget this server. Try again."

    // General
    static let openAtLogin = "Open at login"
    static let openAtLoginApproval = "Allow TinyMounter in System Settings › General › Login Items & Extensions."
    static let showInMenuBar = "Show in menu bar"
    static let menuBarDescription = """
        The menu bar item keeps TinyMounter open. TinyMounter must be open to read data that is not downloaded.
        """
    static let notifications = "Notifications"
    static let notificationsDescription = "Show a notification when a share disconnects or a download cannot start."

    // Storage
    static let notAvailable = "Not available"
    static let total = "Total"
    static let storageDescription = """
        This includes the kept files. When disk space is low, macOS removes the downloaded files that you do \
        not keep. Remove Downloads removes them immediately. TinyMounter leaves 2 GiB free for macOS. \
        A download can need extra temporary space.
        """
    static let removeDownloadsMenu = "Remove Downloads…"
    static let removeDownloads = "Remove Downloads"
    static let cannotRemoveDownloads = "TinyMounter cannot remove the downloads of this location."

    static func removeDownloadsTitle(_ name: String) -> String { "Remove the downloads of “\(name)”?" }

    static func removeDownloadsMessage(files: Int, bytes: Int64) -> String {
        let count = files == 1 ? "1 file" : "\(files) files"
        return """
            TinyMounter removes the downloaded copies of \(count) (\(size(bytes))) that you do not keep. Kept files \
            stay on this Mac. The files on the server do not change.
            """
    }

    static func downloadsStayed(_ files: Int) -> String {
        let (count, them) = files == 1 ? ("1 downloaded file", "it") : ("\(files) downloaded files", "them")
        return "TinyMounter cannot remove \(count). If an app uses \(them), close the app. Then try again."
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        // A no-break space keeps "307.1 MB" on one line in an alert.
        return formatter.string(fromByteCount: bytes).replacingOccurrences(of: " ", with: "\u{A0}")
    }

    static func downloadedSize(_ bytes: Int64) -> String { "\(size(bytes)) downloaded" }

    static func availableSize(_ bytes: Int64) -> String { "\(size(bytes)) available" }

    // About
    static let version = "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")"
    static let diagnostics = "Diagnostics"
    static let diagnosticsDescription = "This report helps to find problems. It does not include file names, paths, or passwords."
    static let copy = "Copy"

    // Menu bar
    static let pauseDownloads = "Pause Downloads"
    static let resumeDownloads = "Resume Downloads"
    static let quit = "Quit TinyMounter"
    static let noLocations = "No locations"
    static let pauseFailed = "TinyMounter cannot stop background downloads for one or more locations."
    static let resumeFailed = "TinyMounter cannot start background downloads again for one or more locations."

    // Quit
    static let quitTitle = "Downloads are in progress."
    static let quitMessage = "Files that are not downloaded cannot open until TinyMounter starts again."

    // Notifications
    static func shareDisconnected(_ share: String) -> String { "“\(share)” is not connected" }
    static func cannotConnectTitle(_ host: String) -> String { "TinyMounter cannot connect to \(host)" }
    static let downloadFailedTitle = "A file cannot download"
    static func onSameNetwork(_ host: String) -> String {
        "Make sure that \(host) is on. Make sure that this Mac is on the same network."
    }
}
