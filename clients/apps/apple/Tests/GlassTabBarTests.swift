import SwiftUI
import UIKit
import XCTest
@testable import Comma

@available(iOS 26.0, *)
@MainActor
final class GlassTabBarTests: XCTestCase {
    func testShellTabBarControllerUsesNativeUITabBarControllerAcrossPortraitAndCompact() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let navigation = AppNavigation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let bar = ShellTabBarController(store: harness.store, navigation: navigation, bar: ShellTabBar())
        window.rootViewController = bar
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKeyAndVisible()
        }

        // 1. Portrait (402×874): real UITabBarController with 4 primary tabs + detached prominent router UISearchTab.
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.layoutIfNeeded()
        bar.view.layoutIfNeeded()
        bar.systemBar.view.layoutIfNeeded()
        bar.systemBar.tabBar.layoutIfNeeded()

        XCTAssertEqual(bar.systemBar.tabs.count, 5, "Home, Inbox, People, More + prominent Router UISearchTab")
        XCTAssertEqual(bar.systemBar.tabs.map(\.accessibilityIdentifier),
                       ["tab-home", "tab-inbox", "tab-people", "tab-more", "openRouterChat"])
        XCTAssertTrue(bar.overflowMenu.isHidden, "Overflow menu overlay stays hidden at rest so UITabBarController runs 100% natively")
        XCTAssertNil(bar.systemBar.view.layer.mask, "systemBar.view has no mask at rest")
        let systemBarIdx = try XCTUnwrap(bar.view.subviews.firstIndex(where: { $0 === bar.systemBar.view }))
        let overflowIdx = try XCTUnwrap(bar.view.subviews.firstIndex(where: { $0 === bar.overflowMenu }))
        XCTAssertGreaterThan(overflowIdx, systemBarIdx,
                             "overflowMenu must sit above systemBar.view so native Liquid Glass portals and lifted lenses cannot draw over it")
        XCTAssertGreaterThan(bar.view.subviews.count - 1, overflowIdx,
                             "Unread attention dots must sit above overflowMenu so UIGlassEffect never refracts or distorts them while closing")
        XCTAssertEqual(bar.systemBar.view.tintColor.resolvedColor(with: bar.traitCollection),
                       UIColor(CommaTheme.textPrimary).resolvedColor(with: bar.traitCollection),
                       "systemBar.view.tintColor must match textPrimary so Duo vertical rail never falls back to systemBlue")
        XCTAssertNil(findView(containing: "UISegmentedControl", in: bar.view),
                     "No UISegmentedControl emulation may exist in ShellTabBarController")
        if #available(iOS 26.1, *) {
            for tab in bar.systemBar.tabs.prefix(3) {
                XCTAssertNotNil(tab.image, "\(tab.identifier) has normal image")
                XCTAssertNotNil(tab.selectedImage, "\(tab.identifier) uses native UITab.selectedImage for zero-jitter Render Server swaps")
            }
        }
        let portraitLens = try XCTUnwrap(findView(containing: "LiquidLens", in: bar.systemBar.tabBar),
                                         "Native UITabBarController must host Apple's single-element _UILiquidLensView")
        XCTAssertEqual(portraitLens.bounds.height, 54, accuracy: 1.0)
        XCTAssertGreaterThan(portraitLens.bounds.width, 70)
        let portraitPlatter = try XCTUnwrap(bar.primaryPlatterFrame(in: bar.view))
        XCTAssertEqual(portraitPlatter.height, 62, accuracy: 1.0)

        // Opening overflow menu masks all of systemBar.view.layer to .zero (eliminating any UIGlassContainerEffect
        // metaball bridge with the router circle) while standalone routerFace renders the detached circle cleanly.
        let moreTab = try XCTUnwrap(bar.systemBar.tabs.first { $0.accessibilityIdentifier == "tab-more" })
        _ = bar.tabBarController(bar.systemBar, shouldSelectTab: moreTab)
        try await Task.sleep(for: .milliseconds(300))
        let maskLayer = try XCTUnwrap(bar.systemBar.view.layer.mask,
                                      "Opening overflow menu must mask systemBar.view.layer to .zero so no glass portal or metaball bridge remains")
        XCTAssertEqual(maskLayer.frame, .zero,
                       "Mask must clip all of systemBar.view (including UIGlassContainerEffect metaball bridge) while routerFace draws the standalone circle")
        XCTAssertTrue(bar.systemBar.view.isHidden,
                      "While overflowMenu is open, systemBar.view and its non-standIn chrome must be hidden so even UIWindow-level CAPortalLayer lifted lenses cannot paint over the menu")
        XCTAssertNotNil(bar.routerFace.superview, "Standalone routerFace must render the clean circular router button while overflowMenu is open")
        XCTAssertNil(bar.overflowMenu.layer.mask, "Sibling overflowMenu above systemBar.view must stay unmasked")
        bar.overflowMenu.close()
        XCTAssertFalse(bar.systemBar.view.isHidden,
                       "Starting overflowMenu.close() must immediately restore systemBar.view.isHidden = false so tab-more accessibility stays intact during the closing morph")
        XCTAssertNotNil(bar.systemBar.view.layer.mask,
                        "systemBar.view.layer.mask stays active throughout the 0.3s closing morph")
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNil(bar.systemBar.view.layer.mask, "Closing overflow menu restores systemBar.view.layer.mask to nil")

        // 2. Compact landscape (874×402): same native UITabBarController adapts automatically to 44pt platter & 66×36 lens.
        window.traitOverrides.verticalSizeClass = .compact
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.updateTraitsIfNeeded()
        bar.updateTraitsIfNeeded()
        window.layoutIfNeeded()
        bar.view.layoutIfNeeded()
        bar.systemBar.view.layoutIfNeeded()
        bar.systemBar.tabBar.layoutIfNeeded()

        let compactPlatter = try XCTUnwrap(bar.primaryPlatterFrame(in: bar.view))
        XCTAssertEqual(compactPlatter.height, 44, accuracy: 1.0, "Compact landscape platter adapts natively to 44pt")
        let compactLens = try XCTUnwrap(findView(containing: "LiquidLens", in: bar.systemBar.tabBar))
        XCTAssertEqual(compactLens.bounds.height, 36, accuracy: 1.0, "Compact landscape native resting lens is 36pt tall")
        XCTAssertEqual(compactLens.bounds.width, 66, accuracy: 1.0, "Compact landscape native resting lens is 66pt wide")
    }

    func testOverflowMenuIndicatorCoversFullRowAcrossAllPostures() throws {
        struct Posture {
            let name: String
            let size: CGSize
            let orientation: TabOverflowMenuView.Orientation
            let platter: CGRect
            let slots: [CGRect]
            let expectedRowWidth: CGFloat
            let expectedRowHeight: CGFloat
        }

        func horizontalSlots(platter: CGRect, slotSize: CGSize) -> [CGRect] {
            let innerW = platter.width - 8
            let stride = (innerW - slotSize.width) / 3
            return (0..<4).map { i in
                CGRect(x: platter.minX + 4 + stride * CGFloat(i),
                       y: platter.minY + (platter.height - slotSize.height) / 2,
                       width: slotSize.width, height: slotSize.height)
            }
        }

        func verticalSlots(platter: CGRect) -> [CGRect] {
            // Native iOS 27 Duo vertical rail: 48×211pt platter, 44×58pt slots, 50pt stride, 1.5pt end inset, 2pt side inset.
            return (0..<4).map { i in
                CGRect(x: platter.minX + 2,
                       y: platter.minY + 1.5 + 50 * CGFloat(i),
                       width: 44, height: 58)
            }
        }

        let phonePlatter = CGRect(x: 21, y: 874 - 21 - 62, width: 290, height: 62)
        let compactPlatter = CGRect(x: 38, y: 402 - 20 - 44, width: 284, height: 44)
        let duoUnfoldedPlatter = CGRect(x: (669 - 330 - 8 - 62) / 2, y: 951 - 21 - 62, width: 330, height: 62)
        let duoTrailingPlatter = CGRect(x: 951 - 24 - 48, y: 669 - 24 - 48 - 13 - 211, width: 48, height: 211)
        let duoLeadingPlatter = CGRect(x: 24, y: 669 - 24 - 48 - 13 - 211, width: 48, height: 211)

        let postures: [Posture] = [
            .init(name: "iphone_portrait", size: CGSize(width: 402, height: 874), orientation: .horizontal,
                  platter: phonePlatter, slots: horizontalSlots(platter: phonePlatter, slotSize: CGSize(width: 76, height: 54)),
                  expectedRowWidth: 274, expectedRowHeight: 48),
            .init(name: "iphone_compact", size: CGSize(width: 874, height: 402), orientation: .horizontal,
                  platter: compactPlatter, slots: horizontalSlots(platter: compactPlatter, slotSize: CGSize(width: 66, height: 36)),
                  expectedRowWidth: 268, expectedRowHeight: 48),
            .init(name: "duo_unfolded_portrait", size: CGSize(width: 669, height: 951), orientation: .horizontal,
                  platter: duoUnfoldedPlatter, slots: horizontalSlots(platter: duoUnfoldedPlatter, slotSize: CGSize(width: 94, height: 54)),
                  expectedRowWidth: 314, expectedRowHeight: 48),
            .init(name: "duo_vertical_trailing", size: CGSize(width: 951, height: 669), orientation: .vertical(trailing: true),
                  platter: duoTrailingPlatter, slots: verticalSlots(platter: duoTrailingPlatter),
                  expectedRowWidth: 48, expectedRowHeight: 208),
            .init(name: "duo_vertical_leading", size: CGSize(width: 951, height: 669), orientation: .vertical(trailing: false),
                  platter: duoLeadingPlatter, slots: verticalSlots(platter: duoLeadingPlatter),
                  expectedRowWidth: 48, expectedRowHeight: 208),
        ]

        let snapDir = ProcessInfo.processInfo.environment["GLASS_TAB_BAR_SNAPSHOT_DIR"]
        let styles: [UIUserInterfaceStyle] = snapDir == nil ? [.light] : [.light, .dark]

        for style in styles {
            for posture in postures {
                let bounds = CGRect(origin: .zero, size: posture.size)
                let window: UIWindow
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    window = UIWindow(windowScene: scene)
                    window.frame = bounds
                } else {
                    window = UIWindow(frame: bounds)
                }
                defer { window.isHidden = true }
                window.overrideUserInterfaceStyle = style

                let host = UIViewController()
                host.view.backgroundColor = style == .dark ? UIColor(white: 0.08, alpha: 1) : .white
                window.rootViewController = host
                window.makeKeyAndVisible()
                window.layoutIfNeeded()

                let stage = UIView(frame: bounds)
                stage.backgroundColor = host.view.backgroundColor
                let menu = TabOverflowMenuView(frame: stage.bounds)
                menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                let avatar = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { ctx in
                    UIColor.systemPink.withAlphaComponent(0.35).setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 24, height: 24))
                }.withRenderingMode(.alwaysOriginal)
                menu.primaryItems = [
                    .init(id: "tab-home", title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill")),
                    .init(id: "tab-inbox", title: "Inbox", image: UIImage(systemName: "tray"), selectedImage: UIImage(systemName: "tray.fill")),
                    .init(id: "tab-people", title: "People", image: UIImage(systemName: "person.2"), selectedImage: UIImage(systemName: "person.2.fill")),
                ]
                menu.overflow = [
                    .init(id: "tab-apps", title: "Apps", image: UIImage(systemName: "square.grid.2x2")),
                    .init(id: "tab-drive", title: "Drive", image: UIImage(systemName: "doc")),
                    .init(id: "tab-plugins", title: "Plugins", image: UIImage(systemName: "puzzlepiece.extension")),
                    .init(id: "tab-settings", title: "Settings", image: avatar, selectedImage: avatar),
                ]
                menu.selectedID = "tab-settings"
                menu.overflowID = "tab-settings"
                var visibilityLog: [Bool] = []
                menu.onVisibilityChange = { visibilityLog.append($0) }
                stage.addSubview(menu)

                if case .vertical(let trailing) = posture.orientation, trailing {
                    stage.frame.origin.x = window.bounds.width - posture.size.width
                } else if posture.size.width > window.bounds.width && posture.orientation == .horizontal && posture.name != "iphone_compact" {
                    stage.frame.origin.x = (window.bounds.width - posture.size.width) / 2
                }
                if posture.size.height > window.bounds.height {
                    stage.frame.origin.y = window.bounds.height - posture.size.height
                }
                host.view.addSubview(stage)
                window.layoutIfNeeded()

                XCTAssertTrue(menu.isHidden, "\(posture.name): overlay starts hidden at rest")

                let anchor = TabOverflowMenuView.Anchor(
                    platterFrame: posture.platter,
                    slotFrames: posture.slots,
                    orientation: posture.orientation,
                    selectedSlot: 3,
                    overflowSelected: true,
                    handoffLens: nil
                )
                menu.open(anchor: anchor, tracking: false, at: nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.75))
                window.layoutIfNeeded()
                menu.layoutIfNeeded()

                XCTAssertEqual(visibilityLog, [true], "\(posture.name): hides native platter while open")
                let barGlass = try XCTUnwrap(findByIdentifier("glassTabBar.bar", in: menu) as? UIVisualEffectView)
                XCTAssertTrue(barGlass.effect is UIGlassEffect, "\(posture.name): menu keeps pure Liquid Glass")
                let nestedBlurs = barGlass.contentView.subviews.compactMap { $0 as? UIVisualEffectView }
                    .filter { $0.effect is UIBlurEffect }
                XCTAssertTrue(nestedBlurs.isEmpty, "\(posture.name): no nested UIBlurEffect on bar glass")

                let menuIndicator = try XCTUnwrap(findByIdentifier("glassTabBar.menuIndicator", in: menu))
                let menuClip = try XCTUnwrap(menuIndicator.superview)
                let indicatorFill = try XCTUnwrap(menuIndicator.subviews.first)
                let menuFrost = try XCTUnwrap(findBlurEffectView(in: menuIndicator))

                XCTAssertFalse(menuIndicator.isHidden, "\(posture.name): indicator visible when open")
                XCTAssertGreaterThan(menuIndicator.alpha, 0.95, "\(posture.name): indicator full alpha")
                XCTAssertEqual(menuIndicator.bounds.width, posture.expectedRowWidth, accuracy: 2.0, "\(posture.name): indicator width")
                XCTAssertEqual(menuIndicator.bounds.height, posture.expectedRowHeight, accuracy: 2.0, "\(posture.name): indicator height")
                XCTAssertEqual(indicatorFill.bounds.size.width, menuIndicator.bounds.width, accuracy: 0.5)
                XCTAssertEqual(indicatorFill.bounds.size.height, menuIndicator.bounds.height, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(menuFrost.frame.width, indicatorFill.bounds.width,
                                            "\(posture.name): indicatorFrost width covers full row")
                XCTAssertGreaterThanOrEqual(menuFrost.frame.height, indicatorFill.bounds.height,
                                            "\(posture.name): indicatorFrost height covers full row")
                XCTAssertTrue(menuClip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(menuIndicator.frame),
                              "\(posture.name): indicator clipped inside menuClip")

                if let snapDir {
                    let styleTag = style == .dark ? "dark" : "light"
                    let url = URL(fileURLWithPath: snapDir)
                        .appendingPathComponent("\(posture.name)_\(styleTag)_menu.png")
                    let img = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try img.pngData()?.write(to: url)
                }

                menu.close()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                window.layoutIfNeeded()
                XCTAssertTrue(menu.isHidden, "\(posture.name): overlay hides again after close")
                XCTAssertEqual(visibilityLog, [true, false], "\(posture.name): restores native platter after close")
            }
        }
    }

    /// Regression test for iPhone Duo vertical trailing rail (`-90°` rotated canvas): when an overflow page
    /// (`Plugins`) is active on the bottom `More` slot, opening and closing the overflow menu must start from and
    /// return to the bottom `More` slot (`slots[3]`, `44×58pt`), never animating up to the top `Home` slot (`slots[0]`).
    func testOverflowMenuCloseLandsOnBottomMoreSlotInDuoVerticalPostures() throws {
        let size = CGSize(width: 951, height: 669)
        let trailingPlatter = CGRect(x: 951 - 24 - 48, y: 669 - 24 - 48 - 13 - 211, width: 48, height: 211)
        let leadingPlatter = CGRect(x: 24, y: 669 - 24 - 48 - 13 - 211, width: 48, height: 211)

        func verticalSlots(platter: CGRect) -> [CGRect] {
            (0..<4).map { i in
                CGRect(x: platter.minX + 2, y: platter.minY + 1.5 + 50 * CGFloat(i), width: 44, height: 58)
            }
        }

        let cases: [(name: String, orientation: TabOverflowMenuView.Orientation, platter: CGRect)] = [
            ("duo_vertical_trailing", .vertical(trailing: true), trailingPlatter),
            ("duo_vertical_leading", .vertical(trailing: false), leadingPlatter),
        ]

        for entry in cases {
            let bounds = CGRect(origin: .zero, size: size)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                window = UIWindow(windowScene: scene)
                window.frame = bounds
            } else {
                window = UIWindow(frame: bounds)
            }
            defer { window.isHidden = true }

            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()

            let menu = TabOverflowMenuView(frame: bounds)
            menu.primaryItems = [
                .init(id: "tab-home", title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill")),
                .init(id: "tab-inbox", title: "Inbox", image: UIImage(systemName: "tray"), selectedImage: UIImage(systemName: "tray.fill")),
                .init(id: "tab-people", title: "People", image: UIImage(systemName: "person.2"), selectedImage: UIImage(systemName: "person.2.fill")),
            ]
            menu.overflow = [
                .init(id: "tab-apps", title: "Apps", image: UIImage(systemName: "square.grid.2x2")),
                .init(id: "tab-drive", title: "Drive", image: UIImage(systemName: "doc")),
                .init(id: "tab-plugins", title: "Plugins", image: UIImage(systemName: "puzzlepiece.extension")),
                .init(id: "tab-settings", title: "Settings", image: UIImage(systemName: "gearshape")),
            ]
            menu.selectedID = "tab-plugins"
            menu.overflowID = "tab-plugins"
            host.view.addSubview(menu)
            window.layoutIfNeeded()

            let slots = verticalSlots(platter: entry.platter)
            let homeSlot = slots[0]
            let moreSlot = slots[3]
            let anchor = TabOverflowMenuView.Anchor(
                platterFrame: entry.platter,
                slotFrames: slots,
                orientation: entry.orientation,
                selectedSlot: 3,
                overflowSelected: true,
                handoffLens: nil,
                restingPillSize: CGSize(width: 44, height: 58),
                restingPillEdgeInset: 1.5
            )

            menu.open(anchor: anchor, tracking: false, at: nil)
            let menuIndicator = try XCTUnwrap(findByIdentifier("glassTabBar.menuIndicator", in: menu))
            // On the opening frame, indicator must start on the bottom More slot (never top Home slot).
            let openStartRect = menuIndicator.convert(menuIndicator.bounds, to: menu)
            XCTAssertLessThan(abs(openStartRect.midY - moreSlot.midY), abs(openStartRect.midY - homeSlot.midY),
                              "\(entry.name): opening indicator must start at bottom More slot, not top Home slot")
            XCTAssertEqual(openStartRect.midY, moreSlot.midY, accuracy: 2.0,
                           "\(entry.name): opening indicator center matches bottom More slot")
            XCTAssertEqual(openStartRect.width, 44, accuracy: 1.0, "\(entry.name): resting vertical pill width is 44pt")
            XCTAssertEqual(openStartRect.height, 58, accuracy: 1.0, "\(entry.name): resting vertical pill height is 58pt")

            RunLoop.current.run(until: Date().addingTimeInterval(0.65))
            menu.close()
            // Sample near end of the 0.3s closing morph while menuIndicator is still visible and arriving on its landing slot.
            RunLoop.current.run(until: Date().addingTimeInterval(0.24))
            let closingRect = menuIndicator.convert(menuIndicator.bounds, to: menu)
            XCTAssertLessThan(abs(closingRect.midY - moreSlot.midY), abs(closingRect.midY - homeSlot.midY),
                              "\(entry.name): closing indicator must converge to bottom More slot, not top Home slot")
            XCTAssertEqual(closingRect.midY, moreSlot.midY, accuracy: 12.0,
                           "\(entry.name): closing indicator lands on bottom More slot (midY=\(closingRect.midY), more=\(moreSlot.midY), home=\(homeSlot.midY))")

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertTrue(menu.isHidden, "\(entry.name): hides cleanly after close")
        }
    }

    /// Verifies that both opening and closing the overflow menu apply a smooth critically-damped spring major-axis
    /// squeeze (zero overshoot wider than the resting bar) while keeping `menuIndicator` inside `menuClip`, and settle
    /// back to exact `barFrame.width` (`0.0 pt`) at rest.
    func testOverflowMenuOpenAndCloseApplyMajorAxisSpringSqueeze() throws {
        let size = CGSize(width: 402, height: 874)
        let platter = CGRect(x: 21, y: 874 - 21 - 62, width: 290, height: 62)
        let innerW = platter.width - 8
        let stride = (innerW - 76) / 3
        let slots = (0..<4).map { i in
            CGRect(x: platter.minX + 4 + stride * CGFloat(i), y: platter.minY + 4, width: 76, height: 54)
        }

        let bounds = CGRect(origin: .zero, size: size)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        defer { window.isHidden = true }

        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let menu = TabOverflowMenuView(frame: bounds)
        menu.primaryItems = [
            .init(id: "tab-home", title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill")),
            .init(id: "tab-inbox", title: "Inbox", image: UIImage(systemName: "tray"), selectedImage: UIImage(systemName: "tray.fill")),
            .init(id: "tab-people", title: "People", image: UIImage(systemName: "person.2"), selectedImage: UIImage(systemName: "person.2.fill")),
        ]
        menu.overflow = [
            .init(id: "tab-apps", title: "Apps", image: UIImage(systemName: "square.grid.2x2")),
            .init(id: "tab-drive", title: "Drive", image: UIImage(systemName: "doc")),
            .init(id: "tab-plugins", title: "Plugins", image: UIImage(systemName: "puzzlepiece.extension")),
            .init(id: "tab-settings", title: "Settings", image: UIImage(systemName: "gearshape")),
        ]
        menu.selectedID = "tab-drive"
        menu.overflowID = "tab-drive"
        host.view.addSubview(menu)
        window.layoutIfNeeded()

        let anchor = TabOverflowMenuView.Anchor(
            platterFrame: platter,
            slotFrames: slots,
            orientation: .horizontal,
            selectedSlot: 3,
            overflowSelected: true,
            handoffLens: nil,
            restingPillSize: CGSize(width: 76, height: 54),
            restingPillEdgeInset: 10.0 / 3.0
        )

        let barGlass = try XCTUnwrap(findByIdentifier("glassTabBar.bar", in: menu))
        let menuIndicator = try XCTUnwrap(findByIdentifier("glassTabBar.menuIndicator", in: menu))
        let menuClip = try XCTUnwrap(menuIndicator.superview)

        // 1. Opening: major-axis width pinches noticeably (~18-20%) then springs smoothly back out to 290pt with zero overshoot.
        menu.open(anchor: anchor, tracking: false, at: nil)
        var minOpenWidth = platter.width
        var maxOpenWidth: CGFloat = 0
        for _ in 0..<24 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let w = barGlass.bounds.width
            minOpenWidth = min(minOpenWidth, w)
            maxOpenWidth = max(maxOpenWidth, w)
            XCTAssertTrue(menuClip.bounds.insetBy(dx: -1.0, dy: -1.0).contains(menuIndicator.frame),
                          "menuIndicator must stay unclipped inside menuClip during opening squeeze")
        }
        XCTAssertLessThan(minOpenWidth, platter.width * 0.88,
                          "Opening must squeeze major-axis width by at least 12% (min=\(minOpenWidth), base=\(platter.width))")
        XCTAssertLessThanOrEqual(maxOpenWidth, platter.width + 0.5,
                                 "Opening squeeze must ease out with zero overshoot wider than resting bar")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(barGlass.bounds.width, platter.width, accuracy: 0.5, "Opening settles at exact bar width")

        // 2. Closing: major-axis width also pinches noticeably (~15-18%) then springs smoothly back out to 290pt before hiding.
        menu.close()
        var minCloseWidth = platter.width
        var maxCloseWidth: CGFloat = 0
        var lastVisibleWidth = platter.width
        for _ in 0..<26 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if !menu.isHidden {
                let w = barGlass.bounds.width
                minCloseWidth = min(minCloseWidth, w)
                maxCloseWidth = max(maxCloseWidth, w)
                lastVisibleWidth = w
                XCTAssertTrue(menuClip.bounds.insetBy(dx: -1.0, dy: -1.0).contains(menuIndicator.frame),
                              "menuIndicator must stay unclipped inside menuClip during closing squeeze")
            }
        }
        XCTAssertLessThan(minCloseWidth, platter.width * 0.90,
                          "Closing must squeeze major-axis width by at least 10% (min=\(minCloseWidth), base=\(platter.width))")
        XCTAssertLessThanOrEqual(maxCloseWidth, platter.width + 0.5,
                                 "Closing squeeze must ease out with zero overshoot wider than resting bar")
        XCTAssertEqual(lastVisibleWidth, platter.width, accuracy: 1.5,
                       "Closing blooms back to full resting width before handoff")
        XCTAssertTrue(menu.isHidden, "Overlay hides cleanly once close morph settles")
    }

    private func findByIdentifier(_ id: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == id { return root }
        for sub in root.subviews { if let found = findByIdentifier(id, in: sub) { return found } }
        return nil
    }

    private func findView(containing className: String, in root: UIView) -> UIView? {
        if NSStringFromClass(type(of: root)).contains(className) { return root }
        for sub in root.subviews { if let found = findView(containing: className, in: sub) { return found } }
        return nil
    }

    private func findBlurEffectView(in root: UIView) -> UIVisualEffectView? {
        if let v = root as? UIVisualEffectView, v.effect is UIBlurEffect { return v }
        for sub in root.subviews { if let found = findBlurEffectView(in: sub) { return found } }
        return nil
    }
}
