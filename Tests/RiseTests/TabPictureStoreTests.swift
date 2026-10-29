import AppKit
import XCTest
import RiseCore
@testable import Rise

@MainActor final class TabPictureStoreTests: XCTestCase {
    private func picture() -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 20))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 20).fill(); image.unlockFocus()
        return image
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(1300)) }

    func testAPictureComesBackAtTheNextLaunchWhileTheTabIsWhereItWas() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TabPictures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = SavedTab(url: "https://example.com/story", title: "Story")
        let tab = BrowserTab(saved: saved)
        tab.thumbnail = picture()
        let store = TabPictureStore(folder: folder)
        store.keep(tab)
        await settle()

        let relaunched = TabPictureStore(folder: folder)
        XCTAssertNotNil(relaunched.picture(for: BrowserTab(saved: saved)), "The tab gets its picture back without loading")
        let moved = SavedTab(id: saved.id, url: "https://example.com/elsewhere", title: "Elsewhere")
        XCTAssertNil(relaunched.picture(for: BrowserTab(saved: moved)), "A picture of another address isn't shown")
    }

    func testPicturesOfClosedTabsAreLetGo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TabPictures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = BrowserTab(saved: SavedTab(url: "https://example.com/kept", title: "Kept"))
        let closed = BrowserTab(saved: SavedTab(url: "https://example.com/closed", title: "Closed"))
        let store = TabPictureStore(folder: folder)
        for tab in [kept, closed] { tab.thumbnail = picture(); store.keep(tab) }
        await settle()
        store.keepOnly([kept.id])
        await settle()

        let relaunched = TabPictureStore(folder: folder)
        XCTAssertNotNil(relaunched.picture(for: kept))
        XCTAssertNil(relaunched.picture(for: closed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(closed.id.uuidString + ".jpg").path))
    }
}
