import AppKit
import SwiftUI

private let scale: CGFloat = 2
private let menuWidth: CGFloat = 250
private let menuBarHeight: CGFloat = 30
private let menuBarLogo = NSImage(contentsOfFile: "assets/sago-drop-mark.svg")

@main
@MainActor
struct MenuMockup {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2,
              let state = MockupState(rawValue: arguments[0]) else {
            fputs("Usage: MenuMockup <before|after|update-before|update-after|how-it-works> <output.png>\n", stderr)
            exit(2)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        captureController = CaptureController(state: state, outputPath: arguments[1])
        app.delegate = captureController
        app.run()
    }
}

@MainActor private var captureController: CaptureController?

private enum MockupState: String {
    case before
    case after
    case updateBefore = "update-before"
    case updateAfter = "update-after"
    case howItWorks = "how-it-works"

    var usesSmartSharing: Bool { self != .before && self != .howItWorks }
    var showsAutoUpdate: Bool { self == .updateAfter }
    var canvasSize: CGSize {
        self == .howItWorks
            ? CGSize(width: 760, height: 500)
            : CGSize(width: 760, height: 450)
    }
}

private struct MenuMockupView: View {
    let state: MockupState

    var body: some View {
        ZStack(alignment: .topLeading) {
            DesktopBackground()

            if state == .howItWorks {
                HowItWorksView(
                    appIcon: NSImage(contentsOfFile: "assets/sago-drop-logo.svg"),
                    onDone: {}
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .position(x: state.canvasSize.width / 2, y: state.canvasSize.height / 2)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: menuBarHeight)

                statusItem
                    .position(x: 385, y: menuBarHeight / 2)

                menu
                    .padding(.leading, 245)
                    .padding(.top, menuBarHeight + 1)

                if state.usesSmartSharing {
                    discordLimitMenu
                        .padding(.leading, 245 + menuWidth + 2)
                        .padding(.top, menuBarHeight + 94)
                }
            }
        }
        .frame(width: state.canvasSize.width, height: state.canvasSize.height)
        .preferredColorScheme(.dark)
    }

    private var statusItem: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.18))
                .frame(width: 30, height: 24)

            if let menuBarLogo {
                Image(nsImage: menuBarLogo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
        }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            MenuRow(state.usesSmartSharing ? "Share Files…" : "Upload Files…", shortcut: "⌘O")
            if state.usesSmartSharing {
                MenuRow("Share Copied Files", shortcut: "⌘V")
                MenuSeparator()
                MenuRow("Save Clipboard", shortcut: "⌥⌘V")
            } else {
                MenuRow("Upload Copied Files", shortcut: "⇧⌘V")
                MenuRow("Save Clipboard", shortcut: "⌘V")
            }
            MenuSeparator()
            if state.usesSmartSharing {
                MenuRow("Discord Upload Limit", shortcut: "›")
                MenuSeparator()
            }
            MenuRow("Sign In")
            MenuSeparator()
            MenuRow("Open at Login")
            if state.showsAutoUpdate {
                MenuRow("Update Available")
            }
            MenuRow("How Sago Drop Works…")
            MenuSeparator()
            MenuRow("Quit")
        }
        .padding(.vertical, 5)
        .frame(width: menuWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 9)
    }

    private var discordLimitMenu: some View {
        VStack(spacing: 0) {
            MenuRow("✓  Free, 20 MB")
            MenuRow("    Nitro Basic, 50 MB")
            MenuRow("    Nitro, 500 MB")
        }
        .padding(.vertical, 5)
        .frame(width: 210)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 9)
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String?

    init(_ title: String, shortcut: String? = nil) {
        self.title = title
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 25)
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 0.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

private struct DesktopBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.13, blue: 0.22),
                    Color(red: 0.16, green: 0.30, blue: 0.43),
                    Color(red: 0.46, green: 0.20, blue: 0.39),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.cyan.opacity(0.55), .clear],
                center: UnitPoint(x: 0.18, y: 0.18),
                startRadius: 5,
                endRadius: 280
            )

            RadialGradient(
                colors: [Color.orange.opacity(0.48), .clear],
                center: UnitPoint(x: 0.88, y: 0.8),
                startRadius: 10,
                endRadius: 300
            )
        }
    }
}

private enum RenderError: Error {
    case missingScreen
    case missingWindowID
    case missingCaptureFunction
    case captureFailed
    case pngEncodingFailed
}

private typealias WindowCaptureFunction = @convention(c) (
    CGRect,
    UInt32,
    CGWindowID,
    UInt32
) -> Unmanaged<CGImage>?

@MainActor
private final class CaptureController: NSObject, NSApplicationDelegate {
    private let state: MockupState
    private let outputPath: String
    private var window: NSWindow?

    init(state: MockupState, outputPath: String) {
        self.state = state
        self.outputPath = outputPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            window = try makeWindow()
            window?.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.captureAndExit()
            }
        } catch {
            fail(error)
        }
    }

    private func makeWindow() throws -> NSWindow {
        guard let screen = NSScreen.main else { throw RenderError.missingScreen }
        let renderedSize = CGSize(
            width: state.canvasSize.width * scale,
            height: state.canvasSize.height * scale
        )

        let rootView = MenuMockupView(state: state)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: renderedSize.width, height: renderedSize.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: renderedSize)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: renderedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.contentView = hostingView
        window.center()
        hostingView.layoutSubtreeIfNeeded()
        return window
    }

    private func captureAndExit() {
        do {
            guard let window,
                  let windowID = CGWindowID(exactly: window.windowNumber) else {
                throw RenderError.missingWindowID
            }

            for _ in 0..<6 {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                window.displayIfNeeded()
            }

            guard let capture = windowCaptureFunction() else {
                throw RenderError.missingCaptureFunction
            }
            var image: CGImage?
            for _ in 0..<5 {
                image = capture(
                    .null,
                    CGWindowListOption.optionIncludingWindow.rawValue,
                    windowID,
                    CGWindowImageOption.boundsIgnoreFraming.rawValue
                )?.takeRetainedValue()
                if image != nil { break }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            guard let image else {
                throw RenderError.captureFailed
            }

            try writePNG(image, to: URL(fileURLWithPath: outputPath))
            print("Wrote \(outputPath)")
            NSApplication.shared.terminate(nil)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) -> Never {
        fputs("Menu mockup failed: \(error)\n", stderr)
        exit(1)
    }
}

private func windowCaptureFunction() -> WindowCaptureFunction? {
    guard let handle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        RTLD_NOW
    ), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
        return nil
    }
    return unsafeBitCast(symbol, to: WindowCaptureFunction.self)
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw RenderError.pngEncodingFailed
    }
    try data.write(to: url, options: .atomic)
}
