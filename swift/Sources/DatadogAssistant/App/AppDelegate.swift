import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private let dataSource = MockDataSource()

    func applicationDidFinishLaunching(_ notification: Notification) {
        dataSource.start()
        menuBar = MenuBarController(dataSource: dataSource)
    }

    func applicationWillTerminate(_ notification: Notification) {
        dataSource.stop()
    }
}
