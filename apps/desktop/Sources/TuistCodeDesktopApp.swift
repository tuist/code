import Sparkle
import AppKit

@main
enum TuistCodeDesktopApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = TuistCodeDesktopApplicationDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
private final class TuistCodeDesktopApplicationDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var mainWindowController: AppKitMainWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        let mainWindowController = AppKitMainWindowController()
        self.mainWindowController = mainWindowController
        configureMainMenu(for: mainWindowController)
        mainWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    private func configureMainMenu(for controller: AppKitMainWindowController) {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: "About Tuist Code",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let updateItem = applicationMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(
            withTitle: "Settings…",
            action: #selector(AppKitMainWindowController.showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = controller
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Hide Tuist Code",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(
            withTitle: "Quit Tuist Code",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        addItem("New Workspace…", action: #selector(controller.newWorkspace(_:)), key: "n", to: fileMenu, target: controller)
        addItem("Add Local Repository…", action: #selector(controller.addLocalRepository(_:)), key: "o", to: fileMenu, target: controller)
        addItem("Clone Repository…", action: #selector(controller.cloneRepository(_:)), key: "", to: fileMenu, target: controller)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func addItem(
        _ title: String,
        action: Selector,
        key: String,
        to menu: NSMenu,
        target: AnyObject
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
    }

    @objc private func checkForUpdates(_: Any?) {
        updaterController.checkForUpdates(nil)
    }
}
