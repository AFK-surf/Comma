import XCTest

/// The composer's @ and / menus, as the desktop's: the buttons beside the + while the keyboard is up, the menu above
/// the composer, the desktop's trigger rules, what a pick writes and what a send carries. The fixture has no
/// Resources, so glyphs are blank and strings are English keys; everything is found by identifier.
@MainActor final class ComposerMenuUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTriggerButtonsShowOnlyWhileTheComposerIsFocused() throws {
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        let mention = app.element("composerMention"), skill = app.element("composerSkill")
        XCTAssertFalse(mention.exists, "Collapsed, the composer offers only the +")
        focus(composer, in: app)
        XCTAssertTrue(mention.waitUntilHittable())
        let plus = app.buttons["Add attachment"].frame, send = app.element("sendMessage").frame
        // @ and / follow the + in its row, level with Send.
        XCTAssertEqual(mention.frame.minX, plus.maxX, accuracy: 1)
        XCTAssertEqual(skill.frame.minX, mention.frame.maxX, accuracy: 1)
        for button in [mention, skill] { XCTAssertEqual(button.frame.midY, send.midY, accuracy: 1) }
        XCTAssertEqual(mention.label, "Mention a task")
        XCTAssertEqual(skill.label, "Use a skill")
        app.at(0.5, 0.2).press(forDuration: 0.05, thenDragTo: app.at(0.5, 0.35))
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 3))
        XCTAssertTrue(mention.waitUntilGone(), "Scrolling the transcript collapses the composer and its buttons")
        XCTAssertFalse(skill.exists)
    }

    func testMentionButtonOpensTasksAboveTheComposerAndInsertsTheChosenTask() throws {
        let app = XCUIApplication.fixture(light: true)
        let composer = app.openRouterChat()
        focus(composer, in: app)
        app.element("composerMention").tap()
        let menu = app.element("composerMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "@")
        XCTAssertEqual(menu.label, "Mentions")
        // The menu spans the composer, 8pt above its glass (whose text sits 16pt in), below the chat's header.
        XCTAssertEqual(menu.frame.minX, app.buttons["Add attachment"].frame.minX, accuracy: 2)
        XCTAssertEqual(menu.frame.maxX, app.element("sendMessage").frame.maxX, accuracy: 2)
        XCTAssertEqual(menu.frame.maxY, composer.frame.minY - 24, accuracy: 2)
        XCTAssertGreaterThanOrEqual(menu.frame.minY, app.element("closeRouterChat").frame.maxY)
        XCTAssertTrue(app.element("menu-task:task0").exists, "The router offers every open Task")
        composer.typeText("29")
        let task = app.element("menu-task:task29")
        XCTAssertTrue(task.waitUntilHittable())
        XCTAssertEqual(Set(rows(in: app).map(\.identifier)), ["menu-task:task29"], "Only Task 29 matches 29")
        let screenshot = keepScreenshot(app, "Mention menu filtered above the keyboard")
        // The menu leaves the keyboard's corner fix alone: its light bottom never shows the black canvas.
        let rgba = try pixel(screenshot, at: CGPoint(x: app.frame.minX + 3, y: app.frame.maxY - 4), in: app.frame)
        for component in rgba.prefix(3) { XCTAssertGreaterThan(component, 150, "Keyboard bottom: \(rgba)") }
        task.tap()
        XCTAssertTrue(menu.waitUntilGone())
        XCTAssertEqual(composer.value as? String, "@Task 29 ")
        XCTAssertTrue(app.keyboards.firstMatch.isHittable, "A pick keeps the keyboard up")
        composer.typeText("next")
        let ink = try pickInk(keepScreenshot(app, "A picked Task in the brand colour"), composer: composer, app: app)
        XCTAssertGreaterThan(ink.brand.count, ink.minimum, "The picked Task is drawn in the brand colour")
        XCTAssertGreaterThan(ink.text.count, ink.minimum, "The text typed after it is drawn in the text colour")
        XCTAssertLessThan(try XCTUnwrap(ink.brand.max()), try XCTUnwrap(ink.text.min()), "Only the pick is in the brand colour")
    }

    func testTypedTriggersFollowTheDesktopRules() throws {
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        focus(composer, in: app)
        let menu = app.element("composerMenu")
        composer.typeText("hi @")
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "A trigger after a space opens its menu")
        composer.typeText(" ")
        XCTAssertTrue(menu.waitUntilGone(), "A space closes it")
        composer.typeText("@zzz")
        XCTAssertTrue(app.element("composerMenuEmpty").waitForExistence(timeout: 3), "No match reads No results")
        XCTAssertTrue(menu.exists, "No results keeps the menu open")
        clear(composer)
        composer.typeText("a/b")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(menu.exists, "A slash inside a word opens nothing")
        clear(composer)
        composer.typeText("go ")
        let mention = app.element("composerMention")
        mention.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "go @")
        XCTAssertTrue(mention.isSelected, "The open menu's button reads as selected")
        mention.tap()
        XCTAssertTrue(menu.waitUntilGone())
        XCTAssertEqual(composer.value as? String, "go ", "The same button takes a bare trigger back out")
    }

    func testSkillChoiceIsSentAsTheDesktopSkillsField() throws {
        let app = XCUIApplication.fixture(light: true)
        let composer = app.openRouterChat()
        focus(composer, in: app)
        app.element("composerSkill").tap()
        let menu = app.element("composerMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(menu.label, "Commands and skills")
        XCTAssertTrue(app.element("menu-salix-status").exists, "The router chat lists the agent commands first")
        XCTAssertTrue(app.element("menu-frontend-design").waitForExistence(timeout: 3), "Then the workspace skills")
        composer.typeText("front")
        let skill = app.element("menu-frontend-design")
        XCTAssertTrue(skill.waitUntilHittable())
        XCTAssertFalse(app.element("menu-salix-status").exists)
        skill.tap()
        XCTAssertTrue(menu.waitUntilGone())
        XCTAssertEqual(composer.value as? String, "/frontend-design ")
        let ink = try pickInk(keepScreenshot(app, "A picked skill in the brand colour"), composer: composer, app: app)
        XCTAssertGreaterThan(ink.brand.count, ink.minimum, "The picked skill is drawn in the brand colour")
        // Sent straight after typing: the simulator's keyboard drops and comes back a moment later, under the tap.
        composer.typeText("make it pop")
        app.element("sendMessage").tap()
        XCTAssertFalse(menu.exists)
        let sent = app.staticTexts["lastSend"]
        XCTAssertTrue(sent.wait(for: \.label, toEqual: "text=/frontend-design make it pop|skills=/.runtime/skills/frontend-design/SKILL.md",
                                timeout: 5), "The send carries the skill's location, as the desktop's does (\(sent.label))")
    }

    func testTaskDockMenuSkipsTheOpenTaskAndStaysBelowTheHeader() throws {
        let app = XCUIApplication.fixture()
        app.openRouterChat()
        app.openTaskFromRouter()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let composer = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "chatComposer")
            .allElementsBoundByIndex.first(where: \.isHittable))
        focus(composer, in: app)
        app.element("composerMention").tap()
        let menu = app.element("composerMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertTrue(app.element("menu-task:task1").exists)
        XCTAssertFalse(app.element("menu-task:task0").exists, "A Task's own composer does not offer the Task")
        XCTAssertGreaterThanOrEqual(menu.frame.minY, close.frame.maxY, "The menu stays below the Task's header")
        XCTAssertGreaterThanOrEqual(app.keyboards.firstMatch.frame.minY - composer.frame.maxY, 8)
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(menu.waitUntilGone())
        app.element("composerSkill").tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(menu.label, "Skills")
        XCTAssertTrue(app.element("menu-frontend-design").waitForExistence(timeout: 3))
        XCTAssertFalse(app.element("menu-salix-status").exists, "Agent commands belong to the router chat")
    }

    func testAttachmentMenuAndTriggerMenuAreNeverOpenTogether() throws {
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        focus(composer, in: app)
        app.element("composerMention").tap()
        let menu = app.element("composerMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        app.buttons["Add attachment"].tap()
        XCTAssertTrue(app.buttons["Photos"].waitUntilHittable())
        XCTAssertTrue(menu.waitUntilGone(), "The + card closes the @ menu")
        XCTAssertTrue(app.element("composerMention").waitUntilUnhittable(), "The card covers @ and /")
        app.at(0.5, 0.3).tap()
        XCTAssertTrue(app.buttons["Photos"].waitUntilUnhittable())
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "Closing the card brings the menu back")
        XCTAssertEqual(composer.value as? String, "@")
    }

    /// Photos picked from the panel show as tiles at once and upload side by side; Send waits until every one has
    /// uploaded, and a failed one is tapped to try again.
    func testPickedPhotosUploadAsTilesAndAFailedOneRetries() throws {
        let app = XCUIApplication.fixture(arguments: ["--upload-fail-once"])
        app.openRouterChat()
        app.buttons["Add attachment"].tap()
        XCTAssertTrue(app.buttons["Photos"].waitUntilHittable())
        app.buttons["Photos"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let photos = app.buttons.matching(NSPredicate(format: "label == %@", "Photo"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 8))
        photos.element(boundBy: 0).tap()
        photos.element(boundBy: 1).tap()
        app.buttons["Add 2"].tap()
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Photo.jpg"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 3), "A picked photo shows before it has uploaded")
        let failed = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "Couldn’t upload")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 5), "The first upload fails")
        XCTAssertFalse(app.element("sendMessage").isEnabled, "Send waits for a failed upload")
        failed.tap()
        XCTAssertTrue(failed.waitUntilGone(), "Tapping retries it")
        XCTAssertTrue(app.element("sendMessage").waitUntilEnabled(), "Send once both have uploaded")
    }

    /// In the router chat the @ menu also lists the models the Workspace can run, to start a Task with (desktop #3785):
    /// a row picks a model at its default effort, its chevron shows the efforts it takes, and the pick reads
    /// `@GPT 5.5 · high` in the field and in the sent bubble while the send carries its `comma:model` link.
    func testRouterMentionMenuStartsATaskWithAModelAtAnEffort() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--models", "--hide-metrics"])
        let composer = app.openRouterChat()
        focus(composer, in: app)
        app.element("composerMention").tap()
        let menu = app.element("composerMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        let gpt = app.element("menu-model:gpt-5.5")
        XCTAssertTrue(gpt.waitUntilHittable(), "The router lists the models a profile serves")
        XCTAssertTrue(app.element("menu-model:gpt-5.5-mini").exists)
        XCTAssertFalse(app.element("menu-model:claude-opus-5").exists, "No profile serves Claude Opus 5")
        XCTAssertFalse(app.element("menu-model:gpt-5.5-mini/efforts").exists, "A model without efforts has no chevron")
        _ = keepScreenshot(app, "Mention menu with the models to start a Task with")

        composer.typeText("gpt")
        XCTAssertTrue(app.element("menu-model:gpt-5.5").waitUntilHittable())
        app.element("menu-model:gpt-5.5/efforts").tap()
        let back = app.element("composerMenuBack")
        XCTAssertTrue(back.waitUntilHittable(), "The chevron shows the model's efforts")
        XCTAssertEqual(back.value as? String, "GPT 5.5")
        for id in ["default", "low", "medium", "high"] { XCTAssertTrue(app.element("menu-model:gpt-5.5:" + id).exists, id) }
        XCTAssertFalse(app.element("menu-model:gpt-5.5-mini").exists, "In place of the list")
        _ = keepScreenshot(app, "A model's thinking efforts")
        back.tap()
        XCTAssertTrue(app.element("menu-model:gpt-5.5-mini").waitUntilHittable(), "Back shows the list as the query left it")
        app.element("menu-model:gpt-5.5/efforts").tap()
        app.element("menu-model:gpt-5.5:high").tap()
        XCTAssertTrue(menu.waitUntilGone())
        XCTAssertEqual(composer.value as? String, "@GPT 5.5 · high ")
        XCTAssertTrue(app.keyboards.firstMatch.isHittable, "A pick keeps the keyboard up")
        composer.typeText("draft the launch notes")
        let ink = try pickInk(keepScreenshot(app, "A picked model in the composer"), composer: composer, app: app)
        XCTAssertGreaterThan(ink.brand.count, ink.minimum, "The picked model is drawn in the brand colour")

        app.element("sendMessage").tap()
        let sent = app.staticTexts["lastSend"]
        XCTAssertTrue(sent.wait(for: \.label, toEqual: "text=[GPT 5.5 · high](comma:model/gpt-5.5?effort=high) draft the launch notes|skills=",
                                timeout: 5), "The send carries the model's link (\(sent.label))")
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", "@GPT 5.5 · high draft the launch notes")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "The sent bubble reads the pick as the field did")
        _ = keepScreenshot(app, "The sent message reads the model's name")
    }

    // MARK: Helpers

    /// Focuses the composer and brings the software keyboard up, which expands the composer.
    private func focus(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        composer.raiseKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilHittable())
    }

    /// Deletes the focused composer's text, character by character, as Backspace does.
    private func clear(_ composer: XCUIElement) {
        let count = (composer.value as? String)?.count ?? 0
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    }

    /// The pixel columns of the composer's line of text drawn in the brand colour and in the text colour, the caret left
    /// out, and how many columns make a word's worth. Light mode: brand 0x205BFF, text 0x1A1B1E.
    private func pickInk(_ screenshot: XCUIScreenshot, composer: XCUIElement,
                         app: XCUIApplication) throws -> (brand: [Int], text: [Int], minimum: Int) {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = CGFloat(width) / app.frame.width
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
        }
        func isBrand(_ x: Int, _ y: Int) -> Bool { let (r, g, b) = rgb(x, y); return b > 200 && b - r > 120 && b - g > 60 }
        func isInk(_ x: Int, _ y: Int) -> Bool { let (r, g, b) = rgb(x, y); return max(r, g, b) < 100 }
        let frame = composer.frame
        // The field's text, short of Send at its trailing edge.
        let xs = Int((frame.minX + 4) * scale)..<Int((frame.maxX - 52) * scale)
        let ys = Int(frame.minY * scale)..<min(Int(frame.maxY * scale), height)
        // The pick's line: the rows with brand ink, which the buttons below the text never have.
        let line = ys.filter { y in xs.contains { isBrand($0, y) } }
        let rows = try XCTUnwrap(line.min(), "The pick is drawn in the brand colour")...line.max()!
        let text = xs.filter { x in rows.contains { isInk(x, $0) } }
        // The caret, a brand bar straight after the last letters (when the blink shows it), is not the pick.
        let last = text.max() ?? xs.lowerBound, caretEnd = last + Int(4 * scale)
        let brand = xs.filter { x in !(x > last && x <= caretEnd) && rows.contains { isBrand(x, $0) } }
        return (brand, text, Int(12 * scale))
    }

    /// The menu's rows, whatever their type.
    private func rows(in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "menu-"))
            .allElementsBoundByIndex
    }
}
