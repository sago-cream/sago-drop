import AppKit
import SwiftUI

struct SettingsLimitOption: Identifiable {
    let id: Int64
    let title: String
}

struct SettingsUpdatePresentation: Equatable {
    let title: String
    let canActivate: Bool
}

@MainActor
final class SettingsState: ObservableObject {
    let appIcon: NSImage?
    let limitOptions: [SettingsLimitOption]

    @Published var selectedLimit: Int64
    @Published var openAtLogin: Bool
    @Published var isSignedIn: Bool
    @Published var isAccountBusy = false
    @Published var update: SettingsUpdatePresentation

    var onSelectLimit: (Int64) -> Void = { _ in }
    var onSetOpenAtLogin: (Bool) -> Bool = { $0 }
    var onSetSignedIn: (Bool) -> Void = { _ in }
    var onActivateUpdate: () async -> Void = {}
    var onShowHowItWorks: () -> Void = {}

    init(
        appIcon: NSImage?,
        limitOptions: [SettingsLimitOption],
        selectedLimit: Int64,
        openAtLogin: Bool,
        isSignedIn: Bool,
        update: SettingsUpdatePresentation
    ) {
        self.appIcon = appIcon
        self.limitOptions = limitOptions
        self.selectedLimit = selectedLimit
        self.openAtLogin = openAtLogin
        self.isSignedIn = isSignedIn
        self.update = update
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

    func activateUpdate() {
        guard update.canActivate else { return }
        Task { await onActivateUpdate() }
    }
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(spacing: 0) {
            header
            settings
            footer
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let appIcon = state.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("Choose how Sago Drop handles files and starts on your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 26)
        .padding(.horizontal, 26)
        .padding(.bottom, 20)
    }

    private var settings: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Discord upload limit", detail: "Used for direct attachments.") {
                Picker("Discord upload limit", selection: Binding(
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

            SettingsRow(title: "Sago Media", detail: "Required only for public links.") {
                Button(state.isSignedIn ? "Sign Out" : "Sign In…") {
                    state.toggleSignIn()
                }
                .disabled(state.isAccountBusy)
            }

            Divider().padding(.leading, 16)

            SettingsRow(title: "Open at Login", detail: "Keep Sago Drop ready in the menu bar.") {
                Toggle("Open at Login", isOn: Binding(
                    get: { state.openAtLogin },
                    set: { state.setOpenAtLogin($0) }
                ))
                .labelsHidden()
            }

            Divider().padding(.leading, 16)

            SettingsRow(title: "Updates", detail: "Checked automatically once a day.") {
                Button(state.update.title) {
                    state.activateUpdate()
                }
                .disabled(!state.update.canActivate)
            }
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack {
            Button("How Sago Drop Works…") {
                state.onShowHowItWorks()
            }
            Spacer()
            Text("Changes save automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
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

#if !SAGO_DROP_MOCKUP
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: UploadModel
    private let autoUpdateStore: AutoUpdateStore
    private let howItWorksWindowController: HowItWorksWindowController
    private let state: SettingsState

    init(
        model: UploadModel,
        autoUpdateStore: AutoUpdateStore,
        howItWorksWindowController: HowItWorksWindowController
    ) {
        self.model = model
        self.autoUpdateStore = autoUpdateStore
        self.howItWorksWindowController = howItWorksWindowController
        state = SettingsState(
            appIcon: AppResources.appIcon,
            limitOptions: DiscordUploadLimit.allCases.map { .init(id: $0.rawValue, title: $0.title) },
            selectedLimit: model.discordUploadLimit.rawValue,
            openAtLogin: SMAppService.mainApp.status == .enabled,
            isSignedIn: model.isSignedIn,
            update: .init(
                title: autoUpdateStore.status.menuTitle,
                canActivate: autoUpdateStore.status.canActivate
            )
        )

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sago Drop Settings"
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
        state.onActivateUpdate = { [weak autoUpdateStore] in
            await autoUpdateStore?.activatePrimaryAction()
        }
        state.onShowHowItWorks = { [weak self] in
            self?.close()
            self?.howItWorksWindowController.show()
        }
        model.onAuthenticationChange = { [weak state] isSignedIn in
            state?.isSignedIn = isSignedIn
            state?.isAccountBusy = false
        }
        autoUpdateStore.onStatusChange = { [weak state] status in
            state?.update = .init(title: status.menuTitle, canActivate: status.canActivate)
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
        state.update = .init(
            title: autoUpdateStore.status.menuTitle,
            canActivate: autoUpdateStore.status.canActivate
        )

        let hostingView = NSHostingView(rootView: SettingsView(state: state))
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
