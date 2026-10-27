import EventKit
import XCTest
@testable import RiseCore

@MainActor final class SelectionItemReceiptTests: XCTestCase {
    func testUndoRedoWritesOnceAndRenewsTheTenSecondWindow() throws {
        var time: TimeInterval = 100, count = 1
        let undo = SelectionItemUndo(now: { time }, remove: { count -= 1 }, restore: { count += 1 })
        time = 109.9
        XCTAssertTrue(try undo.undo()); XCTAssertEqual(count, 0)
        XCTAssertFalse(try undo.undo(), "Holding Command-Z cannot delete twice")
        XCTAssertEqual(undo.remaining, 10, accuracy: 0.001)
        time = 119.8
        XCTAssertTrue(try undo.redo()); XCTAssertEqual(count, 1)
        XCTAssertFalse(try undo.redo(), "Holding Redo cannot create duplicates")
        XCTAssertTrue(try undo.undo()); XCTAssertTrue(try undo.redo()); XCTAssertEqual(count, 1)
    }
    func testExpiredActionsDoNotWrite() throws {
        var time: TimeInterval = 0, writes = 0
        let undo = SelectionItemUndo(now: { time }, remove: { writes += 1 }, restore: { writes += 1 })
        time = 10
        XCTAssertFalse(undo.canUndo); XCTAssertFalse(try undo.undo()); XCTAssertEqual(writes, 0)
        time = 0
        XCTAssertTrue(try undo.undo())
        time = 10
        XCTAssertFalse(undo.canRedo); XCTAssertFalse(try undo.redo()); XCTAssertEqual(writes, 1)
    }
    func testAFailedWritePreservesTheActionAndDeadline() throws {
        enum Failure: Error { case write }
        var fails = true, time: TimeInterval = 0
        let undo = SelectionItemUndo(now: { time }, remove: { if fails { throw Failure.write } }, restore: { if fails { throw Failure.write } })
        time = 4
        XCTAssertThrowsError(try undo.undo()); XCTAssertTrue(undo.canUndo); XCTAssertEqual(undo.remaining, 6)
        fails = false; XCTAssertTrue(try undo.undo())
        fails = true; time = 5
        XCTAssertThrowsError(try undo.redo()); XCTAssertTrue(undo.canRedo); XCTAssertEqual(undo.remaining, 9)
    }
    func testRedoDraftPreservesEventEditsAndSourceURLInANewObject() throws {
        let store = EKEventStore(), event = EKEvent(eventStore: store)
        event.title = "Changed title"; event.location = "Changed venue"; event.notes = "Original selection"
        event.startDate = Date(timeIntervalSince1970: 1_793_709_000); event.endDate = event.startDate.addingTimeInterval(7200)
        event.timeZone = TimeZone(identifier: "America/Los_Angeles"); event.isAllDay = false
        event.url = URL(string: "https://mail.google.com/mail/u/0/#inbox/mail-id")
        event.addAlarm(EKAlarm(relativeOffset: -900))
        let draft = SelectionItemDraft(event)
        event.title = "Later invalidated object"
        let fresh = try XCTUnwrap(draft.makeItem(in: store) as? EKEvent)
        XCTAssertFalse(fresh === event); XCTAssertEqual(fresh.title, "Changed title")
        XCTAssertEqual(fresh.location, "Changed venue"); XCTAssertEqual(fresh.notes, "Original selection")
        XCTAssertEqual(fresh.startDate, event.startDate); XCTAssertEqual(fresh.endDate, event.endDate)
        XCTAssertEqual(fresh.timeZone, event.timeZone); XCTAssertEqual(fresh.url, event.url)
        XCTAssertEqual(fresh.alarms?.first?.relativeOffset, -900)
    }
    func testRedoDraftPreservesReminderDueTimeURLAndAlarm() throws {
        let store = EKEventStore(), item = EKReminder(eventStore: store)
        item.title = "Reminder"; item.url = URL(string: "https://mail.google.com/mail/u/0/#inbox/mail-id")
        item.notes = "Venue\n\nSelected text"; item.priority = 5
        item.dueDateComponents = DateComponents(calendar: .current, year: 2026, month: 11, day: 3, hour: 14, minute: 30)
        item.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_793_709_000)))
        let restored = try XCTUnwrap(SelectionItemDraft(item).makeItem(in: store) as? EKReminder)
        XCTAssertEqual(restored.url, item.url); XCTAssertEqual(restored.notes, item.notes)
        XCTAssertEqual(restored.dueDateComponents, item.dueDateComponents); XCTAssertEqual(restored.priority, 5)
        XCTAssertEqual(restored.alarms?.first?.absoluteDate, item.alarms?.first?.absoluteDate)
    }
    func testItemLinksUseLocalIdentityAndEncodeItAsOnePathComponent() throws {
        let date = Date(timeIntervalSince1970: 0)
        let url = try XCTUnwrap(SelectionItemReceipt.eventURL(identifier: "local/id?x#%", start: date))
        XCTAssertEqual(url.scheme, "ical"); XCTAssertEqual(url.host, "ekevent")
        XCTAssertTrue(url.absoluteString.contains("/19700101T000000Z/local%2Fid%3Fx%23%25?"))
        let id = "CA43FC24-7204-4736-BFBA-452D1E1D03CF"
        XCTAssertEqual(SelectionItemReceipt.reminderURL(identifier: "x-apple-reminder://\(id)")?.absoluteString,
                       "x-apple-reminderkit://REMCDReminder/\(id)")
        XCTAssertEqual(SelectionItemReceipt.reminderURL(identifier: id)?.lastPathComponent, id)
        XCTAssertNil(SelectionItemReceipt.reminderURL(identifier: "not-an-id"))
        XCTAssertNil(SelectionItemReceipt.eventURL(identifier: "", start: date))
    }
}
