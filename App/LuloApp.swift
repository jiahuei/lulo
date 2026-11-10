import AppKit
import LuloCore

@main
@MainActor
final class LuloApp: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
        file.submenu?.addItem(withTitle: "Move to Trash…", action: #selector(trashImage), keyEquivalent: "\u{8}")
        file.submenu?.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(file)
        let view = NSMenuItem()
        view.submenu = NSMenu(title: "View")
        view.submenu?.addItem(withTitle: "Refresh", action: #selector(refreshImages), keyEquivalent: "r")
        view.submenu?.addItem(withTitle: "Toggle Gallery", action: #selector(toggleGallery), keyEquivalent: "g")
        view.submenu?.addItem(withTitle: "Previous Image", action: #selector(previousImage), keyEquivalent: "[")
        view.submenu?.addItem(withTitle: "Next Image", action: #selector(nextImage), keyEquivalent: "]")
        view.submenu?.addItem(withTitle: "Toggle Metadata", action: #selector(toggleMetadata), keyEquivalent: "i")
        view.submenu?.addItem(.separator())
        // Finder uses Command-1 and Command-2 for its view styles; these are radio-checked the same way.
        view.submenu?.addItem(withTitle: "as Rows", action: #selector(showRows), keyEquivalent: "1")
        view.submenu?.addItem(withTitle: "as Preview", action: #selector(showPreview), keyEquivalent: "2")
        view.submenu?.addItem(withTitle: "Larger Thumbnails", action: #selector(largerThumbnails), keyEquivalent: "+")
        view.submenu?.addItem(withTitle: "Smaller Thumbnails", action: #selector(smallerThumbnails), keyEquivalent: "-")
        view.submenu?.addItem(.separator())
        let background = NSMenuItem(
            title: "Blurred Background", action: #selector(toggleBlurredBackground), keyEquivalent: "b")
        background.keyEquivalentModifierMask = [.command, .option]
        view.submenu?.addItem(background)
        menu.addItem(view)
        NSApp.mainMenu = menu
    }

    @objc private func openImage() {
        showViewer()
        viewer?.openPanel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(trashImage) { return viewer?.canTrashCurrentImage == true }
        if menuItem.action == #selector(refreshImages) { return viewer?.canRefresh == true }
        if menuItem.action == #selector(showRows) || menuItem.action == #selector(showPreview) {
            let layout = menuItem.action == #selector(showRows) ? GalleryLayout.rows : .preview
            menuItem.state = viewer?.galleryLayout == layout ? .on : .off
        }
        if menuItem.action == #selector(toggleBlurredBackground) {
            menuItem.state = viewer?.blurredBackground == true ? .on : .off
        }
        if menuItem.action == #selector(largerThumbnails) || menuItem.action == #selector(smallerThumbnails) {
            return viewer?.isGalleryVisible == true
        }
        return true
    }

    @objc private func trashImage() { viewer?.trashCurrentImage() }
    @objc private func refreshImages() { viewer?.refreshImages() }
    @objc private func allowFolder() { viewer?.allowFolderNavigation() }
    @objc private func previousImage() { viewer?.previousImage() }
    @objc private func nextImage() { viewer?.nextImage() }
    @objc private func toggleMetadata() { viewer?.toggleSidebar() }
    @objc private func toggleGallery() { viewer?.toggleGallery() }
    @objc private func showRows() { viewer?.showRows() }
    @objc private func showPreview() { viewer?.showPreview() }
    @objc private func largerThumbnails() { viewer?.largerThumbnails() }
    @objc private func smallerThumbnails() { viewer?.smallerThumbnails() }
    @objc private func toggleBlurredBackground() { viewer?.toggleBlurredBackground() }
}
