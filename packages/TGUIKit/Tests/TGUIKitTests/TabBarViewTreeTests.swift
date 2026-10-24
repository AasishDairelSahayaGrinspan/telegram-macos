import XCTest
import AppKit
@testable import TGUIKit

private final class TestBadgeNode: Node {
    init() {
        let view = View(frame: NSMakeRect(0, 0, 10, 10))
        view.backgroundColor = .systemRed
        super.init(view)
    }

    override func update() {
        if let view, let superview = view.superview {
            view.setFrameOrigin(NSMakePoint(floor(superview.frame.width / 2) + 4, 4))
        }
    }
}

private final class TabSelectionDelegate: TabViewDelegate {
    var changes: [Int] = []
    var scrollCount = 0

    func didChange(selected item: TabItem, index: Int) {
        changes.append(index)
    }

    func scrollup() {
        scrollCount += 1
    }
}

private final class CustomTabIcon: View {
    var selected = false
}

private final class CustomTabItem: TabItem {
    override func makeView() -> NSView {
        return CustomTabIcon(frame: NSMakeRect(0, 0, 30, 30))
    }

    override func setSelected(_ selected: Bool, for view: NSView, animated: Bool) {
        (view as? CustomTabIcon)?.selected = selected
    }
}

final class TabBarViewTreeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func makeTab(badge: Bool = false, controller: ViewController = ViewController()) -> TabItem {
        controller.bar = .init(height: 0)
        return TabItem(image: testImage(CGSize(width: 24, height: 24)), selectedImage: testImage(CGSize(width: 24, height: 24)), controller: controller, subNode: badge ? TestBadgeNode() : nil)
    }

    private func makeBar(width: CGFloat = 333, selected: Int = 0) -> TabBarView {
        let bar = TabBarView(frame: NSMakeRect(0, 0, width, 48))
        for index in 0 ..< 4 {
            bar.addTab(makeTab(badge: index == 2))
        }
        bar.setSelectedIndex(selected, respondToDelegate: false, animated: false)
        return bar
    }

    private func center(_ bar: TabBarView, _ index: Int) -> NSPoint {
        let frame = bar.control(for: index).frame
        return NSMakePoint(frame.midX, frame.midY)
    }

    func testCapsuleFloatsInsideItsPaneAndCapsItsWidth() {
        XCTAssertEqual(FloatingTabBarLayout.frame(in: NSMakeSize(380, 700)), NSMakeRect(20, 636, 340, 48))
        XCTAssertEqual(FloatingTabBarLayout.frame(in: NSMakeSize(800, 700)), NSMakeRect(150, 636, 500, 48))
        XCTAssertEqual(FloatingTabBarLayout.frame(in: .zero).width, 0)
    }

    func testThreeAndFourTabsFillTheCapsuleWithoutPixelGaps() {
        for width in [CGFloat(280), 333, 401] {
            let bar = makeBar(width: width)
            for count in [4, 3] {
                if count == 3 {
                    bar.removeTab(at: 1)
                }
                XCTAssertEqual(bar.itemControls.count, count)
                XCTAssertEqual(bar.itemControls.first?.frame.minX, 4)
                XCTAssertEqual(bar.itemControls.last?.frame.maxX, width - 4)
                for (index, control) in bar.itemControls.enumerated() {
                    XCTAssertEqual(control.frame.height, 40)
                    XCTAssertEqual(control.subviews.first!.frame.midX, control.bounds.midX, accuracy: 0.5)
                    XCTAssertEqual(control.subviews.first!.frame.midY, control.bounds.midY, accuracy: 0.5)
                    if index > 0 {
                        XCTAssertEqual(bar.itemControls[index - 1].frame.maxX, control.frame.minX)
                    }
                }
            }
        }
    }

    func testIconsAndBadgesStayAttachedWhenResizing() {
        let bar = makeBar(selected: 2)
        let icon = bar.control(for: 2).subviews[0]
        let badge = bar.control(for: 2).subviews[1]
        bar.setFrameSize(NSMakeSize(401, 48))
        XCTAssertTrue(bar.control(for: 2).subviews[0] === icon)
        XCTAssertTrue(bar.control(for: 2).subviews[1] === badge)
        XCTAssertEqual(bar.selectionFrame.midX, bar.control(for: 2).frame.midX)
        XCTAssertEqual(badge.frame.minX, floor(bar.control(for: 2).frame.width / 2) + 4)
    }

    func testDragPreviewsWithoutSwitchingAndCommitsOnceOnRelease() {
        let bar = makeBar()
        let delegate = TabSelectionDelegate()
        bar.delegate = delegate
        bar.beginSelection(at: center(bar, 0))
        bar.updateSelection(at: center(bar, 3))
        XCTAssertEqual(bar.selectedIndex, 0)
        XCTAssertTrue(bar.control(for: 3).isSelected)
        XCTAssertTrue(delegate.changes.isEmpty)
        bar.endSelection(at: center(bar, 3))
        XCTAssertEqual(bar.selectedIndex, 3)
        XCTAssertEqual(delegate.changes, [3])
        XCTAssertFalse(bar.isTrackingSelection)
        XCTAssertEqual(bar.selectionFrame.height, 40)
    }

    func testLensFollowsFractionalDragAndClampsAtTheEnds() {
        let bar = makeBar()
        let start = center(bar, 0)
        let next = center(bar, 1)
        bar.beginSelection(at: start)
        bar.updateSelection(at: NSMakePoint((start.x + next.x) / 2, start.y))
        XCTAssertEqual(bar.selectionFrame.midX, (start.x + next.x) / 2, accuracy: 0.001)
        bar.updateSelection(at: NSMakePoint(-500, start.y))
        XCTAssertEqual(bar.selectionFrame.midX, start.x)
        bar.updateSelection(at: NSMakePoint(1000, start.y))
        XCTAssertEqual(bar.selectionFrame.midX, center(bar, 3).x)
        bar.cancelSelection(animated: false)
    }

    func testReselectingScrollsUpAndCancellationDoesNot() {
        let bar = makeBar(selected: 2)
        let delegate = TabSelectionDelegate()
        bar.delegate = delegate
        bar.beginSelection(at: center(bar, 2))
        bar.endSelection(at: center(bar, 2))
        XCTAssertEqual(delegate.scrollCount, 1)
        bar.beginSelection(at: center(bar, 0))
        bar.cancelSelection(animated: false)
        bar.endSelection(at: center(bar, 0))
        XCTAssertEqual(bar.selectedIndex, 2)
        XCTAssertEqual(delegate.scrollCount, 1)
        XCTAssertTrue(delegate.changes.isEmpty)
        XCTAssertTrue(bar.control(for: 2).isSelected)
    }

    func testHidingResizingAndChangingItemsCancelTheGesture() {
        let bar = makeBar(selected: 2)
        bar.beginSelection(at: center(bar, 0))
        bar.isHidden = true
        XCTAssertFalse(bar.isTrackingSelection)
        bar.isHidden = false
        bar.beginSelection(at: center(bar, 0))
        bar.setFrameSize(NSMakeSize(401, 48))
        XCTAssertFalse(bar.isTrackingSelection)
        bar.beginSelection(at: center(bar, 0))
        bar.removeTab(at: 1)
        XCTAssertFalse(bar.isTrackingSelection)
        XCTAssertEqual(bar.selectedIndex, 1)
    }

    func testCallsInsertionAndRemovalPreserveTheSelectedController() {
        let bar = makeBar(selected: 3)
        let settings = bar.tab(at: 3).controller
        let settingsControl = bar.control(for: 3)
        bar.removeTab(at: 1)
        XCTAssertEqual(bar.selectedIndex, 2)
        XCTAssertTrue(bar.tab(at: 2).controller === settings)
        XCTAssertTrue(bar.control(for: 2) === settingsControl)
        bar.insertTab(makeTab(), at: 1)
        XCTAssertEqual(bar.selectedIndex, 3)
        XCTAssertTrue(bar.tab(at: 3).controller === settings)
    }

    func testRemovingSelectedCallsSelectsChatsAndNotifiesTheDelegate() {
        let bar = makeBar(selected: 1)
        let chats = bar.tab(at: 2).controller
        let delegate = TabSelectionDelegate()
        bar.delegate = delegate
        bar.removeTab(at: 1)
        XCTAssertTrue(bar.tab(at: bar.selectedIndex).controller === chats)
        XCTAssertEqual(delegate.changes, [1])
    }

    func testInvalidSelectionAndEmptyBarsAreSafe() {
        let bar = makeBar(selected: 2)
        for index in [-1, 4, 50] {
            bar.setSelectedIndex(index, respondToDelegate: true, animated: false)
        }
        XCTAssertEqual(bar.selectedIndex, 2)
        for _ in 0 ..< 4 {
            bar.removeTab(at: 0)
        }
        bar.setSelectedIndex(0, respondToDelegate: true, animated: false)
        bar.beginSelection(at: .zero)
        XCTAssertTrue(bar.isEmpty)
        XCTAssertFalse(bar.isTrackingSelection)
        XCTAssertNil(bar.hitTest(.zero))
    }

    func testCapsuleMarginsPassThroughAndIconsHitTheirControls() {
        let parent = View(frame: NSMakeRect(0, 0, 380, 700))
        let bar = makeBar(width: 340)
        bar.frame = FloatingTabBarLayout.frame(in: parent.frame.size)
        parent.addSubview(bar)
        XCTAssertNil(bar.hitTest(NSMakePoint(10, 670)))
        XCTAssertNil(bar.hitTest(NSMakePoint(20, 636)))
        for index in 0 ..< bar.count {
            XCTAssertTrue(bar.hitTest(parent.convert(center(bar, index), from: bar)) === bar.control(for: index))
        }
    }

    func testReplacementUsesTheCustomIconAndPreservesTheBadgeAndTitle() {
        let bar = TabBarView(frame: NSMakeRect(0, 0, 340, 48))
        let original = makeTab(badge: true)
        let item = CustomTabItem(image: original.image, selectedImage: original.selectedImage, controller: original.controller, subNode: original.subNode)
        item.accessibilityTitle = "Settings"
        bar.addTab(item)
        let icon = bar.control(for: 0).subviews[0] as! CustomTabIcon
        let badge = bar.control(for: 0).subviews[1]
        let replacement = CustomTabItem(image: original.image, selectedImage: original.selectedImage, controller: original.controller, subNode: original.subNode)
        replacement.accessibilityTitle = "Updated Settings"
        bar.replaceTab(replacement, at: 0)
        XCTAssertTrue(bar.control(for: 0).subviews[0] === icon)
        XCTAssertTrue(bar.control(for: 0).subviews[1] === badge)
        XCTAssertTrue(icon.selected)
        XCTAssertEqual(bar.control(for: 0).accessibilityLabel(), "Updated Settings")
        XCTAssertEqual(bar.control(for: 0).toolTip, "Updated Settings")
    }

    func testReplacementRemovesAnObsoleteBadge() {
        let bar = makeBar(selected: 2)
        let badge = bar.control(for: 2).subviews[1]
        bar.replaceTab(makeTab(), at: 2)
        XCTAssertNil(badge.superview)
        XCTAssertEqual(bar.control(for: 2).subviews.count, 1)
    }

    func testControllerContentFillsThePaneAndReceivesComposableInsets() {
        let controller = TabBarController()
        controller.bar = .init(height: 0)
        controller._frameRect = NSMakeRect(0, 0, 380, 700)
        controller.loadViewIfNeeded()
        let child = ViewController()
        child.bar = .init(height: 0)
        controller.add(tab: makeTab(controller: child))
        controller.select(index: 0)
        XCTAssertEqual(child.view.frame, controller.bounds)
        XCTAssertEqual(child.containerContentInsets.bottom, 64)
        controller.updateContainerContentInsets(NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0), transition: .immediate)
        XCTAssertEqual(child.containerContentInsets.bottom, 76)
        controller.hideTabView(true)
        XCTAssertEqual(child.view.frame, controller.bounds)
        XCTAssertEqual(child.containerContentInsets.bottom, 12)
        controller.hideTabView(false)
        XCTAssertEqual(child.containerContentInsets.bottom, 76)
    }

    func testAccessibilityPressSelectsOnceAndReportsSelection() {
        let bar = makeBar()
        let delegate = TabSelectionDelegate()
        bar.delegate = delegate
        XCTAssertEqual(bar.accessibilityRole(), .tabGroup)
        XCTAssertEqual(bar.control(for: 2).accessibilityRole(), .radioButton)
        XCTAssertTrue(bar.control(for: 2).accessibilityPerformPress())
        XCTAssertEqual(delegate.changes, [2])
        XCTAssertTrue(bar.control(for: 2).isAccessibilitySelected())
        XCTAssertFalse(bar.control(for: 0).isAccessibilitySelected())
    }

    func testQuickMenuHighlightDoesNotChangeTabSelectionOrLeaveAnAccentedIcon() {
        let bar = makeBar(selected: 3)
        bar.control(for: 3).isSelected = false
        bar.setSelectedIndex(2, respondToDelegate: false, animated: false)
        let previousIcon = bar.control(for: 3).subviews[0] as! ImageView
        XCTAssertTrue(previousIcon.image === bar.tab(at: 3).image)
        bar.control(for: 1).isSelected = true
        XCTAssertFalse(bar.control(for: 1).isAccessibilitySelected())
        XCTAssertTrue(bar.control(for: 2).isAccessibilitySelected())
        XCTAssertEqual(bar.selectedIndex, 2)
    }

    func testWindowResignationCancelsAPendingSelection() {
        let bar = makeBar(selected: 2)
        let window = NSWindow(contentRect: bar.bounds, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = bar
        bar.beginSelection(at: center(bar, 0))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(bar.isTrackingSelection)
        XCTAssertEqual(bar.selectedIndex, 2)
    }

    func testContextActionKeepsItsItemAfterInsertion() {
        let bar = makeBar()
        var calls = 0
        let original = makeTab()
        let item = TabItem(image: original.image, selectedImage: original.selectedImage, controller: original.controller, longHoverHandler: { _ in calls += 1 })
        bar.addTab(item)
        bar.insertTab(makeTab(), at: 1)
        bar.control(for: 5).send(event: .RightDown)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(bar.selectedIndex, 0)
    }

    func testControlClickDoesNotSelectWhenTheModifierIsReleasedFirst() throws {
        let bar = makeBar()
        let original = makeTab()
        var contextActions = 0
        bar.addTab(TabItem(image: original.image, selectedImage: original.selectedImage, controller: original.controller, longHoverHandler: { _ in contextActions += 1 }))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        bar.control(for: 4).mouseDown(with: down)
        bar.control(for: 4).mouseUp(with: up)
        XCTAssertEqual(contextActions, 1)
        XCTAssertEqual(bar.selectedIndex, 0)
        XCTAssertFalse(bar.isTrackingSelection)
    }

    func testNavigationAndSearchSectionsForwardInsetsBeforeLoading() {
        let first = ViewController()
        let second = ViewController()
        let sections = SectionViewController(sections: [SectionControllerItem(title: { "First" }, controller: first), SectionControllerItem(title: { "Second" }, controller: second)])
        let window = Window(contentRect: NSMakeRect(0, 0, 380, 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let navigation = NavigationViewController(sections, window)
        navigation.cleanupAfterDeinit = false
        let insets = NSEdgeInsets(top: 0, left: 0, bottom: 56, right: 0)
        navigation.updateContainerContentInsets(insets, transition: .immediate)
        XCTAssertEqual(first.containerContentInsets.bottom, 56)
        XCTAssertEqual(second.containerContentInsets.bottom, 56)
        XCTAssertFalse(first.isLoaded())
        XCTAssertFalse(second.isLoaded())
        navigation.updateContainerContentInsets(NSEdgeInsets(), transition: .immediate)
        XCTAssertEqual(first.containerContentInsets.bottom, 0)
        XCTAssertEqual(second.containerContentInsets.bottom, 0)
    }
}
