import CloudKit
import Foundation

/// A live integration check using the production sync implementation and a disposable private zone.
@MainActor enum TabSyncAudit {
    static func cleanup(_ name: String) async -> Int32 {
        let prefix = "RiseTabsAudit-"
        let directory = URL.temporaryDirectory.appendingPathComponent(name)
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.json").path) else {
            print("Cleanup requires the exact generated name and a local audit cache.")
            return 1
        }
        do {
            let database = CKContainer(identifier: SharedTabsSync.containerIdentifier).privateCloudDatabase
            _ = try await database.deleteRecordZone(withID: .init(zoneName: name))
            for suite in [name+"A", name+"B", name+"C"] { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try FileManager.default.removeItem(at: directory)
            print("Removed disposable audit zone and its local fixtures")
            return 0
        } catch { print("Audit cleanup failed: \(error.localizedDescription)"); return 1 }
    }

    static func run() async -> Int32 {
        let zoneName = "RiseTabsAudit-\(UUID())"
        let directory = URL.temporaryDirectory.appendingPathComponent(zoneName)
        let names = [zoneName+"A", zoneName+"B", zoneName+"C"]
        let preferences = names.map { UserDefaults(suiteName: $0)! }
        let a = SharedTabsSync(cacheURL: directory.appendingPathComponent("a.json"), preferences: preferences[0], cloudAvailable: true, zoneName: zoneName, automaticallySync: false)
        let b = SharedTabsSync(cacheURL: directory.appendingPathComponent("b.json"), preferences: preferences[1], cloudAvailable: true, zoneName: zoneName, automaticallySync: false)
        let database = CKContainer(identifier: SharedTabsSync.containerIdentifier).privateCloudDatabase
        var result: Int32 = 0
        func require(_ check: () -> Bool, _ message: String) async throws {
            for attempt in 0..<120 {
                if check() { print("PASS: \(message)"); return }
                if attempt % 10 == 0 { _ = await a.refreshAndWait(); _ = await b.refreshAndWait() }
                try await Task.sleep(for: .milliseconds(500))
            }
            a.flush(); b.flush()
            print("Client A titles: \(a.tabs.compactMap(\.title)); B titles: \(b.tabs.compactMap(\.title))")
            for name in ["a", "b"] {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name+".json")),
                   let cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("Client \(name) pending: \((cache["dirtyIDs"] as? [Any])?.count ?? -1); last error: \(cache["lastError"] ?? "none")")
                }
            }
            throw NSError(domain: "Rise.TabSyncAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message) timed out (A: \(a.status), B: \(b.status))"])
        }
        do {
            let one = SharedBrowserTab(id: UUID(), url: "https://example.com/one", title: "One")
            var two = SharedBrowserTab(id: UUID(), url: "https://example.org/two", title: "Two")
            a.onTabsChange = { [weak a] in a?.acknowledge($0) }
            b.onTabsChange = { [weak b] in b?.acknowledge($0) }
            let searchesA = LearnedSearches(storageURL: directory.appendingPathComponent("searches-a.json"))
            let searchesB = LearnedSearches(storageURL: directory.appendingPathComponent("searches-b.json"))
            let visitsA = BrowsingHistory(storageURL: directory.appendingPathComponent("visits-a.json"))
            let visitsB = BrowsingHistory(storageURL: directory.appendingPathComponent("visits-b.json"))
            let account = URL(string: "https://voxi.co.uk/account")!, home = URL(string: "https://voxi.co.uk/")!
            for _ in 0..<7 { visitsA.record(account, title: "Account") }
            for _ in 0..<5 { visitsB.record(account, title: "Account") }
            a.start(tabs: [one], learnedSearches: searchesA, browsingHistory: visitsA)
            b.start(tabs: [two], learnedSearches: searchesB, browsingHistory: visitsB)
            try await require({ Set(a.tabs.map(\.id)) == [one.id, two.id] && a.tabs == b.tabs }, "simultaneous inserts converge")
            try await require({ visitsA.entries.first?.visits == 12 && visitsA.snapshot == visitsB.snapshot }, "concurrent visit counters sum once through real CloudKit")
            two.url = "https://example.org/navigated"; two.title = "Navigated"
            two.navigationHistory = TabNavigationHistory(entries: [
                .init(url: "https://example.org/two", title: "Two"),
                .init(url: two.url!, title: two.title),
                .init(url: "https://example.com/forward", title: "Forward")
            ], index: 1)
            a.capture([two, one])
            try await require({ b.tabs == [two, one] }, "navigation, Back/Forward history, cursor and ordering reach the other client")
            two.navigationHistory?.entries.insert(.init(url: two.url!, title: "Repeated visit"), at: 2)
            two.navigationHistory?.index = 2
            a.capture([two, one])
            try await require({ b.tabs == [two, one] }, "history-only changes at an unchanged URL reach the other client")
            let fresh = SharedTabsSync(cacheURL: directory.appendingPathComponent("fresh-install.json"), preferences: preferences[2], cloudAvailable: true, zoneName: zoneName, automaticallySync: false)
            fresh.start(tabs: [])
            var recovered = false
            for _ in 0..<12 {
                _ = await fresh.refreshAndWait()
                if fresh.tabs == [two, one] { recovered = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            fresh.setEnabled(false)
            guard recovered else { throw NSError(domain: "Rise.TabSyncAudit", code: 4, userInfo: [NSLocalizedDescriptionKey: "A fresh install did not recover the tab history from CloudKit"]) }
            print("PASS: a fresh client with no local cache recovers Back/Forward history and cursor")
            b.setEnabled(false)
            a.capture([two])
            try await require({ a.isClosed(one.id) }, "closure is recorded")
            var stale = one; stale.title = "Offline edit"
            b.capture([two, stale]); b.setEnabled(true)
            try await require({ a.tabs == [two] && b.tabs == [two] && b.isClosed(one.id) }, "a closure wins over offline edits after reconnection")
            a.flush(); b.flush()
            let restarted = SharedTabsSync(cacheURL: directory.appendingPathComponent("b.json"), preferences: preferences[1], cloudAvailable: false, zoneName: zoneName)
            restarted.start(tabs: [two, stale])
            guard restarted.tabs == [two], restarted.isClosed(one.id) else {
                throw NSError(domain: "Rise.TabSyncAudit", code: 2, userInfo: [NSLocalizedDescriptionKey: "A stale saved session resurrected a closed tab"])
            }
            print("PASS: persisted state keeps closed tabs closed after relaunch")
            _ = searchesA.learn(from: URL(string: "https://shop.example/search?q=lamps")!, terms: ["lamps"], name: "Shop")
            _ = searchesB.learn(from: URL(string: "https://docs.example/find?term=swift")!, terms: ["swift"], name: "Docs")
            a.captureSearches(); b.captureSearches()
            try await require({ searchesA.searches.count == 2 && searchesA.snapshot == searchesB.snapshot }, "concurrent learned searches merge through real CloudKit")
            b.setEnabled(false)
            try searchesA.clear(); a.captureSearches()
            _ = await a.refreshAndWait()
            b.captureSearches(); b.setEnabled(true)
            try await require({ searchesA.searches.isEmpty && searchesB.searches.isEmpty }, "an offline device cannot resurrect cleared searches")
            _ = searchesB.learn(from: URL(string: "https://shop.example/find?query=chairs")!, terms: ["chairs"], name: "Shop")
            b.captureSearches()
            try await require({ searchesA.site(forAddress: "shop.example")?.searchURL(for: "table")?.path == "/find" }, "searches learned after clearing sync normally")
            b.setEnabled(false)
            visitsA.record(account, title: "Account"); _ = await a.refreshAndWait()
            visitsB.record(account, title: "Account"); visitsB.record(account, title: "Account")
            b.setEnabled(true)
            try await require({ visitsA.entries.first?.visits == 15 && visitsA.snapshot == visitsB.snapshot }, "offline visits merge with the other device's new visits")
            for _ in 0..<2 { _ = await a.refreshAndWait(); _ = await b.refreshAndWait() }
            guard visitsA.entries.first?.visits == 15, visitsB.entries.first?.visits == 15 else {
                throw NSError(domain: "Rise.TabSyncAudit", code: 3, userInfo: [NSLocalizedDescriptionKey: "Repeated sync inflated the visit counters"])
            }
            print("PASS: repeated fetch/send cycles do not count visits again")
            b.setEnabled(false)
            try visitsA.clear(); _ = await a.refreshAndWait()
            visitsB.record(account, title: "Stale offline visit"); b.setEnabled(true)
            try await require({ visitsA.entries.isEmpty && visitsB.entries.isEmpty }, "clearing visit learning wins over an offline edit")
            visitsB.record(account, title: "New account visit")
            visitsB.record(home, title: "Home")
            try await require({ visitsA.entries.count == 2 && visitsA.snapshot == visitsB.snapshot }, "new visits after clearing sync with fresh counters")
            b.setEnabled(false)
            _ = visitsA.remove(account); _ = await a.refreshAndWait()
            visitsB.record(account, title: "Offline old counter"); b.setEnabled(true)
            try await require({ visitsA.entries.map(\.url) == [home.absoluteString] && visitsB.entries.map(\.url) == [home.absoluteString] }, "individual history deletion survives reconnection without removing other pages")
            print("Live tabs, learned-search and visit-learning sync integration passed")
        } catch { print("FAIL: \(error.localizedDescription)"); result = 1 }
        a.onTabsChange = nil; b.onTabsChange = nil
        a.setEnabled(false); b.setEnabled(false)
        do { _ = try await database.deleteRecordZone(withID: .init(zoneName: zoneName)) }
        catch { print("Audit zone cleanup failed: \(error.localizedDescription)"); result = 1 }
        for (preference, name) in zip(preferences, names) { preference.removePersistentDomain(forName: name) }
        try? FileManager.default.removeItem(at: directory)
        return result
    }
}
