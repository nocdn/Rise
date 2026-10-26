import XCTest
import UIKit
@testable import RiseiOS

final class SelectionTimeNativeMenuTests: XCTestCase {
    @MainActor private func fixture(timeCount: Int = 1, includeReminder: Bool = true,
                                    invoked: @escaping (Int) -> Void = { _ in }) -> (UIMenu, [UIAction], UIAction) {
        let copy = UIAction(title: "Copy “18:00”", image: UIImage(systemName: "doc.on.doc")) { _ in }
        let fallback = UIAction(title: "Add to Calendar") { _ in XCTFail("The fallback must be replaced by the native action") }
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, options: .displayInline, children:
            (0..<timeCount).map { _ in UIMenu(title: "18:00 · in 1 hr", children: [copy, fallback]) })
        let kinds = ["DDCreateEventAction", "DDCreateReminderAction", "DDShowCalendarAction"]
        let titles = ["Zum Kalender hinzufügen", "Zu Erinnerungen hinzufügen", "Im Kalender anzeigen"]
        let images = ["calendar", "list.bullet", "calendar.day.timeline.left"]
        let actions = kinds.enumerated().compactMap { index, kind -> UIAction? in
            guard includeReminder || index != 1 else { return nil }
            return UIAction(title: titles[index], image: UIImage(systemName: images[index]),
                            identifier: .init("com.apple.datadetectors.\(kind).\(UUID())")) { _ in invoked(index) }
        }
        let conversion = UIAction(title: "23. Okt. 2026 um 18:00", identifier:
            .init("com.apple.datadetectors.DDTimeZoneConversionAction.\(UUID())"), attributes: .disabled) { _ in }
        // UIKit uses .lookup for both groups. Removing that identifier wholesale would
        // also remove Look Up / Translate / Search Web, which must remain unchanged.
        let lookup = UIMenu(identifier: .lookup, options: .displayInline, children: [UIAction(title: "Look Up") { _ in }])
        let dates = UIMenu(identifier: .lookup, options: .displayInline, children: [conversion] + actions)
        return (UIMenu(children: [rise, lookup, dates]), actions, copy)
    }

    @MainActor func testMovesOriginalNativeActionsAndKeepsIconsHandlersAndOtherLookupActions() throws {
        var invoked: [Int] = []
        let (root, actions, copy) = fixture { invoked.append($0) }
        let result = SelectionTimeNativeMenu.relocatingDateActions(in: root)
        let rise = try XCTUnwrap(result.children.first as? UIMenu)
        let time = try XCTUnwrap(rise.children.first as? UIMenu)
        XCTAssertEqual(time.children.count, 4)
        XCTAssertTrue(time.children.first === copy)
        for (index, child) in time.children.dropFirst().enumerated() {
            let moved = try XCTUnwrap(child as? UIAction)
            XCTAssertTrue(moved === actions[index])
            XCTAssertTrue(moved.image === actions[index].image)
            let button = UIButton(); button.addAction(moved, for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(invoked, [0, 1, 2])
        XCTAssertEqual(result.children.count, 2)
        XCTAssertEqual((result.children.last as? UIMenu)?.children.map(\.title), ["Look Up"])
        XCTAssertEqual(root.children.count, 3, "The input menu remains immutable")
        XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: result) === result, "Applying twice must be a no-op")
    }

    @MainActor func testPreservesIncompleteOrAmbiguousNativeMenusRatherThanLosingActions() {
        for (count, reminder) in [(1, false), (2, true)] {
            let (root, _, _) = fixture(timeCount: count, includeReminder: reminder)
            XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: root) === root)
        }
        let (root, _, _) = fixture()
        let unrelated = root.replacingChildren(Array(root.children.dropFirst()))
        XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: unrelated) === unrelated)
        let beforeDataDetection = root.replacingChildren(Array(root.children.dropLast()))
        XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: beforeDataDetection) === beforeDataDetection)
    }

    @MainActor func testKeepsUnrelatedActionsInTheDateSection() throws {
        let (root, _, _) = fixture()
        let dates = try XCTUnwrap(root.children.last as? UIMenu)
        let other = UIAction(title: "Other system action") { _ in }
        let mixed = root.replacingChildren(Array(root.children.dropLast()) + [dates.replacingChildren(dates.children + [other])])
        let result = SelectionTimeNativeMenu.relocatingDateActions(in: mixed)
        XCTAssertTrue((result.children.last as? UIMenu)?.children.first === other)
        XCTAssertEqual((result.children.last as? UIMenu)?.children.count, 1)
    }

    @MainActor func testMultipleDatesKeepTheirOwnActionsAndLoseTheDuplicateSystemSection() throws {
        let (root, _, _) = fixture()
        let times = SelectionTimeMenu.elements(for: "10am PST and 11am CET", in: nil)
        XCTAssertEqual(times.count, 2)
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, children: times)
        let input = root.replacingChildren([rise] + root.children.dropFirst())
        let result = SelectionTimeNativeMenu.relocatingDateActions(in: input)
        XCTAssertEqual(result.children.count, 2)
        XCTAssertTrue(result.children.first === rise, "Each date retains its own captured instant")
        XCTAssertEqual(rise.children.compactMap { ($0 as? UIMenu)?.children.count }, [4, 4])
    }

    @MainActor func testAZoneOnlySnapshotDoesNotAcquireNativeAppointmentActions() {
        let (root, _, _) = fixture()
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, children: SelectionTimeMenu.elements(for: "UTC+14:00", in: nil))
        let input = root.replacingChildren([rise] + root.children.dropFirst())
        XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: input) === input)
    }
}
