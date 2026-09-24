//
//  PanelTests.swift
//  SaathiShellTests
//
//  Panels are checked by eye in the running app; these only pin what they expose and that they
//  can be built and driven without a run loop.
//

import AppKit
import XCTest
import SaathiKit
import SaathiMascot
import QuartzCore
@testable import SaathiShell

@MainActor
final class PanelTests: XCTestCase {

    private func data() throws -> MascotData { try MascotData.load() }
    private let blue = MascotColor(hex: "#377FE6")

    // MARK: the buddy

    func testTheBuddyIsSmallClickThroughAboveEverythingAndOnEverySpace() {
        let panel = CompanionPanel()
        XCTAssertEqual(CompanionPanel.side, 48)
        XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isShowing)
    }

    func testTheBuddyFollowsThePointer() {
        let panel = CompanionPanel()
        let before = panel.frame.origin
        panel.step(pointer: CGPoint(x: before.x + 400, y: before.y + 300), dt: 10)
        XCTAssertGreaterThan(panel.frame.origin.x, before.x)
        XCTAssertGreaterThan(panel.frame.origin.y, before.y)
    }

    /// Sixty steps a second on a pointer that has not moved used to be sixty window moves a
    /// second, each one going to the window server for nothing.
    func testTheBuddyMovesNoWindowWhileThePointerIsStill() throws {
        let screen = try XCTUnwrap(NSScreen.main, "needs a display")
        let panel = CompanionPanel()
        let pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        for _ in 0..<120 { panel.step(pointer: pointer, dt: 1.0 / 60) }

        let settled = panel.frame.origin
        let moves = panel.moves
        panel.step(pointer: pointer, dt: 1.0 / 60)
        XCTAssertEqual(panel.frame.origin, settled, "the buddy had already arrived")
        XCTAssertEqual(panel.moves, moves, "a still pointer moves no window")

        panel.step(pointer: CGPoint(x: pointer.x + 300, y: pointer.y), dt: 1.0 / 60)
        XCTAssertGreaterThan(panel.moves, moves, "and it follows again the moment the pointer does")
    }

    func testTheBuddyIsASixteenPointOrangeTriangleWithAGlow() {
        let panel = CompanionPanel()
        XCTAssertEqual(PointerBuddyView.triangleSide, 16)
        XCTAssertEqual(PointerBuddyView.rotation, -35)
        let tint = PointerBuddyView.tint.usingColorSpace(.sRGB)
        XCTAssertEqual(tint?.redComponent ?? 0, 0xF0 / 255, accuracy: 0.001)
        XCTAssertEqual(tint?.greenComponent ?? 0, 0x45 / 255, accuracy: 0.001)
        XCTAssertEqual(tint?.blueComponent ?? 0, 0x2B / 255, accuracy: 0.001)
        XCTAssertEqual(panel.buddy.glowRadius, 8, "the resting glow")
        XCTAssertTrue(panel.buddy.isFlipped, "the triangle is drawn y-down")

        let box = PointerBuddyView.trianglePath(side: 16).boundingBox
        XCTAssertEqual(box.width, 16, accuracy: 0.01)
        XCTAssertEqual(box.height, 16 * sqrt(3) / 2, accuracy: 0.01, "equilateral")
    }

    func testTheBuddyCarriesTheStateWordForVoiceOverAndShowsItInItsGlow() {
        let panel = CompanionPanel()
        panel.setState(.listening)
        XCTAssertEqual(panel.buddy.accessibilityLabel(), "Listening")
        XCTAssertTrue(panel.buddy.isPulsing, "listening breathes")
        XCTAssertEqual(panel.buddy.glowRadius, 8)

        panel.setState(.thinking)
        XCTAssertEqual(panel.buddy.accessibilityLabel(), "Thinking")
        XCTAssertFalse(panel.buddy.isPulsing)
        XCTAssertEqual(panel.buddy.glowRadius, 12, "thinking spreads the glow")

        panel.setState(.idle)
        XCTAssertEqual(panel.buddy.accessibilityLabel(), "Ready")
        XCTAssertEqual(panel.buddy.glowRadius, 8)
    }

    // MARK: the island

    /// Built with the island's spring switched off. The open and close are animated in the app —
    /// the backdrop and the content move together under one `withAnimation` — but a transition in
    /// flight means the outgoing layer is still in the view tree, so an assertion that the mascot
    /// left the window would be racing the animation rather than testing anything.
    private func island() throws -> (NotchPanel, NSScreen) {
        let screen = try XCTUnwrap(NSScreen.main, "needs a display")
        let panel = NotchPanel(data: try data(), color: blue, screen: screen)
        panel.animatesIsland = false
        return (panel, screen)
    }

    private func island(_ geometry: NotchGeometry) throws -> NotchPanel {
        let panel = NotchPanel(data: try data(), color: blue, geometry: geometry)
        panel.animatesIsland = false
        return panel
    }

    /// A 14-inch MacBook Pro's built-in display.
    private let notched = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasHardwareNotch: true,
        notchWidth: 200,
        notchHeight: 32
    )

    /// A 1920 x 1080 display to the right of it, with a 24 pt menu-bar band and no notch.
    private let secondary = NotchGeometry.forScreen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1056),
        safeAreaTop: 0,
        leftAuxiliary: nil,
        rightAuxiliary: nil
    )

    func testTheIslandHangsFromTheTopOfTheScreenAboveTheMenuBar() throws {
        let (panel, screen) = try island()
        XCTAssertEqual(panel.level, .popUpMenu)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(
            panel.frame.width,
            NotchPanel.openWidth + IslandRootView.topCornerFlare * 2,
            "the window is the island plus its flare: the top corners curve outward past the body, "
                + "and a window exactly the body's width clips that curve away")
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testNothingIsOnShowUntilSomethingAsksForIt() throws {
        let (panel, _) = try island()
        XCTAssertEqual(panel.islandState, .collapsed)
        XCTAssertNil(panel.mascot.superview, "the face leaves the tree, which is what stops its ticker")
    }

    func testBeingBusyOpensTheCompactStripByItself() throws {
        let (panel, _) = try island()
        panel.setState(.listening)
        XCTAssertEqual(panel.islandState, .compact)
        XCTAssertEqual(panel.word, "Listening")
        XCTAssertEqual(panel.mascot.expression, .listening)
        XCTAssertNotNil(panel.mascot.superview)
        XCTAssertEqual(panel.rect(for: .compact).width, NotchPanel.compactWidth)
    }

    func testGoingIdleCollapsesTheStripOnceTheGraceHasPassed() throws {
        let (panel, screen) = try island()
        let now = CACurrentMediaTime()
        panel.setState(.listening)
        panel.setState(.idle)
        XCTAssertEqual(panel.islandState, .compact, "it does not snap shut the moment Saathi stops")
        let away = CGPoint(x: screen.frame.minX + 5, y: screen.frame.minY + 5)
        panel.pollHover(mouse: away, now: now + 1)
        XCTAssertEqual(panel.islandState, .collapsed)
        XCTAssertNil(panel.mascot.superview, "the face leaves the tree, which is what stops its ticker")
    }

    func testReachingTheTopOfTheScreenBringsTheIslandDown() throws {
        let (panel, screen) = try island()
        let atTheNotch = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 2)
        panel.pollHover(mouse: atTheNotch, now: CACurrentMediaTime())
        XCTAssertEqual(panel.islandState, .open)
        XCTAssertEqual(panel.rect(for: .open).width, NotchPanel.openWidth)
        XCTAssertNil(
            panel.mascot.superview,
            "the open panel is OpenClicky's Home tab, which has no face in it — the companion is "
                + "out on the desktop, or docked as a badge. The face shows in the compact strip")
        XCTAssertEqual(panel.rect(for: .open).maxY, screen.frame.maxY, accuracy: 0.5)
    }

    func testTheWordAndTheFaceFollowTheState() throws {
        let (panel, _) = try island()
        panel.setState(.thinking)
        XCTAssertEqual(panel.word, "Thinking")
        XCTAssertEqual(panel.mascot.expression, .thinking)
        XCTAssertEqual(panel.mascot.accessibilityLabel(), "Thinking")
    }

    /// A display change re-lays the island on whatever screen is main now. The change itself
    /// cannot be staged in a test, but the call the notification makes can.
    func testLayingTheIslandOutAgainOnTheSameScreenKeepsItAtTheTopOfThatScreen() throws {
        let (panel, screen) = try island()
        panel.moveTo(screen: screen)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(
            panel.frame.width,
            NotchPanel.openWidth + IslandRootView.topCornerFlare * 2,
            "the window is the island plus its flare: the top corners curve outward past the body, "
                + "and a window exactly the body's width clips that curve away")
        XCTAssertEqual(panel.islandState, .collapsed)
    }

    // MARK: the two kinds of display — the look the user rejected lived here

    func testOnADisplayWithoutANotchCollapsedIsNothingButTheHandle() throws {
        let panel = try island(secondary)
        panel.apply(.collapsed)
        XCTAssertFalse(panel.drawsIslandBackdrop, "no black pill under the menu bar")
        XCTAssertTrue(panel.contents.isHandleVisible)
        XCTAssertNil(panel.mascot.superview, "the face leaves the tree, which is what stops its ticker")
        XCTAssertFalse(panel.isContentVisible)
        XCTAssertEqual(panel.frame.maxY, 1080, accuracy: 0.5)
        XCTAssertEqual(panel.frame.midX, 1512 + 960, accuracy: 0.5)
    }

    func testWithNoMenuBarBandTheCollapsedIslandShowsNoHandle() throws {
        let hiddenMenuBar = NotchGeometry.forScreen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0,
            leftAuxiliary: nil,
            rightAuxiliary: nil
        )
        let panel = try island(hiddenMenuBar)
        panel.apply(.collapsed)
        XCTAssertFalse(panel.contents.isHandleVisible, "nowhere to sit but over the content")
        XCTAssertFalse(panel.drawsIslandBackdrop)
    }

    func testOnADisplayWithoutANotchTheIslandStillComesDownWhenYouReachForIt() throws {
        let panel = try island(secondary)
        panel.apply(.collapsed)
        panel.pollHover(mouse: CGPoint(x: 1512 + 960, y: 1079), now: CACurrentMediaTime())
        XCTAssertEqual(panel.islandState, .open)
        XCTAssertTrue(panel.drawsIslandBackdrop)
        XCTAssertFalse(panel.contents.isHandleVisible, "the handle gives way to the island")
        XCTAssertNil(panel.mascot.superview, "the open Home panel has no face in it")
    }

    func testOnANotchedDisplayCollapsedIsTheNotchItselfAndNoHandle() throws {
        let panel = try island(notched)
        panel.apply(.collapsed)
        XCTAssertTrue(panel.drawsIslandBackdrop, "black over black hardware: invisible")
        XCTAssertFalse(panel.contents.isHandleVisible)
        XCTAssertNil(panel.mascot.superview, "the face leaves the tree, which is what stops its ticker")
        XCTAssertEqual(panel.rect(for: .collapsed), notched.notchRect)
    }

    /// A `MascotView` tickers on a display link for as long as it is in a window, hidden or not,
    /// so the collapsed island takes it out of the view rather than hiding it.
    ///
    /// This used to be asserted through `mascot.isHidden`, which `apply` set by hand. That flag is
    /// gone: the island's open and close are a SwiftUI transition now, and hiding the view outright
    /// would make the face vanish instantly while the black was still springing shut. Leaving the
    /// tree is the guarantee that matters — it is what actually stops the ticker — so that is what
    /// these assertions check.
    func testACollapsedIslandTakesTheMascotOutOfTheWindowSoItStopsAnimating() throws {
        let (panel, _) = try island()
        panel.apply(.collapsed)
        XCTAssertNil(panel.mascot.window, "a hidden mascot in a window would go on ticking")
        XCTAssertNil(panel.mascot.superview)

        // The compact strip is the state that shows the face: the open panel is OpenClicky's Home
        // tab, and that panel has no face in it.
        panel.apply(.compact)
        XCTAssertTrue(panel.mascot.window === panel, "back in the island when the strip comes down")
        XCTAssertNotNil(panel.mascot.superview)

        panel.apply(.open)
        XCTAssertNil(panel.mascot.window, "Home has skill tiles where the face used to be")

        panel.apply(.collapsed)
        XCTAssertNil(panel.mascot.window)
    }

    // MARK: the three tabs, and how tall each one makes the island

    /// OpenClicky's `fullHeight` rule, and its three numbers. They are worth pinning because they
    /// are the kind of thing that gets nudged by a layout tweak and never noticed: the island is
    /// laid out from them, not from what its content happens to measure.
    func testEachTabOpensTheIslandToItsOwnHeight() {
        let band: CGFloat = 32
        XCTAssertEqual(NotchPanel.openHeight(for: .home, topBandHeight: band), 232,
                       "Home has a floor for the whole island: 32 + 195 is under it, so 232 wins")
        XCTAssertEqual(NotchPanel.openHeight(for: .agents, topBandHeight: band), band + 380)
        XCTAssertEqual(NotchPanel.openHeight(for: .setup, topBandHeight: band), band + 590,
                       "Settings is a scroll of sections, not two fields")
    }

    /// The Home floor is a floor, not a fixed height: a tall menu-bar band pushes past it.
    func testATallBandPushesHomePastItsFloor() {
        XCTAssertEqual(NotchPanel.openHeight(for: .home, topBandHeight: 50), 245)
    }

    func testSwitchingTabRelaysTheIslandAtTheNewTabsHeight() throws {
        let panel = try island(notched)
        panel.model.tab = .home
        panel.apply(.open)
        let home = panel.rect(for: .open).height

        panel.model.tab = .setup
        let settings = panel.rect(for: .open).height
        XCTAssertGreaterThan(settings, home, "Settings is the taller face")
        XCTAssertEqual(settings, notched.topBandHeight + NotchPanel.setupContentUnderBand)
        XCTAssertEqual(panel.rect(for: .open).width, NotchPanel.openWidth, "every tab is 512 wide")
    }

    /// Regression for the handle four hundred points down an external display. The island is laid
    /// out for a screen at Home's height and the handle placed against that window; the window is
    /// then grown for whichever tab is current, and the handle — in the window's own coordinates,
    /// measured from its bottom — stayed where the shorter window's top had been.
    func testTheHandleStaysInTheMenuBarWhateverHeightTheWindowGrowsTo() throws {
        let panel = try island(secondary)
        panel.model.tab = .setup   // the tallest face; the window grows to hold it
        panel.apply(.collapsed)
        XCTAssertEqual(
            panel.frame.height, secondary.topBandHeight + NotchPanel.setupContentUnderBand, accuracy: 0.5,
            "the window is sized for the current tab even while collapsed")
        XCTAssertTrue(panel.contents.isHandleVisible)
        let onScreen = panel.contents.handleFrame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        XCTAssertEqual(onScreen.midX, secondary.handleRect.midX, accuracy: 0.5)
        XCTAssertEqual(onScreen.maxY, 1080 - NotchGeometry.handleTopInset, accuracy: 0.5,
                       "tucked just under the top edge of the screen, not the top of some earlier window")
    }

    /// The other direction: a window that shrinks back for a shorter tab does so only after the
    /// spring has settled, and everything inside it was placed against the taller frame.
    func testTheContentStaysAtTheTopOnceTheWindowShrinksBackForAShorterTab() throws {
        let panel = try island(secondary)
        panel.model.tab = .setup
        panel.apply(.open)
        panel.model.tab = .home
        panel.apply(.collapsed)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: NotchPanel.springSettleDuration + 0.3))
        XCTAssertEqual(panel.frame.height, NotchPanel.homeTotalHeight, accuracy: 0.5, "shrunk back for Home")
        XCTAssertEqual(panel.hostingFrame.maxY, panel.frame.height, accuracy: 0.5,
                       "the hosted tree hangs from the top of the window it is now in")
        let onScreen = panel.contents.handleFrame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        XCTAssertEqual(onScreen.maxY, 1080 - NotchGeometry.handleTopInset, accuracy: 0.5)
    }

    func testOnlyTheWorkingStatesCountAsBusy() {
        XCTAssertTrue(NotchPanel.isBusy(.listening))
        XCTAssertTrue(NotchPanel.isBusy(.thinking))
        XCTAssertTrue(NotchPanel.isBusy(.speaking))
        XCTAssertTrue(NotchPanel.isBusy(.alert("no")))
        XCTAssertTrue(NotchPanel.isBusy(.showingStep(index: 1, total: 3)))
        XCTAssertTrue(NotchPanel.isBusy(.celebrating))
        XCTAssertTrue(NotchPanel.isBusy(.poweringDown), "the goodbye is worth showing")
        XCTAssertFalse(NotchPanel.isBusy(.idle))
        XCTAssertFalse(NotchPanel.isBusy(.asleep))
    }

    /// Quit used to collapse the island and then wait a second and a half in silence.
    func testPoweringDownShowsTheGoodbye() throws {
        let (panel, _) = try island()
        panel.setState(.poweringDown)
        XCTAssertEqual(panel.islandState, .compact)
        XCTAssertEqual(panel.word, "Bye")
        XCTAssertNotNil(panel.mascot.superview)
    }

    // MARK: the Home panel

    /// The empty panel the user rejected lived here: nothing drawn, and every click passes
    /// through to whatever is under the menu bar.
    func testCollapsedDrawsNothingAndPassesClicksThrough() throws {
        let (panel, _) = try island()
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isContentVisible)
    }

    /// Open is a real, clickable Home panel: 512 pt wide, and the pointer reaches its buttons.
    func testOpenIsAClickableFiveTwelveWideHomePanel() throws {
        let (panel, _) = try island()
        panel.apply(.open)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.isContentVisible)
        XCTAssertEqual(panel.bodyRect.width, NotchPanel.openWidth)
    }

    func testTheModelsStateFollowsSetStateAndSoDoesTheWord() throws {
        let (panel, _) = try island()
        panel.setState(.thinking)
        XCTAssertEqual(panel.model.state, .thinking)
        XCTAssertEqual(panel.word, "Thinking")

        panel.setState(.speaking)
        XCTAssertEqual(panel.model.state, .speaking)
        XCTAssertEqual(panel.word, "Speaking")
    }

    /// Home takes the keyboard for exactly as long as "Create a skill…" is open, and never just
    /// for being looked at.
    func testTheIslandTakesTheKeyboardForSetupAndForTheSkillComposerOnly() {
        XCTAssertTrue(NotchPanel.wantsKeyboard(state: .open, tab: .setup, isComposingSkill: false))
        XCTAssertTrue(NotchPanel.wantsKeyboard(state: .open, tab: .home, isComposingSkill: true))
        XCTAssertFalse(NotchPanel.wantsKeyboard(state: .open, tab: .home, isComposingSkill: false))
        XCTAssertFalse(NotchPanel.wantsKeyboard(state: .compact, tab: .home, isComposingSkill: true), "a strip has no field")
        XCTAssertFalse(NotchPanel.wantsKeyboard(state: .collapsed, tab: .setup, isComposingSkill: false))
    }
}
