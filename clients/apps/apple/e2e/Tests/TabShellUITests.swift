import XCTest
import UIKit

/// The tab shell over the fixture: the app opens on the router chat and keeps its page across the background, tabs
/// keep their state without reloading, the router chat opens over them and keeps its draft, Home's platform cards
/// settle on a card and carry a throw, Home leads into the Task dock, the archive and the router composer, search
/// opens from the tab bar ready to type, and another Task takes over a minimized dock.
@MainActor final class TabShellUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testMiniAppCardBodyPressAndIndependentGlassRun() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--card-polish", "--hide-metrics"]
                + (orientation == .portrait ? [] : ["--mini-app-landscape"]))
            let apps = app.buttons["tab-apps"]
            XCTAssertTrue(apps.waitForExistence(timeout: 15)); apps.tap()
            let card = app.buttons["mini-app-reading"]
            let run = app.buttons["mini-app-run-reading"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertEqual(app.frame.width > app.frame.height, orientation != .portrait)
            if orientation != .portrait { app.scrollViews.firstMatch.swipeUp() }
            miniAppScreenshot(app, "Card normal " + orientationName(orientation))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { PerfSignal.captureMiniApp.post() }
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75))
                .press(forDuration: 1.5, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)))
            XCTAssertTrue(run.isHittable, "Dragging out cancels the card's action")
            if orientation != .portrait { app.scrollViews.firstMatch.swipeUp() }
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.86)).tap()
            let detailRun = app.buttons["mini-app-detail-run"]
            XCTAssertTrue(detailRun.waitForExistence(timeout: 10), "The description area opens app details")
            miniAppScreenshot(app, "Details from card body " + orientationName(orientation))
            let back = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Apps")).firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
            back.tap()
            XCTAssertTrue(run.waitForExistence(timeout: 5))
            run.tap()
            let consent = app.alerts["Run this app?"]
            XCTAssertTrue(consent.waitForExistence(timeout: 10), "Run opens the runtime directly")
            consent.buttons["Cancel"].tap()
            XCTAssertTrue(run.waitForExistence(timeout: 5), "Run must not also navigate to details")
            miniAppScreenshot(app, "Card after run cancelled " + orientationName(orientation))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testAppStoreStyleMiniAppDetailsKeepRunAndManagement() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--app-detail", "--hide-metrics"]
                + (orientation == .portrait ? [] : ["--mini-app-landscape"]))
            XCTAssertTrue(app.buttons["tab-apps"].waitForExistence(timeout: 15)); app.buttons["tab-apps"].tap()
            let card = app.buttons["mini-app-reading"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            miniAppScreenshot(app, "Apps with version artwork " + orientationName(orientation))
            card.tap()
            let mainRun = app.buttons["mini-app-detail-primary-run"]
            XCTAssertTrue(mainRun.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.frame.contains(mainRun.frame))
            let appsTab = app.buttons["tab-apps"].frame
            if appsTab.minX > app.frame.midX, appsTab.minY < app.frame.maxY - 100 {
                XCTAssertLessThan(mainRun.frame.maxX, appsTab.minX, "Detail actions stay clear of the Duo system rail")
            }
            XCTAssertTrue(app.staticTexts["Preview"].exists, "API screenshot metadata reaches the native details page")
            miniAppScreenshot(app, "App detail hero " + orientationName(orientation))
            let scroll = app.scrollViews.firstMatch
            let more = app.buttons["mini-app-detail-description-toggle"]
            for _ in 0 ..< 5 where !more.isHittable { scroll.swipeUp() }
            XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
            miniAppScreenshot(app, "App detail preview and description " + orientationName(orientation))
            more.tap(); XCTAssertEqual(more.label, "Less")
            miniAppScreenshot(app, "App detail expanded description " + orientationName(orientation))
            // On iOS 27, isHittable may stay true after expansion moves a SwiftUI
            // button below the viewport. Bring its actual frame onscreen first.
            let readingArea = app.frame.insetBy(dx: 0, dy: 80)
            for _ in 0 ..< 5 where !readingArea.contains(more.frame) { scroll.swipeUp() }
            XCTAssertTrue(readingArea.contains(more.frame), app.debugDescription)
            more.tap(); XCTAssertEqual(more.label, "More")
            let group = app.buttons["mini-app-detail-management"]
            for _ in 0 ..< 4 where !group.isHittable { scroll.swipeUp() }
            XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription); group.tap()
            XCTAssertTrue(app.buttons["Preview version"].waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0 ..< 4 where !app.buttons["Disable app"].isHittable { scroll.swipeUp() }
            XCTAssertTrue(app.buttons["Disable app"].waitForExistence(timeout: 5), app.debugDescription)
            miniAppScreenshot(app, "App detail version management " + orientationName(orientation))
            let run = app.buttons["mini-app-detail-run"]
            XCTAssertTrue(run.isHittable, "Run remains available while reading the lower page")
            run.tap()
            XCTAssertTrue(app.alerts["Run this app?"].waitForExistence(timeout: 10))
            app.alerts["Run this app?"].buttons["Cancel"].tap()
            XCTAssertTrue(run.waitForExistence(timeout: 5))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testMiniAppPhotoPickerRequiresDeliveryConfirmation() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--photo-picker", "--hide-metrics"]
                + (orientation == .portrait ? [] : ["--mini-app-landscape"]))
            XCTAssertTrue(app.buttons["tab-apps"].waitForExistence(timeout: 15)); app.buttons["tab-apps"].tap()
            app.buttons["mini-app-run-reading"].tap()
            let consent = app.alerts["Run this app?"]
            XCTAssertTrue(consent.waitForExistence(timeout: 10)); consent.buttons["Run"].tap()
            let web = app.webViews.firstMatch
            let choose = web.buttons["Choose app photos"]
            XCTAssertTrue(choose.waitForExistence(timeout: 15)); choose.tap()
            let library = app.buttons["mini-app-photo-library"]
            XCTAssertTrue(library.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Send to Reading tracker"].exists)
            XCTAssertFalse(app.buttons["mini-app-photo-camera"].exists, "The Simulator must not pretend to have a camera")
            miniAppScreenshot(app, "Photo request recipient " + orientationName(orientation))
            XCTAssertFalse(app.buttons["mini-app-photo-share"].exists)
            library.tap()
            let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
            miniAppScreenshot(app, "System photo picker " + orientationName(orientation))
            let system = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            system.name = "System photo library " + orientationName(orientation); system.lifetime = .keepAlways; add(system)
            photo.tap()
            let share = app.buttons["mini-app-photo-share"]
            XCTAssertTrue(share.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertFalse(web.staticTexts["Shared photo: image/png, buffer=true"].exists)
            XCTAssertTrue(app.frame.contains(share.frame), "Delivery controls remain inside the screen")
            miniAppScreenshot(app, "Photo preview before delivery " + orientationName(orientation))
            share.tap()
            XCTAssertTrue(web.staticTexts["Shared photo: image/png, buffer=true"].waitForExistence(timeout: 10), app.debugDescription)
            miniAppScreenshot(app, "Photo delivered to SDK " + orientationName(orientation))
            choose.tap(); XCTAssertTrue(library.waitForExistence(timeout: 5))
            XCTAssertFalse(share.exists, "A new request must not reuse the previous photos")
            app.navigationBars["Share photos"].buttons["Cancel"].tap()
            XCTAssertTrue(web.staticTexts["Photo request cancelled"].waitForExistence(timeout: 5))
            miniAppScreenshot(app, "Photo request cancelled " + orientationName(orientation))
            choose.tap(); XCTAssertTrue(library.waitForExistence(timeout: 5))
            XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended,
                "The app must actually enter the OS background, state=\(app.state.rawValue)")
            app.activate()
            let cancelled = web.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "Photo request cancelled", "Photo request: unavailable")).firstMatch
            XCTAssertTrue(cancelled.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(library.waitUntilGone(), "A photo request cannot survive backgrounding")
            miniAppScreenshot(app, "Background cancelled pending delivery " + orientationName(orientation))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testMiniAppImmersiveModeAdaptsAndKeepsTheDocument() throws {
        let expectsSide = UIDevice.current.name.contains("Duo")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--chrome-mode", "--hide-metrics"]
                + (orientation == .portrait ? [] : ["--mini-app-landscape"]))
            XCTAssertTrue(app.buttons["tab-apps"].waitForExistence(timeout: 15))
            app.buttons["tab-apps"].tap()
            let run = app.buttons["mini-app-run-reading"]
            XCTAssertTrue(run.waitForExistence(timeout: 10)); run.tap()
            let consent = app.alerts["Run this app?"]
            XCTAssertTrue(consent.waitForExistence(timeout: 10)); consent.buttons["Run"].tap()
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.staticTexts["Reading app ready"].waitForExistence(timeout: 15))
            let menu = app.buttons["mini-app-menu"]
            let header = app.otherElements["mini-app-header"]
            XCTAssertFalse(header.exists, "New executions start in immersive mode")
            XCTAssertFalse(app.statusBars.firstMatch.exists)
            miniAppScreenshot(app, "Default immersive " + orientationName(orientation))
            menu.tap()
            let toggle = app.buttons["mini-app-immersive"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
            miniAppScreenshot(app, "Immersive mode menu " + orientationName(orientation))
            toggle.tap()
            miniAppScreenshot(app, "Mode switched " + orientationName(orientation))
            XCTAssertTrue(menu.waitUntilHittable(timeout: 5))
            // Duo's system rail is on the right; ordinary iPhones keep controls in the header.
            if expectsSide {
                XCTAssertFalse(header.exists)
                XCTAssertGreaterThan(menu.frame.midX, app.frame.maxX - 90)
                XCTAssertGreaterThan(abs(menu.frame.midY - app.buttons["mini-app-back"].frame.midY), 30)
                XCTAssertLessThan(web.frame.maxX, menu.frame.midX)
            } else {
                XCTAssertTrue(header.waitForExistence(timeout: 5))
                XCTAssertLessThan(menu.frame.maxY, web.frame.minY + 1)
            }
            XCTAssertTrue(app.frame.insetBy(dx: 12, dy: 12).contains(menu.frame), "The controls avoid rounded corners")
            XCTAssertEqual(web.frame.maxY, app.frame.maxY, accuracy: 1, "Nonimmersive content extends through the bottom safe area")
            miniAppScreenshot(app, "Nonimmersive native chrome " + orientationName(orientation))
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "System chrome " + orientationName(orientation); screen.lifetime = .keepAlways
            add(screen)
            let input = web.textFields["Reading notes"]
            input.tap(); input.typeText("Keep my mode and note")
            app.buttons["mini-app-back"].tap()
            XCTAssertTrue(run.waitForExistence(timeout: 10)); XCTAssertTrue(run.label.hasPrefix("Continue"))
            run.tap()
            XCTAssertTrue(input.waitUntilHittable(timeout: 10))
            XCTAssertEqual(input.value as? String, "Keep my mode and note")
            if expectsSide { XCTAssertGreaterThan(menu.frame.midX, app.frame.maxX - 90) }
            else { XCTAssertTrue(header.exists, "Continue keeps the execution's mode") }
            miniAppScreenshot(app, "Continued nonimmersive app " + orientationName(orientation))
            menu.tap(); XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
            XCTAssertFalse(header.exists)
            XCTAssertEqual(input.value as? String, "Keep my mode and note", "Switching mode preserves the same document")
            XCTAssertLessThan(menu.frame.maxX, app.frame.midX)
            miniAppScreenshot(app, "Immersive restored " + orientationName(orientation))
            menu.tap(); app.buttons["mini-app-close"].tap()
            XCTAssertTrue(run.waitForExistence(timeout: 10))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testMiniAppImmersiveChromeAndKeyboard() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--hide-metrics"]
                + (orientation == .portrait ? [] : ["--mini-app-landscape"]))
            let apps = app.buttons["tab-apps"]
            XCTAssertTrue(apps.waitForExistence(timeout: 15)); apps.tap()
            XCTAssertEqual(app.frame.width > app.frame.height, orientation != .portrait)
            let run = app.buttons["mini-app-run-reading"]
            XCTAssertTrue(run.waitForExistence(timeout: 10))
            let statusBefore = app.statusBars.firstMatch.exists
            run.tap()
            let consent = app.alerts["Run this app?"]
            XCTAssertTrue(consent.waitForExistence(timeout: 10))
            miniAppScreenshot(app, "Cloud consent " + orientationName(orientation))
            consent.buttons["Run"].tap()
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.staticTexts["Reading app ready"].waitForExistence(timeout: 15))
            let back = app.buttons["mini-app-back"]
            XCTAssertTrue(back.isHittable)
            let menu = app.buttons["mini-app-menu"]
            for control in [menu, back] {
                XCTAssertTrue(app.frame.insetBy(dx: 24, dy: 24).contains(control.frame))
            }
            miniAppScreenshot(app, "Glass runtime " + orientationName(orientation))
            menu.tap()
            let reload = app.buttons["mini-app-reload"]
            XCTAssertTrue(reload.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["mini-app-close"].isHittable)
            miniAppScreenshot(app, "Native app menu " + orientationName(orientation))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
            XCTAssertTrue(reload.waitUntilGone())
            let input = web.textFields["Reading notes"]
            input.tap(); input.typeText("Keep this note")
            input.raiseKeyboard()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(back.isHittable)
            miniAppScreenshot(app, "Runtime keyboard " + orientationName(orientation))
            back.tap()
            XCTAssertTrue(run.waitForExistence(timeout: 10))
            XCTAssertTrue(run.label.hasPrefix("Continue"))
            XCTAssertEqual(app.statusBars.firstMatch.exists, statusBefore)
            miniAppScreenshot(app, "Apps continue " + orientationName(orientation))
            run.tap()
            XCTAssertTrue(input.waitUntilHittable(timeout: 10))
            XCTAssertEqual(input.value as? String, "Keep this note", "Continue reattaches the same document")
            miniAppScreenshot(app, "Continued app " + orientationName(orientation))
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(input.waitUntilHittable(timeout: 10))
            XCTAssertEqual(input.value as? String, "Keep this note", "OS backgrounding preserves the foreground document")
            miniAppScreenshot(app, "App after OS background " + orientationName(orientation))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
            XCTAssertTrue(run.waitForExistence(timeout: 10), "A native left-edge gesture returns without closing")
            XCTAssertTrue(run.label.hasPrefix("Continue"))
            miniAppScreenshot(app, "Apps after back swipe " + orientationName(orientation))
            run.tap()
            XCTAssertTrue(input.waitUntilHittable(timeout: 10))
            XCTAssertEqual(input.value as? String, "Keep this note")
            menu.tap()
            XCTAssertTrue(app.buttons["mini-app-close"].waitForExistence(timeout: 5))
            app.buttons["mini-app-close"].tap()
            XCTAssertTrue(run.waitForExistence(timeout: 10))
            XCTAssertTrue(run.label.hasPrefix("Run"), "Complete close retires the execution")
            XCTAssertTrue(app.buttons["openRouterChat"].isHittable)
            miniAppScreenshot(app, "Apps after complete close " + orientationName(orientation))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Apps without apps reads as the Inbox does: the same inline page title and the app's one empty state,
    /// with no search field over nothing to search.
    func testEmptyAppsUsesThePageTitleAndEmptyState() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--mini-app-empty", "--hide-metrics"])
        let inbox = app.buttons["tab-inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 15)); inbox.tap()
        XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 10))
        let inboxBar = app.navigationBars.firstMatch.frame
        app.buttons["tab-apps"].tap()
        let empty = app.element("miniAppsEmpty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No apps yet"].exists)
        XCTAssertFalse(app.element("miniAppSearch").exists, "Search waits for apps to search")
        XCTAssertEqual(app.navigationBars.firstMatch.frame.height, inboxBar.height, accuracy: 1,
                       "Apps uses the inline page title, as the Inbox does")
        app.buttons["tab-inbox"].tap()
        XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 10))
        app.buttons["tab-apps"].tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        miniAppScreenshot(app, "Apps empty")
    }

    private func orientationName(_ orientation: UIDeviceOrientation) -> String {
        orientation == .portrait ? "portrait" : "landscape"
    }

    private func miniAppScreenshot(_ app: XCUIApplication, _ name: String) {
        PerfSignal.captureMiniApp.post()
        Thread.sleep(forTimeInterval: 0.3)
        keepScreenshot(app, name)
    }

    func testTabsKeepTheirStateWithoutReloading() throws {
        let app = XCUIApplication.fixture()
        XCTAssertTrue(app.element("task-review0").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Needs review"].isSelected, "Home opens on Needs review")
        app.buttons["In progress"].tap()
        XCTAssertTrue(app.element("task-task0").waitForExistence(timeout: 5))
        let loads = app.staticTexts["listLoads"].label
        let inbox = app.buttons["tab-inbox"]
        XCTAssertEqual(inbox.value as? String, "Unread", "Tasks waiting for review mark the Inbox")
        inbox.tap()
        XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 5))
        XCTAssertTrue(inbox.isSelected)
        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["tab-home"].tap()
        XCTAssertTrue(app.element("task-task0").waitUntilHittable())
        XCTAssertTrue(app.buttons["In progress"].isSelected, "Home keeps its status across tabs")
        XCTAssertEqual(app.staticTexts["listLoads"].label, loads, "Switching tabs must not reload the list")
    }

    func testRouterChatOpensOverTheTabsAndKeepsItsDraft() throws {
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        XCTAssertFalse(app.buttons["tab-home"].isHittable, "The router chat covers the tabs")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Router draft")
        app.buttons["closeRouterChat"].tap()
        XCTAssertTrue(composer.waitUntilGone(), "Closing folds the chat back into its button")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.openRouterChat().value as? String, "Router draft")
        // A downward drag on the header closes it too.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        XCTAssertTrue(composer.waitUntilGone(), "A header drag closes the router chat")
        XCTAssertTrue(app.buttons["tab-home"].waitUntilHittable())
        // So does a drag toward the trailing edge from the chat's leading third, like going back; on a message the
        // same drag replies to it instead (ReplyThreadUITests). One let go short and slow springs back open, and one
        // from further in (here across the header, where there is no message) leaves the chat open.
        XCTAssertEqual(app.openRouterChat().value as? String, "Router draft")
        app.at(0.03, 0.5).press(forDuration: 0.05, thenDragTo: app.at(0.18, 0.5), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(composer.waitUntilHittable(), "A short sideways drag springs the chat back open")
        XCTAssertFalse(app.buttons["tab-home"].isHittable)
        app.at(0.5, 0.08).press(forDuration: 0.05, thenDragTo: app.at(0.95, 0.09))
        XCTAssertFalse(composer.waitUntilGone(timeout: 1.5), "A sideways drag from mid-screen leaves the chat open")
        XCTAssertFalse(app.buttons["tab-home"].isHittable)
        app.at(0.03, 0.5).press(forDuration: 0.05, thenDragTo: app.at(0.9, 0.55))
        XCTAssertTrue(composer.waitUntilGone(), "A sideways drag closes the router chat")
        XCTAssertTrue(app.buttons["tab-home"].waitUntilHittable())
    }

    func testOpensOnTheChatAndKeepsThePageInTheBackground() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat"])
        // A fresh launch opens on the chat, already in place.
        let composer = app.routerComposer
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.waitUntilHittable(), "The app opens on the chat")
        XCTAssertFalse(app.buttons["tab-home"].isHittable, "The chat covers the tabs")
        // Back from the background, the chat is still open.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(composer.waitUntilHittable(), "Coming back keeps the chat open")
        // And a tab the member moved to stays selected, with the chat still closed.
        app.buttons["closeRouterChat"].tap()
        XCTAssertTrue(composer.waitUntilGone())
        let inbox = app.buttons["tab-inbox"]
        XCTAssertTrue(inbox.waitUntilHittable())
        inbox.tap()
        XCTAssertTrue(inbox.isSelected)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(inbox.waitUntilHittable(), "Coming back keeps the page")
        XCTAssertTrue(inbox.isSelected, "Coming back keeps the selected tab")
        XCTAssertFalse(composer.exists, "Coming back does not reopen the chat")
    }

    func testSearchOpensFromTheTabBarAndKeepsTheTab() throws {
        let app = XCUIApplication.fixture()
        let inbox = app.buttons["tab-inbox"]
        XCTAssertTrue(inbox.waitUntilHittable(timeout: 10))
        inbox.tap()
        // Search's button beside Inbox opens the system's search field, focused with the keyboard up.
        app.buttons["openTaskSearch"].tap()
        let field = app.searchFields["Search tasks"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search opens with the keyboard up")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
        XCTAssertFalse(inbox.isHittable, "Search covers the tabs")
        field.typeText("launch")
        // The field's close button (the search bar's Cancel before iOS 26) closes search on the tab it opened over.
        let closeSearch = if #available(iOS 26.0, *) { app.buttons["close"] } else { app.buttons["Cancel"] }
        closeSearch.tap()
        XCTAssertTrue(field.waitUntilGone(), "Closing search puts the field away")
        XCTAssertTrue(inbox.waitUntilHittable(), "Closing search returns to the tabs")
        XCTAssertTrue(inbox.isSelected, "Search leaves the selected tab as it was")
    }

    func testPlatformCardsSettleOnACardAndCarryAThrow() throws {
        let app = XCUIApplication.fixture()
        let slack = app.buttons["platform-conn-slack"], linear = app.buttons["platform-conn-linear"]
        let last = app.buttons["platform-conn-github"]
        XCTAssertTrue(linear.waitForExistence(timeout: 10))
        let margin = slack.frame.minX - app.frame.minX
        let row = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 0, dy: linear.frame.midY))
        func settled(_ card: XCUIElement, leading: Bool, _ message: String) {
            Thread.sleep(forTimeInterval: 1.2)
            let edge = leading ? card.frame.minX - app.frame.minX : app.frame.maxX - card.frame.maxX
            XCTAssertEqual(edge, margin, accuracy: 2, message)
        }
        // Let go still past half a card, and the row settles on the next card rather than between two.
        row.withOffset(CGVector(dx: 300, dy: 0)).press(forDuration: 0.05, thenDragTo: row.withOffset(CGVector(dx: 200, dy: 0)),
                                                       withVelocity: .slow, thenHoldForDuration: 0.3)
        settled(linear, leading: true, "A drag let go still settles on the nearest card")
        row.withOffset(CGVector(dx: 40, dy: 0)).press(forDuration: 0.02, thenDragTo: row.withOffset(CGVector(dx: 360, dy: 0)),
                                                      withVelocity: XCUIGestureVelocity(3000), thenHoldForDuration: 0)
        settled(slack, leading: true, "A throw back returns to the first card")
        // A hard throw carries the row as far as its speed takes it, here to the end, not one card at a time.
        row.withOffset(CGVector(dx: 320, dy: 0)).press(forDuration: 0.02, thenDragTo: row.withOffset(CGVector(dx: 200, dy: 0)),
                                                       withVelocity: XCUIGestureVelocity(3000), thenHoldForDuration: 0)
        settled(last, leading: false, "A hard throw carries the row to its end")
    }

    func testHomeOpensTasksTheArchiveAndPreTasks() throws {
        let app = XCUIApplication.fixture()
        let review = app.element("task-review0")
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitUntilGone())
        // The archive reads past an empty first page.
        app.element("openArchivedTasks").tap()
        XCTAssertTrue(app.element("task-arch0").waitForExistence(timeout: 5))
        app.element("closeArchivedTasks").tap()
        XCTAssertTrue(app.element("task-arch0").waitUntilGone())
        // A pre-task goes into the router composer and waits there for the member to send it.
        let slack = app.element("platform-conn-slack")
        XCTAssertTrue(slack.waitForExistence(timeout: 5))
        XCTAssertEqual(slack.label, "Slack, 3 suggested tasks")
        XCTAssertEqual(app.element("platform-conn-github").label, "GitHub, acme, nothing new")
        slack.tap()
        // A member task's card shows the source words it quotes, and its minus stops suggesting the source item.
        let task = app.element("pretask-item-0")
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        XCTAssertTrue(task.label.contains("the rerun is green"), "The card shows its quote: \(task.label)")
        XCTAssertTrue(app.element("pretask-dismiss-item-0").exists)
        let item = app.element("pretask-item-1")
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let composer = app.routerComposer
        let filled = NSPredicate(format: "value CONTAINS %@", "Summarize the #launch thread")
        wait(for: [expectation(for: filled, evaluatedWith: composer)], timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The composer takes focus")
    }

    /// A minimized Task keeps the status switcher over its bar, and another Task opened then takes over the dock,
    /// raised, with its own title.
    func testAnotherTaskTakesOverAMinimizedDock() throws {
        let app = XCUIApplication.fixture()
        let first = app.element("task-review0")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitUntilHittable())
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        XCTAssertTrue(app.buttons["Done"].waitUntilHittable(), "The status switcher shows over the minimized Task")
        let second = app.element("task-review1")
        XCTAssertTrue(second.waitUntilHittable())
        second.tap()
        let title = app.buttons.matching(NSPredicate(format: "label == %@", "Draft the Q4 planning notes")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The dock shows the Task opened last")
        XCTAssertTrue(app.buttons["Done"].waitUntilUnhittable(), "The raised sheet covers the switcher")
        close.tap()
        XCTAssertTrue(close.waitUntilGone())
    }
}
