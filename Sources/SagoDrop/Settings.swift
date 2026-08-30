import AppKit
import SwiftUI

enum SettingsPresentation {
    private static let seenKey = "hasSeenHowItWorksV1"

    static func shouldShow(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markShown(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

struct SettingsLimitOption: Identifiable {
    let id: Int64
    let title: String
}

@MainActor
final class SettingsState: ObservableObject {
    let appIcon: NSImage?
    let limitOptions: [SettingsLimitOption]

    @Published var selectedLimit: Int64
    @Published var openAtLogin: Bool
    @Published var isSignedIn: Bool
    @Published var isAccountBusy = false

    var onSelectLimit: (Int64) -> Void = { _ in }
    var onSetOpenAtLogin: (Bool) -> Bool = { $0 }
    var onSetSignedIn: (Bool) -> Void = { _ in }

    init(
        appIcon: NSImage?,
        limitOptions: [SettingsLimitOption],
        selectedLimit: Int64,
        openAtLogin: Bool,
        isSignedIn: Bool
    ) {
        self.appIcon = appIcon
        self.limitOptions = limitOptions
        self.selectedLimit = selectedLimit
        self.openAtLogin = openAtLogin
        self.isSignedIn = isSignedIn
    }

    func selectLimit(_ value: Int64) {
        selectedLimit = value
        onSelectLimit(value)
    }

    func setOpenAtLogin(_ enabled: Bool) {
        openAtLogin = onSetOpenAtLogin(enabled)
    }

    func toggleSignIn() {
        isAccountBusy = true
        onSetSignedIn(!isSignedIn)
    }
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            routeSection
            settingsSection
            footer
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let appIcon = state.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Sago Drop is ready")
                    .font(.system(size: 21, weight: .bold, design: .rounded))

                Text("Sago Drop lives in your Mac’s menu bar, not the Dock. Drag a file onto its S icon, or copy a file in Finder and choose Share Copied Files from the S menu.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var routeSection: some View {
        VStack(spacing: 0) {
            RouteRow(
                symbol: "paperclip",
                title: "If it fits in Discord",
                detail: "Sago Drop copies the file itself. Large videos are compressed on this Mac only when they can stay at 720p or better."
            )
            Divider().padding(.leading, 54)
            RouteRow(
                symbol: "link",
                title: "If it is still too large",
                detail: "Sago Drop asks before uploading it to Sago Media, then copies a public link. Anyone with that link can open the file."
            )
        }
        .panelStyle()
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var settingsSection: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Your Discord plan", detail: "Sets the largest file Discord accepts for you.") {
                Picker("Your Discord plan", selection: Binding(
                    get: { state.selectedLimit },
                    set: { state.selectLimit($0) }
                )) {
                    ForEach(state.limitOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(width: 172)
            }

            Divider().padding(.leading, 16)

            SettingsRow(title: "Sago Media", detail: "Sign in only if you want files to become links.") {
                Button(state.isSignedIn ? "Sign Out" : "Sign In…") {
                    state.toggleSignIn()
                }
                .disabled(state.isAccountBusy)
            }

            Divider().padding(.leading, 16)

            SettingsRow(title: "Open at Login", detail: "Keeps the S icon ready after restarting your Mac.") {
                Toggle("Open at Login", isOn: Binding(
                    get: { state.openAtLogin },
                    set: { state.setOpenAtLogin($0) }
                ))
                .labelsHidden()
            }
        }
        .panelStyle()
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("When Sago Drop finishes, paste the copied file or link into Discord with ⌘V.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Done") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

private struct RouteRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
    }
}

private extension View {
    func panelStyle() -> some View {
        background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

#if !SAGO_DROP_MOCKUP
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: UploadModel
    private let state: SettingsState

    init(model: UploadModel) {
        self.model = model
        state = SettingsState(
            appIcon: AppResources.appIcon,
            limitOptions: DiscordUploadLimit.allCases.map { .init(id: $0.rawValue, title: $0.title) },
            selectedLimit: model.discordUploadLimit.rawValue,
            openAtLogin: SMAppService.mainApp.status == .enabled,
            isSignedIn: model.isSignedIn
        )

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sago Drop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        super.init(window: window)

        state.onSelectLimit = { [weak model] rawValue in
            guard let limit = DiscordUploadLimit(rawValue: rawValue) else { return }
            model?.discordUploadLimit = limit
        }
        state.onSetOpenAtLogin = { [weak self] enabled in
            self?.setOpenAtLogin(enabled) ?? false
        }
        state.onSetSignedIn = { [weak model, weak state] shouldSignIn in
            guard let model, !model.isUploading else {
                state?.isAccountBusy = false
                return
            }
            if shouldSignIn { model.login() } else { model.logout() }
        }
        model.onAuthenticationChange = { [weak state] isSignedIn in
            state?.isSignedIn = isSignedIn
            state?.isAccountBusy = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        state.selectedLimit = model.discordUploadLimit.rawValue
        state.openAtLogin = SMAppService.mainApp.status == .enabled
        state.isSignedIn = model.isSignedIn
        state.isAccountBusy = model.isUploading

        let hostingView = NSHostingView(rootView: SettingsView(
            state: state,
            onDone: { [weak self] in self?.close() }
        ))
        hostingView.layoutSubtreeIfNeeded()
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func setOpenAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    SMAppService.openSystemSettingsLoginItems()
                case .notFound, .notRegistered:
                    try SMAppService.mainApp.register()
                @unknown default:
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            model.reportAttention("Couldn’t update Open at Login")
            NSSound.beep()
        }
        return SMAppService.mainApp.status == .enabled
    }
}
#endif
