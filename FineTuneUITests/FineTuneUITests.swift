import XCTest

final class FineTuneUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testAppLaunchesAsMenuBarAgent() {
        XCTAssertTrue(
            waitForAppToRun(timeout: 8),
            "FineTune should launch and remain running as a menu bar agent."
        )
    }

    func testMenuBarPopupControlsAreReachableInUITestHost() {
        XCTAssertTrue(
            waitForPopupRoot(timeout: 8),
            "The UI test host should expose the same content used by the menu bar popup."
        )

        XCTAssertTrue(
            popupHost.descendants(matching: .any)["devices.output.toggle"].exists,
            "The output-device tab should be present in the popup."
        )
        XCTAssertTrue(
            popupHost.descendants(matching: .any)["devices.input.toggle"].exists,
            "The input-device tab should be present in the popup."
        )
    }

    func testDeviceInspectorShowsSoftwareVolumeControl() throws {
        XCTAssertTrue(
            waitForPopupRoot(timeout: 8),
            "The UI test host should expose the device list."
        )

        let reorderButton = popupHost.descendants(matching: .any)["devices.reorder.toggle"]
        XCTAssertTrue(
            reorderButton.waitForExistence(timeout: 5),
            "The device priority editor should be reachable from the popup."
        )
        activateAppAndWaitForPopupHost()
        reorderButton.click()

        let expandDetailsButton = popupHost.buttons["Expand device details"].firstMatch
        guard expandDetailsButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("No output device detail row was exposed in this test environment.")
        }
        activateAppAndWaitForPopupHost()
        expandDetailsButton.click()

        let detailRoot = popupHost.descendants(matching: .any)["deviceDetail.root"]
        XCTAssertTrue(
            detailRoot.waitForExistence(timeout: 5),
            "Opening a device inspector should reveal the device detail panel."
        )

        XCTAssertTrue(
            popupHost.descendants(matching: .any)["deviceDetail.softwareControl"].exists,
            "The device detail panel should expose the software-volume control section."
        )
    }

    func testSettingsWindowExposesPrimaryTabsAndCustomCloseButton() {
        relaunchForSettingsUITestHost()

        let settingsRoot = app.descendants(matching: .any)["settings.root"]
        XCTAssertTrue(
            settingsRoot.waitForExistence(timeout: 8),
            "The custom Settings SwiftUI root should be exposed for UI regression tests."
        )

        XCTAssertTrue(app.descendants(matching: .any)["settings.sidebar.general"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.sidebar.audio"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.sidebar.shortcuts"].exists)

        let closeButton = app.descendants(matching: .any)["settings.close"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: 5),
            "The Settings window should expose the custom close button."
        )
        closeButton.click()
        XCTAssertFalse(
            settingsRoot.waitForExistence(timeout: 2),
            "The custom close button should dismiss the Settings host window."
        )
    }

    func testMenuBarPopupOpensFromSystemStatusItemWhenAccessible() throws {
        try openMenuBarPopup()

        XCTAssertTrue(
            waitForPopupRoot(timeout: 5),
            "FineTune should expose the menu bar popup after clicking its status item."
        )
    }

    private func waitForAppToRun(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .runningForeground || app.state == .runningBackground {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForPopupRoot(timeout: TimeInterval) -> Bool {
        let popup = popupHost.descendants(matching: .any)["menuBarPopup.root"]
        return popup.waitForExistence(timeout: timeout)
    }

    private var popupHost: XCUIElement {
        app.windows["FineTune UI Test Host"].firstMatch
    }

    private func activateAppAndWaitForPopupHost() {
        app.activate()
        _ = popupHost.waitForExistence(timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private func relaunchForSettingsUITestHost() {
        app.terminate()
        app.launchArguments = [
            "--ui-testing",
            "--ui-testing-settings",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        app.launch()
    }

    private func openMenuBarPopup(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            waitForAppToRun(timeout: 8),
            "FineTune should be running before opening the menu bar popup.",
            file: file,
            line: line
        )

        let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let statusItem = findFineTuneStatusItem(in: systemUIServer)

        guard statusItem.waitForExistence(timeout: 8) else {
            throw XCTSkip("FineTune status item was not exposed by SystemUIServer accessibility.")
        }

        statusItem.click()
    }

    private func findFineTuneStatusItem(in systemUIServer: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
            "FineTune",
            "FineTune"
        )

        let matchingMenuBarItem = systemUIServer
            .menuBars
            .menuBarItems
            .matching(predicate)
            .firstMatch

        if matchingMenuBarItem.exists {
            return matchingMenuBarItem
        }

        return systemUIServer.descendants(matching: .any).matching(predicate).firstMatch
    }
}
