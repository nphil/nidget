import SwiftUI

// MARK: - FilePickView
//
// Onboarding step 2: pick a budget file from the server (`.needsFilePick`'s payload).
// Encrypted files carry a lock badge and expand in place for the E2E password. Opening a file
// calls `store.selectFile`, which flips the setup state to `.syncingFirstTime`; if that throws,
// RootContentView recreates this screen with the failure preserved through `failureMessage`
// (a binding to RootContentView state, since this instance is torn down mid-flight).

struct FilePickView: View {
    private let files: [RemoteFile]
    @Binding private var failureMessage: String?

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedID: String?
    @State private var e2ePassword = ""
    @State private var isOpening = false
    @FocusState private var passwordFocused: Bool

    init(files: [RemoteFile], failureMessage: Binding<String?>) {
        self.files = files
        self._failureMessage = failureMessage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.cardSpacing) {
                header
                if let failureMessage {
                    failureBanner(failureMessage)
                }
                if files.isEmpty {
                    EmptyStateView(systemImage: "tray",
                                   title: "No budgets on this server",
                                   message: "Create a budget file in Actual first — Nidget will spot it as soon as it exists.",
                                   actionTitle: "Check Again",
                                   action: { Task { await store.bootstrap() } })
                        .padding(.top, theme.layout.spacing * 2)
                } else {
                    ForEach(files) { file in
                        fileCard(file)
                    }
                }
            }
            .padding(.horizontal, theme.layout.spacing * 2)
            .padding(.vertical, theme.layout.spacing)
        }
        .scrollDismissesKeyboard(.interactively)
        .themedScreen()
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step 2 of 2")
                .font(theme.font(.label))
                .textCase(theme.typography.labelCase)
                .tracking(theme.typography.labelTracking)
                .foregroundStyle(theme.palette.accent)
            Text("Pick a budget")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
            Text("These live on your server. Choose the one Nidget should carry around.")
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.layout.spacing * 0.75) {
            Image(systemName: "exclamationmark.triangle")
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.negative)
                .accessibilityHidden(true)
            Text(message)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.negative)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .themedCard(padding: 12)
    }

    // MARK: File cards

    private func fileCard(_ file: RemoteFile) -> some View {
        let isEncrypted = file.encryptKeyID != nil
        let isSelected = selectedID == file.fileID
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                cardTapped(file)
            } label: {
                HStack(spacing: theme.layout.spacing) {
                    fileIcon(encrypted: isEncrypted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(theme.font(.headline))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(2)
                        Text(isEncrypted ? "End-to-end encrypted" : "Ready to open")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if isOpening && isSelected {
                        ProgressView()
                            .tint(theme.palette.accent)
                    } else {
                        Image(systemName: isEncrypted ? (isSelected ? "chevron.up" : "chevron.down")
                                                      : "chevron.right")
                            .font(theme.font(.caption))
                            .fontWeight(theme.icons.weight)
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
            .disabled(isOpening)
            .accessibilityHint(isEncrypted ? "Requires an encryption password" : "Opens this budget")

            if isEncrypted && isSelected {
                e2ePasswordSection(for: file)
            }
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring, value: selectedID)
    }

    private func e2ePasswordSection(for file: RemoteFile) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SecureField("Encryption password", text: $e2ePassword)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($passwordFocused)
                .onSubmit { openSelected(file) }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(fieldShape.fill(theme.palette.fill))
            Text("This budget has a second password that never leaves your devices.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            NidgetButton(isOpening ? "Opening…" : "Unlock & Open",
                         systemImage: "key",
                         action: { openSelected(file) })
                .disabled(e2ePassword.isEmpty || isOpening)
                .opacity(e2ePassword.isEmpty || isOpening ? 0.55 : 1)
        }
        .padding(.top, theme.layout.spacing)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func fileIcon(encrypted: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "book.closed")
                .font(theme.font(.title))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
            if encrypted {
                Image(systemName: "lock.circle.fill")
                    .font(theme.font(.caption))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.palette.onAccent, theme.palette.accentSecondary)
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 36)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func cardTapped(_ file: RemoteFile) {
        failureMessage = nil
        if file.encryptKeyID != nil {
            let newSelection = selectedID == file.fileID ? nil : file.fileID
            if reduceMotion {
                selectedID = newSelection
            } else {
                withAnimation(theme.motion.spring) { selectedID = newSelection }
            }
            e2ePassword = ""
            if newSelection != nil {
                passwordFocused = true
            }
        } else {
            selectedID = file.fileID
            open(file, e2ePassword: nil)
        }
    }

    private func openSelected(_ file: RemoteFile) {
        guard !e2ePassword.isEmpty else { return }
        open(file, e2ePassword: e2ePassword)
    }

    private func open(_ file: RemoteFile, e2ePassword: String?) {
        guard !isOpening else { return }
        isOpening = true
        passwordFocused = false
        failureMessage = nil
        // Deliberately unstructured: `selectFile` flips the setup state and this view gets
        // torn down mid-call; the failure lands in the binding that outlives this instance.
        Task {
            do {
                try await store.selectFile(file, e2ePassword: e2ePassword)
                Haptics.success()
            } catch {
                failureMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't open that budget. Give it another try."
                Haptics.warning()
            }
            isOpening = false
        }
    }

    private var fieldShape: AnyShape {
        theme.shape.buttonsAreCapsule ? AnyShape(Capsule()) : AnyShape(theme.controlShape)
    }
}
