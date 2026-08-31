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
            message
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
                Text("Sago Drop")
                    .font(.system(size: 21, weight: .bold, design: .rounded))

                Text("Send your files anywhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var message: some View {
        Text("Drag a file onto the menu bar icon, or paste or select a file. If needed, your file will then be compressed with little quality loss, or turned into a public link when it's too large (you need to connect to GitHub for this). The result will then be copied to your clipboard. Boom! Now you can just paste and send it in Discord!")
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("For those files stuck in your clipboard, Sago Drop also helps you save them with an easy ⌥⌘V paste.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Got It") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
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
        window.title = "Sago Drop"
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
