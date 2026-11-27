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
            openApps(app)
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
            openApps(app)
            let card = app.buttons["mini-app-reading"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            miniAppScreenshot(app, "Apps with version artwork " + orientationName(orientation))
            card.tap()
            let mainRun = app.buttons["mini-app-detail-primary-run"]
            XCTAssertTrue(mainRun.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.frame.contains(mainRun.frame))
            let rail = app.buttons["tab-home"].frame
            if rail.minX > app.frame.midX, rail.minY < app.frame.maxY - 100 {
                XCTAssertLessThan(mainRun.frame.maxX, rail.minX, "Detail actions stay clear of the Duo system rail")
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
            openApps(app)
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
            openApps(app)
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
            openApps(app)
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

    /// An applied filter shows its count beside the Inbox's filter glyph and the button keeps its place, also in Duo's
    /// vertical bar, where the count once let the system stretch the button's Glass over the page.
    func testInboxFilterButtonStaysInPlaceWithAFilterApplied() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--hide-metrics"]
                + (orientation == .portrait ? [] : ["--mini-app-landscape"]))
            let inbox = app.buttons["tab-inbox"]
            XCTAssertTrue(inbox.waitForExistence(timeout: 15)); inbox.tap()
            XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 10))
            let filters = app.buttons["openInboxFilters"]
            XCTAssertTrue(filters.waitUntilHittable())
            let plain = filters.frame
            screenScreenshot("Inbox no filter " + orientationName(orientation))
            filters.tap()
            let unread = app.buttons["inboxUnreadOnly"]
            XCTAssertTrue(unread.waitForExistence(timeout: 5), app.debugDescription); unread.tap()
            // The sheet closes when pulled down from its top row.
            unread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)))
            XCTAssertTrue(unread.waitUntilGone(), app.debugDescription)
            XCTAssertTrue(filters.waitUntilHittable())
            Thread.sleep(forTimeInterval: 0.5)
            screenScreenshot("Inbox unread only " + orientationName(orientation))
            XCTAssertEqual(filters.value as? String, "1 applied")
            // The count widens the button by a digit and leaves it in its bar.
            let applied = filters.frame
            XCTAssertEqual(applied.height, plain.height, accuracy: 1, "\(plain) -> \(applied)")
            XCTAssertLessThan(applied.width, plain.width + 30, "\(plain) -> \(applied)")
            XCTAssertLessThan(abs(applied.midY - plain.midY), 30, "\(plain) -> \(applied)")
            XCTAssertLessThan(abs(applied.midX - plain.midX), 30, "\(plain) -> \(applied)")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// The whole screen: Duo's compositor crops an app's own landscape screenshot.
    private func screenScreenshot(_ name: String) {
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name; screen.lifetime = .keepAlways
        add(screen)
    }

    /// Apps without apps reads as the Inbox does: the same inline page title and the app's one empty state,
    /// with no search field over nothing to search.
    func testEmptyAppsUsesThePageTitleAndEmptyState() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--mini-app-empty", "--hide-metrics"])
        let inbox = app.buttons["tab-inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 15)); inbox.tap()
        XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 10))
        let inboxBar = app.navigationBars.firstMatch.frame
        openApps(app)
        let empty = app.element("miniAppsEmpty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No apps yet"].exists)
        XCTAssertFalse(app.element("miniAppSearch").exists, "Search waits for apps to search")
        XCTAssertEqual(app.navigationBars.firstMatch.frame.height, inboxBar.height, accuracy: 1,
                       "Apps uses the inline page title, as the Inbox does")
        app.buttons["tab-inbox"].tap()
        XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 10))
        if #available(iOS 26.0, *) {
            app.openTab("tab-apps")
            XCTAssertTrue(empty.waitForExistence(timeout: 10), "The menu leads back to Apps")
        } else {
            app.buttons["tab-settings"].tap()
            XCTAssertTrue(empty.waitForExistence(timeout: 10), "Settings keeps Apps open")
        }
        miniAppScreenshot(app, "Apps empty")
    }

    /// New app, as on the desktop, leaves the start of a request in the router chat's composer with the keyboard up
    /// for the member to finish; nothing is sent.
    func testNewAppStartsARequestInTheRouterComposer() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--mini-app", "--mini-app-empty", "--hide-metrics"])
        openApps(app)
        let newApp = app.buttons["miniAppsNew"]
        XCTAssertTrue(newApp.waitUntilHittable(), "New app takes a tap over the empty state")
        newApp.tap()
        let composer = app.routerComposer
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let filled = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "Build a Comma app that"), evaluatedWith: composer)
        wait(for: [filled], timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard comes up to finish the request")
        miniAppScreenshot(app, "New app in the router composer")
    }

    /// Apps is a page in the bar's menu; before iOS 26 it is Settings › Comma › Apps.
    private func openApps(_ app: XCUIApplication) {
        if #available(iOS 26.0, *) { app.openTab("tab-apps"); return }
        app.openTab("tab-settings")
        let apps = app.buttons["openApps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 10)); apps.tap()
    }

    private func orientationName(_ orientation: UIDeviceOrientation) -> String {
        orientation == .portrait ? "portrait" : "landscape"
    }

    private func miniAppScreenshot(_ app: XCUIApplication, _ name: String) {
        PerfSignal.captureMiniApp.post()
        Thread.sleep(forTimeInterval: 0.3)
        keepScreenshot(app, name)
    }

    /// The tab a dragged lens leaves stays drawn. Its glyph is cut to the lifted lens while it is selected, and once
    /// kept that cut after the selection moved on, so the glyph was gone.
    func testATabTheLensLeavesKeepsItsGlyph() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The system's bar draws its own glyphs before iOS 26") }
        let app = XCUIApplication.fixture(light: true)
        let home = app.buttons["tab-home"], people = app.buttons["tab-people"]
        XCTAssertTrue(home.waitUntilHittable(timeout: 15))
        let centre = CGVector(dx: 0.5, dy: 0.5)
        home.coordinate(withNormalizedOffset: centre)
            .press(forDuration: 0.4, thenDragTo: people.coordinate(withNormalizedOffset: centre))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: people)], timeout: 5)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(try darkPixels(home.screenshot()), 150, "Home's glyph is drawn in its slot")
    }

    /// Tapping an unselected tab switches cleanly, tapping More opens the overflow menu, and dragging the lifted lens
    /// onto More and up into a row selects that overflow page in one continuous gesture.
    func testTabBarTapSwitchAndDragIntoOverflowMenu() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The overflow glass menu requires iOS 26") }
        let app = XCUIApplication.fixture(light: true)
        let home = app.buttons["tab-home"], inbox = app.buttons["tab-inbox"], people = app.buttons["tab-people"]
        let more = app.buttons["tab-more"]
        XCTAssertTrue(home.waitUntilHittable(timeout: 15))

        people.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: people)], timeout: 5)
        inbox.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: inbox)], timeout: 5)
        home.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: home)], timeout: 5)

        // Tap More -> pick Settings from overflow menu -> verify Settings opens and More is selected.
        more.tap()
        let settingsRow = app.buttons["tab-settings"]
        XCTAssertTrue(settingsRow.waitUntilHittable(timeout: 5))
        settingsRow.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(more.isSelected)

        // Return to Inbox, then drag the lifted lens from Inbox onto More and dwell so the overflow menu opens
        // mid-drag while the finger is still down (cancelling native bar tracking with no stuck lens or peeking platter).
        inbox.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: inbox)], timeout: 5)
        let centre = CGVector(dx: 0.5, dy: 0.5)
        inbox.coordinate(withNormalizedOffset: centre)
            .press(forDuration: 0.15, thenDragTo: more.coordinate(withNormalizedOffset: centre),
                   withVelocity: .default, thenHoldForDuration: 0.8)
        let driveRow = app.buttons["tab-drive"]
        XCTAssertTrue(driveRow.waitUntilHittable(timeout: 5), "Dwelling on More during a drag must open the overflow menu")
        driveRow.tap()
        XCTAssertTrue(more.waitUntilHittable(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: more)], timeout: 5)

        // Return to Home, then verify glyphs on Home, Inbox, and People all remain drawn after tap & drag switching.
        home.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: home)], timeout: 5)
        Thread.sleep(forTimeInterval: 0.6)
        for slot in [home, inbox, people] {
            XCTAssertGreaterThan(try darkPixels(slot.screenshot()), 120, "\(slot.identifier) glyph must remain drawn")
        }
    }

    /// Verifies tap-open AND mid-drag dwell-open of the overflow menu in landscape (compact 44pt bar on iPhone,
    /// vertical side rail on Duo) as well as Dark Mode, confirming `tab-more` accessibility and clean handoff.
    func testTabBarOverflowMenuInLandscapeAndDarkMode() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The overflow glass menu requires iOS 26") }
        defer { XCUIDevice.shared.orientation = .portrait }

        // 1. Landscape (Light): compact 44pt bar on iPhone / vertical rail on Duo.
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeApp = XCUIApplication.fixture(light: true)
        let lHome = landscapeApp.buttons["tab-home"]
        let lInbox = landscapeApp.buttons["tab-inbox"]
        let lMore = landscapeApp.buttons["tab-more"]
        XCTAssertTrue(lHome.waitUntilHittable(timeout: 15))
        XCTAssertTrue(landscapeApp.frame.width > landscapeApp.frame.height)

        lInbox.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: lInbox)], timeout: 5)
        lMore.tap()
        let lSettings = landscapeApp.buttons["tab-settings"]
        XCTAssertTrue(lSettings.waitUntilHittable(timeout: 5))
        lSettings.tap()
        XCTAssertTrue(lMore.waitUntilHittable(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: lMore)], timeout: 5)

        lInbox.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: lInbox)], timeout: 5)
        let centre = CGVector(dx: 0.5, dy: 0.5)
        lInbox.coordinate(withNormalizedOffset: centre)
            .press(forDuration: 0.15, thenDragTo: lMore.coordinate(withNormalizedOffset: centre),
                   withVelocity: .default, thenHoldForDuration: 0.8)
        let lDrive = landscapeApp.buttons["tab-drive"]
        XCTAssertTrue(lDrive.waitUntilHittable(timeout: 5), "Landscape drag-dwell onto More must open overflow menu")
        lDrive.tap()
        XCTAssertTrue(lMore.waitUntilHittable(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: lMore)], timeout: 5)
        lHome.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: lHome)], timeout: 5)

        // 2. Portrait (Dark Mode): verify zero AX loss on `tab-more` and clean drag-dwell handoff.
        XCUIDevice.shared.orientation = .portrait
        let darkApp = XCUIApplication.fixture(light: false, arguments: ["-AppleInterfaceStyle", "Dark"])
        let dHome = darkApp.buttons["tab-home"]
        let dInbox = darkApp.buttons["tab-inbox"]
        let dMore = darkApp.buttons["tab-more"]
        XCTAssertTrue(dHome.waitUntilHittable(timeout: 15))

        dMore.tap()
        let dSettings = darkApp.buttons["tab-settings"]
        XCTAssertTrue(dSettings.waitUntilHittable(timeout: 5))
        dSettings.tap()
        XCTAssertTrue(darkApp.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(dMore.isSelected)

        dInbox.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: dInbox)], timeout: 5)
        dInbox.coordinate(withNormalizedOffset: centre)
            .press(forDuration: 0.15, thenDragTo: dMore.coordinate(withNormalizedOffset: centre),
                   withVelocity: .default, thenHoldForDuration: 0.8)
        let dDrive = darkApp.buttons["tab-drive"]
        XCTAssertTrue(dDrive.waitUntilHittable(timeout: 5), "Dark mode drag-dwell onto More must open overflow menu")
        dDrive.tap()
        XCTAssertTrue(dMore.waitUntilHittable(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: dMore)], timeout: 5)
        dHome.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: dHome)], timeout: 5)
    }

    /// Regression test: dragging onto `More` and opening the overflow menu via dwell, immediate lift (`case .ended`),
    /// or edge-slop lift (`shouldSelectTab`), then dismissing without picking must never leave the selected tab icon
    /// stuck at UIKit's `1.16×` lifted-lens magnification (and subsequent native drags must continue working cleanly).
    func testRepeatedDragIntoOverflowMenuAndDismissKeepsSelectedIconSize() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The overflow glass menu requires iOS 26") }
        let app = XCUIApplication.fixture(light: true)
        let home = app.buttons["tab-home"]
        let inbox = app.buttons["tab-inbox"]
        let more = app.buttons["tab-more"]
        XCTAssertTrue(home.waitUntilHittable(timeout: 15))
        Thread.sleep(forTimeInterval: 0.4)
        let base = try darkPixelExtent(home.screenshot())
        XCTAssertGreaterThan(base.width, 20, "Baseline Home glyph visible: \(base)")
        XCTAssertGreaterThan(base.height, 20, "Baseline Home glyph visible: \(base)")

        let c = CGVector(dx: 0.5, dy: 0.5)
        let dismiss = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))

        func assertRestingSize(_ label: String) throws {
            let after = try darkPixelExtent(home.screenshot())
            XCTAssertLessThanOrEqual(abs(after.width - base.width), 3,
                                     "\(label): Home icon width must stay at 1.0× resting size (base=\(base), after=\(after))")
            XCTAssertLessThanOrEqual(abs(after.height - base.height), 3,
                                     "\(label): Home icon height must stay at 1.0× resting size (base=\(base), after=\(after))")
        }

        // Trigger 1: Drag Home -> More and dwell (armMenuDwell) -> dismiss without picking.
        home.coordinate(withNormalizedOffset: c)
            .press(forDuration: 0.2, thenDragTo: more.coordinate(withNormalizedOffset: c), withVelocity: .default, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.buttons["tab-settings"].waitUntilHittable(timeout: 5), "Dwell on More opens menu")
        dismiss.tap()
        XCTAssertTrue(home.waitUntilHittable(timeout: 5))
        Thread.sleep(forTimeInterval: 0.7)
        try assertRestingSize("Trigger 1 (dwell)")

        // Trigger 2: Drag Home -> More and lift immediately (previously stranded SelectedContentView/_UITabButton at 1.16×!).
        for round in 1...2 {
            home.coordinate(withNormalizedOffset: c)
                .press(forDuration: 0.15, thenDragTo: more.coordinate(withNormalizedOffset: c), withVelocity: .default, thenHoldForDuration: 0.0)
            XCTAssertTrue(app.buttons["tab-settings"].waitUntilHittable(timeout: 5), "Lift on More round \(round) opens menu")
            dismiss.tap()
            XCTAssertTrue(home.waitUntilHittable(timeout: 5))
            Thread.sleep(forTimeInterval: 0.7)
            try assertRestingSize("Trigger 2 lift round \(round)")
        }

        // Trigger 3: Start slightly outside platter edge left of Home -> drag onto More -> lift -> dismiss.
        let outsideHome = home.coordinate(withNormalizedOffset: CGVector(dx: -0.05, dy: 0.5))
        outsideHome.press(forDuration: 0.15, thenDragTo: more.coordinate(withNormalizedOffset: c), withVelocity: .default, thenHoldForDuration: 0.0)
        if app.buttons["tab-settings"].waitUntilHittable(timeout: 3) {
            dismiss.tap()
            XCTAssertTrue(home.waitUntilHittable(timeout: 5))
            Thread.sleep(forTimeInterval: 0.7)
        }
        try assertRestingSize("Trigger 3 (edge-slop lift)")

        // Trigger 4: Subsequent native tab drag (Home -> Inbox -> Home) still works and settles at 1.0×.
        home.coordinate(withNormalizedOffset: c)
            .press(forDuration: 0.15, thenDragTo: inbox.coordinate(withNormalizedOffset: c))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: inbox)], timeout: 5)
        inbox.coordinate(withNormalizedOffset: c)
            .press(forDuration: 0.15, thenDragTo: home.coordinate(withNormalizedOffset: c))
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: home)], timeout: 5)
        Thread.sleep(forTimeInterval: 0.7)
        try assertRestingSize("Trigger 4 (subsequent native drag)")
    }

    private func darkPixelExtent(_ screenshot: XCUIScreenshot) throws -> (width: Int, height: Int, count: Int) {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var minX = w, maxX = -1, minY = h, maxY = -1, count = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2]) < 240 {
                    count += 1
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (maxX - minX + 1, maxY - minY + 1, count)
    }

    /// How many of a screenshot's pixels are near black, as a glyph's are on the light bar.
    private func darkPixels(_ screenshot: XCUIScreenshot) throws -> Int {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: rgba.count, by: 4).count { Int(rgba[$0]) + Int(rgba[$0 + 1]) + Int(rgba[$0 + 2]) < 240 }
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
        app.openTab("tab-settings")
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["tab-home"].tap()
        XCTAssertTrue(app.element("task-task0").waitUntilHittable())
        XCTAssertTrue(app.buttons["In progress"].isSelected, "Home keeps its status across tabs")
        XCTAssertEqual(app.staticTexts["listLoads"].label, loads, "Switching tabs must not reload the list")
    }

    func testRouterChatOpensOverTheTabsAndKeepsItsDraft() throws {
        let app = XCUIApplication.fixture()
        let home = app.buttons["tab-home"]
        XCTAssertTrue(home.waitUntilHittable(timeout: 10))
        let barBottom = home.frame.maxY
        let composer = app.openRouterChat()
        XCTAssertFalse(app.buttons["tab-home"].isHittable, "The router chat covers the tabs")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Router draft")
        app.buttons["closeRouterChat"].tap()
        XCTAssertTrue(composer.waitUntilGone(), "Closing folds the chat back into its button")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(home.frame.maxY, barBottom, accuracy: 1, "The tab bar returns to the bottom with the keyboard")
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

    /// The routine counts what is left beside its refresh. The member clears its cards one by one: the count follows,
    /// the cleared line takes the cards' place, and a refresh brings cards back.
    func testClearingTheRoutineShowsItClearedUntilARefresh() throws {
        let app = XCUIApplication.fixture(arguments: ["--routines-clear"])
        let open = app.element("openRoutine")
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let status = app.element("routineStatus"), refresh = app.element("refreshRoutines")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "3 things need you")
        // The refresh sits on the status line, at its trailing end.
        XCTAssertEqual(refresh.frame.midY, status.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(refresh.frame.minX, status.frame.minX)
        XCTAssertFalse(app.element("routinesCleared").exists)
        for (row, left) in [("item-0", "2 things need you"), ("item-1", "1 thing needs you"), ("item-2", "All cleared")] {
            app.element("pretask-dismiss-" + row).tap()
            let confirm = app.buttons["Don’t remind me"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            confirm.tap()
            XCTAssertTrue(app.element("pretask-" + row).waitUntilGone(), "The dismissed card leaves")
            wait(for: [expectation(for: NSPredicate(format: "label == %@", left), evaluatedWith: status)], timeout: 5)
        }
        let cleared = app.element("routinesCleared")
        XCTAssertTrue(cleared.waitForExistence(timeout: 3))
        XCTAssertEqual(cleared.label, "Congrats, routines cleared")
        refresh.tap()
        XCTAssertTrue(app.element("pretask-item-0").waitForExistence(timeout: 5), "A refresh brings cards back")
        XCTAssertTrue(cleared.waitUntilGone())
        XCTAssertEqual(status.label, "3 things need you")
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

    /// A diagonal rightward swipe starting near a message bubble's edge must not simultaneously recognize
    /// reply-swipe and router-close; the bubble keeps the reply gesture, and a subsequent leading-edge swipe
    /// closes the router chat cleanly with no lingering keyboard over Home.
    func testDiagonalSwipeExitNearMessageDoesNotRaiseKeyboardOrReply() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--hide-metrics"])
        let home = app.buttons["tab-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let barBottom = home.frame.maxY

        let composer = app.openRouterChat()
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "History message ")
        let bubble = try XCTUnwrap(app.staticTexts.matching(predicate).allElementsBoundByIndex.first { el in
            el.exists && el.isHittable && el.frame.midY >= 140 && el.frame.midY <= app.frame.height - 200
        }, "Expected a visible assistant message bubble")
        let startY = bubble.frame.minY - 9
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: startY))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 360, dy: startY - 80))
        start.press(forDuration: 0.05, thenDragTo: end)

        // ReplySwipe wins exclusively: the reply thread opens inside the still-open router chat.
        XCTAssertTrue(app.element("replyThread").waitForExistence(timeout: 3),
                      "Diagonal swipe starting inside a message bubble must open its reply thread")
        XCTAssertTrue(composer.isHittable, "Router chat must remain open when reply swipe claims the gesture")
        XCTAssertFalse(home.isHittable, "Home tab bar must stay covered while the router chat is open")
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        _ = keepScreenshot(app, "After diagonal swipe on bubble")

        // From the leading edge, a diagonal rightward swipe closes the router chat and dismisses the keyboard.
        let edgeStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 10, dy: 400))
        let edgeEnd = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 360, dy: 320))
        edgeStart.press(forDuration: 0.05, thenDragTo: edgeEnd)

        XCTAssertTrue(composer.waitUntilGone(), "Leading-edge swipe must close the router chat")
        XCTAssertTrue(home.waitUntilHittable(), "Home tab bar must be reachable after closing")
        XCTAssertEqual(home.frame.maxY, barBottom, accuracy: 1, "Tab bar must stay at its resting height")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        _ = keepScreenshot(app, "After left-edge swipe exit to Home")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Closing the router chat must not raise the keyboard over Home")

        _ = app.openRouterChat()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Reopening the router chat must not show the keyboard")
    }
}
