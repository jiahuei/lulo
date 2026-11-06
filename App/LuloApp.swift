import AppKit

@main
@MainActor
final class LuloApp: NSObject, NSApplicationDelegate {
    private var viewer: ViewerController?

    static func main() {
        let app = NSApplication.shared
        let delegate = LuloApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        showViewer()
    }

    private func showViewer() {
        if viewer == nil { viewer = ViewerController() }
        viewer?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        showViewer()
        viewer?.open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showViewer()
        return true
    }

    private func makeMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "Lulo")
        application.submenu?.addItem(
            withTitle: "About Lulo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        application.submenu?.addItem(.separator())
        application.submenu?.addItem(
            withTitle: "Quit Lulo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application)
        let file = NSMenuItem()
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "Open…", action: #selector(openImage), keyEquivalent: "o")
        file.submenu?.addItem(withTitle: "Allow Folder Navigation…", action: #selector(allowFolder), keyEquivalent: "")
        file.submenu?.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(file)
        let view = NSMenuItem()
        view.submenu = NSMenu(title: "View")
        view.submenu?.addItem(withTitle: "Toggle Gallery", action: #selector(toggleGallery), keyEquivalent: "g")
        view.submenu?.addItem(withTitle: "Previous Image", action: #selector(previousImage), keyEquivalent: "[")
        view.submenu?.addItem(withTitle: "Next Image", action: #selector(nextImage), keyEquivalent: "]")
        view.submenu?.addItem(withTitle: "Toggle Metadata", action: #selector(toggleMetadata), keyEquivalent: "i")
        menu.addItem(view)
        NSApp.mainMenu = menu
    }

    @objc private func openImage() {
        showViewer()
        viewer?.openPanel()
    }
    @objc private func allowFolder() { viewer?.allowFolderNavigation() }
    @objc private func previousImage() { viewer?.previousImage() }
    @objc private func nextImage() { viewer?.nextImage() }
    @objc private func toggleMetadata() { viewer?.toggleSidebar() }
    @objc private func toggleGallery() { viewer?.toggleGallery() }
}
