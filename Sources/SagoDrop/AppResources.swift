import AppKit
import Foundation

enum AppResources {
    private static let sourceAssetsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("assets", isDirectory: true)

    static var appIcon: NSImage? {
        image(named: "sago-drop-logo")
    }

    static var menuBarIcon: NSImage? {
        image(named: "sago-drop-mark")
    }

    private static func image(named name: String) -> NSImage? {
        let bundledURL = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "assets"
        )
        let sourceURL = sourceAssetsURL
            .appendingPathComponent(name)
            .appendingPathExtension("svg")
        return NSImage(contentsOf: bundledURL ?? sourceURL)
    }
}
