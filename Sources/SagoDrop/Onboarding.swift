import AppKit
import SwiftUI

enum OnboardingPresentation {
    private static let seenKey = "hasSeenHowItWorksV1"

    static func shouldShow(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markShown(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

struct OnboardingView: View {
    let appIcon: NSImage?
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            routeSection
            footer
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome to Sago Drop")
                    .font(.system(size: 21, weight: .bold, design: .rounded))

                Text("Sago Drop lives in your Mac's menu bar, not the Dock. Drag a file onto its S icon, or copy a file in Finder and choose Share Copied Files from the S menu.")
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
            OnboardingRow(
                symbol: "paperclip",
                title: "If it fits in Discord",
                detail: "Sago Drop copies the file itself. It can compress large videos on this Mac, but never below 720p."
            )
            Divider().padding(.leading, 54)
            OnboardingRow(
                symbol: "link",
                title: "If it is still too large",
                detail: "Sago Drop asks before uploading it to Sago Media, then copies a public link. Anyone with the link can open the file."
            )
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Your Discord limit, Sago Media sign-in, and Open at Login stay in the S menu. After sharing, paste into Discord with ⌘V.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Get Started") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

private struct OnboardingRow: View {
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

#if !SAGO_DROP_MOCKUP
@MainActor
final class OnboardingWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Sago Drop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        let hostingView = NSHostingView(rootView: OnboardingView(
            appIcon: AppResources.appIcon,
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
}
#endif
