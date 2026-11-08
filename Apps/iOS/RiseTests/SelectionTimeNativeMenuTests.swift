import XCTest
import UIKit
@testable import RiseiOS

final class SelectionTimeNativeMenuTests: XCTestCase {
    @MainActor private func fixture(timeCount: Int = 1, includeReminder: Bool = true,
                                    invoked: @escaping (Int) -> Void = { _ in }) -> (UIMenu, [UIAction], UIAction) {
        let copy = UIAction(title: "Copy “18:00”", image: UIImage(systemName: "doc.on.doc")) { _ in }
        let fallback = UIAction(title: "Add to Calendar") { _ in XCTFail("The fallback must be replaced by the native action") }
        let replace = SelectionTimeMenu.replaceAction(in: nil)
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, options: .displayInline, children:
            (0..<timeCount).map { _ in UIMenu(title: "18:00 (in 1 hr)", children: [copy, replace, fallback]) })
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
        XCTAssertEqual(time.children.count, 5)
        XCTAssertTrue(time.children.first === copy)
        XCTAssertEqual(time.children[1].title, "Replace on Page")
        for (index, child) in time.children.dropFirst(2).enumerated() {
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
        XCTAssertEqual(rise.children.compactMap { ($0 as? UIMenu)?.children.count }, [5, 5])
    }

    @MainActor func testAZoneOnlySnapshotDoesNotAcquireNativeAppointmentActions() {
        let (root, _, _) = fixture()
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, children: SelectionTimeMenu.elements(for: "UTC+14:00", in: nil))
        let input = root.replacingChildren([rise] + root.children.dropFirst())
        XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: input) === input)
    }

    @MainActor func testAnEventKeepsRisesFilledInActionsAndDropsTheSystemsDateSection() throws {
        let (root, _, _) = fixture()
        let text = "Event details\nDate: Tuesday, November 3, 2026\nTime: 13:30 - 20:30\nLocation: Corner Corner, London"
        let elements = SelectionTimeMenu.elements(for: text, in: nil)
        let event = try XCTUnwrap(elements.first as? UIMenu)
        XCTAssertEqual(event.identifier, SelectionTimeMenu.eventIdentifier)
        XCTAssertEqual(event.children.map(\.title), ["Add to Calendar", "Add to Reminders", "Show in Calendar"])
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, options: .displayInline, children: elements)
        // A day without a zone: the system's section has no conversion heading.
        let dates = try XCTUnwrap(root.children.last as? UIMenu)
        let plain = dates.replacingChildren(dates.children.filter { !(($0 as? UIAction)?.identifier.rawValue.contains("Conversion") ?? false) })
        let input = root.replacingChildren([rise, root.children[1], plain])
        let result = SelectionTimeNativeMenu.relocatingDateActions(in: input)
        XCTAssertTrue(result.children.first === rise, "Rise's actions, which fill in the place and title, are kept")
        XCTAssertEqual(result.children.count, 2)
        XCTAssertEqual((result.children.last as? UIMenu)?.children.map(\.title), ["Look Up"])
        // Without Rise's event, a plain date's section is the system's own and stays.
        let withoutEvent = root.replacingChildren([UIMenu(identifier: SelectionTimeMenu.menuIdentifier, children: []), root.children[1], plain])
        XCTAssertTrue(SelectionTimeNativeMenu.relocatingDateActions(in: withoutEvent) === withoutEvent)
    }

    @MainActor func testATimeInAnotherZoneKeepsItsConvertedItemWithTheEventsActions() throws {
        let menus = SelectionTimeMenu.elements(for: "Launch call, Wed 4 Nov 2026 9:00 AM – 10:00 AM PST", in: nil).compactMap { $0 as? UIMenu }
        XCTAssertEqual(menus.count, 1)
        XCTAssertEqual(menus.first?.identifier, SelectionTimeMenu.eventIdentifier)
        XCTAssertTrue(menus.first?.children.first?.title.hasPrefix("Copy “") == true)
        XCTAssertEqual(menus.first?.children.count, 5)
    }
}
