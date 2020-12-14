/*
 *
 * AutoRaise
 *
 * Copyright (c) 2020 Stefan Post, Lothar Haeger
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import CoreServices
import Cocoa
import Foundation

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    // Settings
    @IBOutlet weak var window: NSWindow!

    @IBOutlet weak var delaySliderLabel: NSTextField!
    @IBOutlet weak var delaySlider: NSSlider!
    @IBOutlet weak var enableWarpButton: NSButton!
    // About
    @IBOutlet weak var aboutText: NSTextField!
    @IBOutlet weak var homePage: NSButton!
    

    let appAbout =  "AutoRaise\n" +
        "Version 1.0, 2020-12-13\n\n" +
        "©2020 Stefan Post, Lothar Haeger\n" +
        "Icons made by https://www.flaticon.com/authors/fr"
    
    let homePageUrl = "https://github.com/sbmpost/AutoRaise"

    let prefs = UserDefaults.standard

    var statusBar = NSStatusBar.system
    var menuBarItem : NSStatusItem = NSStatusItem()
    var menu: NSMenu = NSMenu()
    var menuItemPrefs : NSMenuItem = NSMenuItem()
    var menuItemQuit : NSMenuItem = NSMenuItem()
    var autoRaiseUrl : URL!
    var autoRaiseService: Process = Process()

    var autoRaiseDelay : NSInteger = 40
    var enableWarp = NSControl.StateValue.off

    let icon = NSImage(named: "MenuIcon")
    let iconRunning = NSImage(named: "MenuIconRunning")

    override func awakeFromNib() {

        // Build status bar menu
        menuBarItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        menuBarItem.title = ""

        if let button = menuBarItem.button {
            button.action = #selector(menuBarItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = icon
        }

        //"Preferences" menuItem
        menuItemPrefs.title = "Preferences"
        menuItemPrefs.action = #selector(Preferences(_:))
        menu.addItem(menuItemPrefs)
        
        // Separator
        menu.addItem(NSMenuItem.separator())
        
        // "Quit" menuItem
        menuItemQuit.title = "Quit"
        menuItemQuit.action = #selector(quitApplication(_:))
        menu.addItem(menuItemQuit)
    }

    @objc func menuBarItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == NSEvent.EventType.rightMouseUp {
            menuBarItem.popUpMenu(menu)
        } else {
            if autoRaiseService.isRunning {
                self.stopService(self)
            } else {
                self.startService(self)
            }
        }
    }

    @IBAction func autoRaiseDelay(_ sender: Any) {
        autoRaiseDelay = delaySlider.integerValue
        delaySliderLabel.stringValue = "Delay window activation for " + String(autoRaiseDelay) + " ms"
        self.prefs.set(autoRaiseDelay, forKey: "autoRaiseDelay")
        if autoRaiseService.isRunning {
            self.stopService(self)
            self.startService(self)
        }
    }

    @IBAction func enableWarp(_ sender: NSButton) {
        enableWarp = enableWarpButton.state
        self.prefs.set(enableWarp == NSControl.StateValue.on ? "1" : "0", forKey: "enableWarp")
        if autoRaiseService.isRunning {
            self.stopService(self)
            self.startService(self)
        }
    }

    func readPreferences() {
        if let rawValue = prefs.string(forKey: "enableWarp") {
            enableWarp = NSControl.StateValue(rawValue: Int(rawValue) ?? 0)
            autoRaiseDelay = prefs.integer(forKey: "autoRaiseDelay")
        }
        delaySliderLabel.stringValue = "Delay window activation for " + String(autoRaiseDelay) + " ms"
        enableWarpButton.state = enableWarp
        delaySlider.integerValue = autoRaiseDelay
    }

    @IBAction func homePagePressed(_ sender: NSButton) {
        let url = URL(string: homePageUrl)!
        NSWorkspace.shared.open(url)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.floatingWindow)))

        menuBarItem.button?.image = icon

        // update about tab contents
        aboutText.stringValue = appAbout
        // homepage link
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = NSTextAlignment.center
        homePage.attributedTitle = NSAttributedString(
            string: homePageUrl,
            attributes: [ NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13.0),
                          NSAttributedString.Key.foregroundColor: NSColor.blue,
                          NSAttributedString.Key.underlineStyle: 1,
                          NSAttributedString.Key.paragraphStyle: pstyle])
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        stopService(self)
    }

    func messageBox(_ message: String, description: String?=nil) -> Bool {
        let myPopup: NSAlert = NSAlert()
        myPopup.alertStyle = NSAlert.Style.critical
        myPopup.addButton(withTitle: "OK")
        myPopup.messageText = message
        if let informativeText = description {
            myPopup.informativeText = informativeText
        }
        return (myPopup.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn)
    }

    @objc func Preferences(_ sender: AnyObject){
        readPreferences()
        self.window.makeKeyAndOrderFront(self)
    }
    
    @objc func startService(_ sender: AnyObject) {
        if !autoRaiseService.isRunning {
            autoRaiseService = Process()
            let autoRaiseCmd = Bundle.main.url(forResource: "AutoRaise", withExtension: "")
            if FileManager().fileExists(atPath: autoRaiseCmd!.path) {
                autoRaiseService.launchPath = autoRaiseCmd?.path
                autoRaiseService.arguments = ["-delay", String(autoRaiseDelay / 20)]
                if ( enableWarp == NSControl.StateValue.on ) {
                    autoRaiseService.arguments! += ["-warpX", "0.5", "-warpY", "0.5"]
                }
            }
            autoRaiseService.launch()
        }
        menuBarItem.button?.image = iconRunning
    }

    @objc func stopService(_ sender: AnyObject) {
        if autoRaiseService.isRunning {
            autoRaiseService.terminate()
            autoRaiseService.waitUntilExit()
        }
        menuBarItem.button?.image = icon
    }

    @objc func quitApplication(_ sender: AnyObject) {
        NSApplication.shared.terminate(sender)
    }
}
