import XCTest
import UIKit
import CloudKit
@testable import RiseiOS

final class TabSyncTests: XCTestCase {
    @MainActor func testSettingsPanelSurvivesRapidNavigationAndPersistsTheSyncPreference() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseSyncSettings-\(UUID())")
        let suite = "RiseSyncSettings-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let browser = BrowserViewController(startURL: nil, sessionStore: store, tabSync: sync)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = browser; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        browser.view.layoutIfNeeded()
        let bar = browser.bottomBar
        XCTAssertTrue(sync.isEnabled)
        XCTAssertTrue(bar.appSettings.syncRow.toggle.isOn)
        for _ in 0..<3 {
            bar.moreButton.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(50))
            bar.menu.siteSettingsButton.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(50))
            bar.siteSettings.appSettingsRow.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(bar.panel, .appSettings)
            XCTAssertEqual(bar.appSettings.alpha, 1)
            XCTAssertGreaterThan(bar.bounds.height, BottomBar.siteSettingsHeight(width: bar.bounds.width, safeBottom: window.safeAreaInsets.bottom))
            for hidden in [bar.home, bar.menu, bar.siteSettings, bar.search, bar.find] {
                XCTAssertEqual(hidden.alpha, 0)
                XCTAssertTrue(hidden.accessibilityElementsHidden)
            }
            XCTAssertEqual(bar.appSettings.syncRow.toggle.onTintColor, SiteSettingsPanel.switchBlue)
            XCTAssertNotNil(MenuIcons.syncTabs)
            XCTAssertTrue(bar.appSettings.syncRow.frame.maxY < bar.appSettings.bounds.height)
            bar.appSettings.closeButton.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(50))
            bar.siteSettings.appSettingsRow.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(bar.siteSettings.alpha, 0)
            browser.closePanel(); try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(bar.home.alpha, 1)
            XCTAssertEqual(bar.appSettings.alpha, 0)
        }
        bar.moreButton.sendActions(for: .primaryActionTriggered)
        browser.openSiteSettings(); browser.openAppSettings()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "Rise Settings iCloud sync"; screenshot.lifetime = .keepAlways; add(screenshot)
        bar.appSettings.syncRow.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertFalse(bar.appSettings.syncRow.toggle.isOn)
        let restored = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        XCTAssertFalse(restored.isEnabled)
        bar.appSettings.syncRow.toggle.setOn(true, animated: false)
        bar.appSettings.syncRow.toggle.sendActions(for: .valueChanged)
        XCTAssertTrue(sync.isEnabled)
        XCTAssertEqual(sync.status, .unavailable)
    }

    @MainActor func testRemoteChangesWaitForThePanelAndPreserveLocalSelection() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseSyncAdapter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let a = MobileBrowserSession.Tab(url: nil, title: "A"), b = MobileBrowserSession.Tab(url: nil, title: "B")
        store.save(.init(tabs: [a, b], selectedTabID: b.id)); store.flush()
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), cloudAvailable: false)
        let browser = BrowserViewController(sessionStore: store, tabSync: sync)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = browser; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        browser.view.layoutIfNeeded()
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, b.id])
        XCTAssertEqual(browser.tabs[browser.tabIndex].id, b.id)
        browser.bottomBar.moreButton.sendActions(for: .primaryActionTriggered)
        let c = SharedBrowserTab(id: UUID(), url: nil, title: "Remote tab")
        let incoming = [c, SharedBrowserTab(id: b.id, url: nil, title: "Updated B")]
        sync.capture(incoming)
        sync.onTabsChange?(incoming)
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, b.id], "An open panel keeps its current page until the transition finishes")
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(browser.tabs.map(\.id), [c.id, b.id])
        XCTAssertEqual(browser.tabs[browser.tabIndex].id, b.id)
        XCTAssertEqual(browser.tabs[browser.tabIndex].title, "Updated B")
        browser.saveSession(flush: true)
        XCTAssertEqual(store.load()?.selectedTabID, b.id)
        sync.capture([]); sync.onTabsChange?([])
        XCTAssertEqual(browser.tabs.map(\.id), [b.id])
        XCTAssertEqual(browser.tabs[0].title, "Updated B")
        XCTAssertTrue(sync.tabs.isEmpty, "Retaining the active tab locally must not reopen it on other devices")
        XCTAssertTrue(sync.isClosed(b.id))
        browser.saveSession(flush: true)
        let restored = BrowserViewController(sessionStore: store)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs[0].id, b.id, "Relaunch keeps the page the user was reading")
        XCTAssertFalse(restored.tabs[0].isSyncPlaceholder)
    }

    /// Opt-in device integration test. The generated private zone contains only disposable fixtures.
    @MainActor func testLiveCloudKitMergesTwoClientsAndKeepsClosuresAfterReconnection() async throws {
        guard ProcessInfo.processInfo.environment["RISE_LIVE_ICLOUD_TESTS"] == "1" else {
            throw XCTSkip("Set RISE_LIVE_ICLOUD_TESTS=1 for the live CloudKit integration test")
        }
        let container = CKContainer(identifier: SharedTabsSync.containerIdentifier)
        let accountStatus = try await container.accountStatus()
        XCTAssertEqual(accountStatus, .available)
        let zoneName = "RiseTabsTest-\(UUID())"
        let folder = URL.temporaryDirectory.appendingPathComponent(zoneName)
        let suiteA = zoneName+"A", suiteB = zoneName+"B"
        let pa = try XCTUnwrap(UserDefaults(suiteName: suiteA)), pb = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        let a = SharedTabsSync(cacheURL: folder.appendingPathComponent("a.json"), preferences: pa, cloudAvailable: true, zoneName: zoneName, automaticallySync: false)
        let b = SharedTabsSync(cacheURL: folder.appendingPathComponent("b.json"), preferences: pb, cloudAvailable: true, zoneName: zoneName, automaticallySync: false)
        let one = SharedBrowserTab(id: UUID(), url: "https://example.com/one", title: "One")
        let two = SharedBrowserTab(id: UUID(), url: "https://example.org/two", title: "Two")
        a.onTabsChange = { [weak a] in a?.acknowledge($0) }
        b.onTabsChange = { [weak b] in b?.acknowledge($0) }
        a.start(tabs: [one]); b.start(tabs: [two])
        func waitUntil(_ check: () -> Bool) async throws {
            for index in 0..<120 {
                if check() { return }
                if index % 10 == 0 { _ = await a.refreshAndWait(); _ = await b.refreshAndWait() }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTFail("CloudKit did not converge. Client A: \(a.status); B: \(b.status)")
        }
        do {
            try await waitUntil { Set(a.tabs.map(\.id)) == [one.id, two.id] && a.tabs == b.tabs }
            var changed = two; changed.url = "https://example.org/navigated"; changed.title = "Navigated"
            a.capture([changed])
            try await waitUntil { b.tabs == [changed] }
            b.setEnabled(false)
            b.capture([one, changed])
            b.setEnabled(true)
            try await waitUntil { b.tabs == [changed] && a.tabs == b.tabs }
            a.flush(); b.flush()
            XCTAssertTrue(b.isClosed(one.id))
            print("Live CloudKit: inserts, navigation, closure and offline reconnect converged")
        } catch {
            a.setEnabled(false); b.setEnabled(false)
            _ = try? await container.privateCloudDatabase.deleteRecordZone(withID: .init(zoneName: zoneName))
            throw error
        }
        a.setEnabled(false); b.setEnabled(false)
        _ = try await container.privateCloudDatabase.deleteRecordZone(withID: .init(zoneName: zoneName))
        pa.removePersistentDomain(forName: suiteA); pb.removePersistentDomain(forName: suiteB)
        try? FileManager.default.removeItem(at: folder)
    }
}
