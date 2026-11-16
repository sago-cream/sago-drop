import AppKit

@MainActor
enum UpdateRequiredPresentation {
    static func makeAlert(icon: NSImage?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update Sago Drop"
        alert.informativeText = "Install the latest version to continue sharing public links. Sago Drop will relaunch after updating."
        alert.icon = icon
        alert.addButton(withTitle: "Update Sago Drop")
        alert.addButton(withTitle: "Later")
        return alert
    }
}
