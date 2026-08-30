import AppKit
import SwiftUI

enum HowItWorksPresentation {
    private static let seenKey = "hasSeenHowItWorksV1"

    static func shouldShow(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markShown(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

struct HowItWorksView: View {
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
        HStack(spacing: 16) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("How Sago Drop works")
                    .font(.system(size: 21, weight: .bold, design: .rounded))

                Text("Drop a file on the menu-bar icon, or copy it and press ⌘V.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 26)
        .padding(.horizontal, 26)
        .padding(.bottom, 20)
    }

    private var routeSection: some View {
        VStack(spacing: 0) {
            RouteRow(
                symbol: "paperclip",
                title: "Fits your limit",
                detail: "Copied as an attachment. Video compression stays on your Mac."
            )
            Divider().padding(.leading, 54)
            RouteRow(
                symbol: "link",
                title: "Needs a link",
                detail: "Files that cannot fit become public Sago Media links. Video never drops below 720p."
            )
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 20)
    }

    private var footer: some View {
        HStack {
            Text("Set your Discord limit and sign in from Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
    }
}

private struct RouteRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
    }
}

#if !SAGO_DROP_MOCKUP
@MainActor
final class HowItWorksWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "How Sago Drop Works"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        let hostingView = NSHostingView(rootView: makeView())
        hostingView.layoutSubtreeIfNeeded()
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeView() -> HowItWorksView {
        HowItWorksView(
            appIcon: AppResources.appIcon,
            onDone: { [weak self] in self?.close() }
        )
    }
}
#endif
