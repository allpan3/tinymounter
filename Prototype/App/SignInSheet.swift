import SwiftUI

/// What opened the sign-in sheet.
struct SignInRequest: Identifiable {
    enum Purpose {
        /// Add Server… in a location's Server menu.
        case add(locationID: UUID)
        /// Sign In Again… for a saved server: Server and Name are fixed.
        case again(ServerRecord)
    }

    let id = UUID()
    let purpose: Purpose

    var fixed: ServerAccount? {
        if case .again(let server) = purpose { server.login } else { nil }
    }
}

/// Signs in with the password and returns the share names. A refused name or password throws
/// `SourceFailure.notAuthenticated`. The bytes are UTF-8.
typealias ShareLister = @Sendable (ServerAccount, Data) async throws -> [String]

/// Connection-layer plan, UI changes: Server, Name, Password, Cancel and Sign In.
struct SignInSheet: View {
    let request: SignInRequest
    /// Nil when the sign-in is saved, else the text to show in the sheet.
    let signIn: (_ server: String, _ name: String, _ password: Data) async -> String?
    let cancel: () -> Void

    @State private var server = ""
    @State private var name = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.fixed.map { UIText.signInAgainTitle($0.host) } ?? UIText.signInTitle).font(.headline)
            Form {
                TextField(UIText.server, text: $server, prompt: Text(UIText.addressPlaceholder))
                    .disabled(request.fixed != nil)
                TextField(UIText.name, text: $name)
                    .disabled(request.fixed != nil)
                SecureField(UIText.password, text: $password)
                    .onSubmit(submit)
            }
            Text(message ?? UIText.signInDescription)
                .font(.callout)
                .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(UIText.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(UIText.signIn, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || password.isEmpty || (request.fixed == nil && server.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
        .disabled(busy)
        .onAppear {
            if let fixed = request.fixed {
                server = fixed.host
                name = fixed.account
            }
        }
    }

    private func submit() {
        guard !busy, !password.isEmpty else { return }
        // The field's String can't be cleared from memory; keep only one copy as bytes.
        var bytes = Data(password.utf8)
        password = ""
        busy = true
        message = nil
        Task {
            message = await signIn(server, name, bytes)
            bytes.resetBytes(in: 0..<bytes.count)
            busy = false
        }
    }
}
