import Foundation

/// All UI text, in ASD-STE100 (docs/ui-design.md §8), so the STE checker reads one file.
enum UIText {
    static let appName = "tinymounter"

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

    // Location pane
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
    static let connectionMode = "Connection Mode"
    static let fileProvider = "File Provider"
    static let fileProviderDescription = """
        Finder shows the files below Locations. A file downloads when you open it. \
        You can keep files on this Mac for offline use.
        """
    static let serverVolume = "Server volume"
    static let serverVolumeDescription = """
        macOS connects to the share, the same as Connect to Server in Finder. Files open directly from the \
        server. You cannot use it offline. Not available in this version.
        """
    static let keepDownloaded = "Keep Downloaded"
    static let requested = "Requested"
    static let notOnServer = "Not on the server"
    static let keepHint = "To keep a file downloaded, right-click it in Finder. Then click Keep Downloaded."
    static let draftKeepHint = """
        tinymounter downloads these items after you click Add. If an item is not in the folder, tinymounter \
        shows “Not on the server”.
        """
    static let removeLocationDescription = "Remove this location from this Mac. The files on the server do not change."
    static let draftBar = "Finder does not show this location until you click Add."
    static let applyBar = """
        If you change the source or the connection mode, tinymounter removes the downloaded copies of this \
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
    static let connectInServers = "Open Servers in tinymounter Settings. Then click Connect."
    static let selectShareAgain = "Select the share again in Servers."
    static let folderNotOnShare = "This folder is not on the share."
    static let catalogUnavailable = "tinymounter cannot read the data for this location. Remove the location. Then add it again."
    static let turnedOff = "This location is turned off in System Settings."
    static let problem = "Problem"

    static func cannotConnect(_ host: String) -> String {
        "tinymounter cannot connect to \(host). Make sure that \(host) is on. Make sure that this Mac is on the same network."
    }

    static func cannotDisconnect(_ share: String) -> String {
        "tinymounter cannot disconnect “\(share)”. Close the files that are open on it. Then try again."
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
        The files on the server do not change. tinymounter removes the downloaded copies of this location \
        from this Mac.
        """
    static let saveKeepList = "Save the Keep Downloaded list"
    static let removeLocation = "Remove Location"
    static func applyTitle(_ name: String) -> String { "Change the source of “\(name)”?" }
    static func downloadTitle(_ count: Int) -> String {
        count == 1 ? "Download 1 kept file now?" : "Download \(count) kept files now?"
    }
    static func downloadMessage(_ name: String) -> String {
        """
        tinymounter found items of the saved Keep Downloaded list in “\(name)”. They are in folders that you \
        did not open in Finder. They download only when you open these folders.
        """
    }
    static let downloadNow = "Download Now"
    static let notNow = "Not Now"

    // Errors
    static let settingsUnreadable = "tinymounter cannot read its settings file. You cannot add or change a location."
    static let domainsUnreadable = "tinymounter cannot read its locations from macOS. Quit tinymounter. Then open it again."
    static let wrongFolderPath = "This folder path is not correct. Type a path in the share."
    static let wrongName = "This name is not correct. Type a different name."
    static let notVolumeRoot = "This folder is not a share. Select the share, not a folder in it."
    static let notSMBShare = "This volume is not an SMB share. To add a share, click Add Share…."
    static let addressRejected = "tinymounter cannot use the address of this share."
    static let otherShare = "This is a different share. To add it, click Add Share…."
    static let shareNotMounted = "The share is not connected. In Servers, click Connect. Then click Select… again."
    static let wrongAddress = "This address is not correct. Type an address such as smb://server/share."
    static func passwordNotAccepted(_ host: String) -> String {
        "\(host) did not accept the password. Type the password again."
    }
    static let tooManyItems = "This folder has more than 100,000 items. tinymounter cannot show it."
    static let cannotShow = "Finder cannot show this location."
    static let serverInUse = "A location uses this server. Remove the location first."
    static func cannotDo(_ code: String) -> String { "tinymounter cannot do this (\(code))." }

    // Panels
    static let selectShareMessage = "Click Open to give tinymounter access to this share."
    static let selectFolderMessage = "Select a folder in the share."

    // Servers
    static let selectAgain = "Select Again…"
    static let notResponding = "Cannot connect"
    static let selectShareAgainShort = "Select the share again."
    static func accountAndShare(_ account: String, _ share: String) -> String { "\(account) · \(share)" }
    static let noServers = "To add a server, click Add Server…."
    static let noSelectedShares = "No shares selected."
    static let otherConnectedShares = "Other Connected Shares"
    static let useShare = "Use Share"
    static let useOtherAddressTitle = "Use the connection at this other address?"
    static func useOtherAddress(_ address: ShareAddress, server: String) -> String {
        "Use \(address.host) / \(address.share), connected as \(address.account), with \(server)? Disconnect and Remove eject this connection from this Mac."
    }
    static let connectAnotherShare = "Connect Another Share…"
    static let chooseShareDescription = """
        These shares are already connected on this Mac. To use one, select it and click Use Share. \
        To connect another share, click Connect Another Share. macOS asks for the password if necessary. \
        Select “Remember this password in my keychain”, so that tinymounter can connect again.
        """
    static func chooseShareTitle(_ host: String) -> String { "Choose a share for \(host)." }
    static func mountedShare(_ address: ShareAddress) -> String {
        "\(address.host) / \(address.share) · \(address.account)"
    }
    static func serverAddress(_ server: ServerRecord) -> String {
        server.account.map { "\($0)@\(server.host)" } ?? server.host
    }
    static let removeServerTitle = "Disconnect this server's shares and remove the server?"
    static let removeServerMessage = "The files on the server do not change. Other apps lose access to these connections."
    static let cannotRemoveServer = """
        tinymounter cannot remove this server. Its entry has been kept. Close files that are open on its \
        shares. Then try again.
        """
    static let serverSetupHint = "To show files in Finder, add a location under Locations."
    static let disconnectHint = "Disconnect ejects the share from this Mac, including its connection in Finder."

    // General
    static let openAtLogin = "Open at login"
    static let openAtLoginApproval = "Allow tinymounter in System Settings › General › Login Items & Extensions."
    static let showInMenuBar = "Show in menu bar"
    static let menuBarDescription = """
        The menu bar item keeps tinymounter open. tinymounter must be open to read data that is not downloaded.
        """
    static let notifications = "Notifications"
    static let notificationsDescription = "Show a notification when a share disconnects or a download cannot start."

    // Storage
    static let notAvailable = "Not available"
    static let total = "Total"
    static let storageDescription = """
        This includes the kept files. When disk space is low, macOS removes the downloaded files that you do \
        not keep. Remove Downloads removes them immediately.
        """
    static let removeDownloadsMenu = "Remove Downloads…"
    static let removeDownloads = "Remove Downloads"
    static let cannotRemoveDownloads = "tinymounter cannot remove the downloads of this location."

    static func removeDownloadsTitle(_ name: String) -> String { "Remove the downloads of “\(name)”?" }

    static func removeDownloadsMessage(files: Int, bytes: Int64) -> String {
        let count = files == 1 ? "1 file" : "\(files) files"
        return """
            tinymounter removes the downloaded copies of \(count) (\(size(bytes))) that you do not keep. Kept files \
            stay on this Mac. The files on the server do not change.
            """
    }

    static func downloadsStayed(_ files: Int) -> String {
        let (count, them) = files == 1 ? ("1 downloaded file", "it") : ("\(files) downloaded files", "them")
        return "tinymounter cannot remove \(count). If an app uses \(them), close the app. Then try again."
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
    static let version = "Version 0.1 (prototype)"
    static let diagnostics = "Diagnostics"
    static let diagnosticsDescription = "This report helps to find problems. It does not include file names, paths, or passwords."
    static let copy = "Copy"

    // Menu bar
    static let pauseDownloads = "Pause Downloads"
    static let resumeDownloads = "Resume Downloads"
    static let quit = "Quit tinymounter"
    static let noLocations = "No locations"
    static let pauseFailed = "tinymounter cannot stop background downloads for one or more locations."
    static let resumeFailed = "tinymounter cannot start background downloads again for one or more locations."

    // Quit
    static let quitTitle = "Downloads are in progress."
    static let quitMessage = "Files that are not downloaded cannot open until tinymounter starts again."

    // Notifications
    static func shareDisconnected(_ share: String) -> String { "“\(share)” is not connected" }
    static func cannotConnectTitle(_ host: String) -> String { "tinymounter cannot connect to \(host)" }
    static let downloadFailedTitle = "A file cannot download"
    static func onSameNetwork(_ host: String) -> String {
        "Make sure that \(host) is on. Make sure that this Mac is on the same network."
    }
}
