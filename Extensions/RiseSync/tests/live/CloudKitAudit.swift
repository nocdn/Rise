import CloudKit
import Foundation

// Signed diagnostic: only the generated RiseWebAudit-UUID zone may be modified.
@main struct CloudKitWebAudit {
    static func main() async {
        do {
            let mode = CommandLine.arguments[1]
            let file = URL(fileURLWithPath: CommandLine.arguments[2])
            let container = CKContainer(identifier: "iCloud.dev.bartosz.Rise")
            let db = container.privateCloudDatabase
            if mode == "token" {
                var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: String]
                let token: String = try await withCheckedThrowingContinuation { continuation in
                    let operation = CKFetchWebAuthTokenOperation(apiToken: CommandLine.arguments[3])
                    operation.fetchWebAuthTokenResultBlock = { continuation.resume(with: $0) }
                    db.add(operation)
                }
                value["token"] = token
                try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                print("PASS: obtained native web authentication in a private file")
            } else if mode == "cleanup-orphans" {
                for zone in try await db.allRecordZones() where zone.zoneID.zoneName.hasPrefix("RiseWebAudit-") && UUID(uuidString: String(zone.zoneID.zoneName.dropFirst(13))) != nil {
                    _ = try await db.deleteRecordZone(withID: zone.zoneID)
                    print("Removed generated web audit zone: \(zone.zoneID.zoneName)")
                }
            } else if mode == "prepare" {
                let zone = CKRecordZone(zoneName: "RiseWebAudit-\(UUID())")
                _ = try await db.save(zone)
                let tabID = UUID().uuidString
                let recordID = CKRecord.ID(recordName: tabID, zoneID: zone.zoneID)
                let record = CKRecord(recordType: "RiseTab", recordID: recordID)
                let version: [String: Any] = ["clock": 100, "device": UUID().uuidString]
                let payload: [String: Any] = ["tab": ["id": tabID, "url": "https://example.com/rise-web-audit", "title": "Native → web 🌅"],
                    "contentVersion": version, "position": 0, "positionVersion": version]
                record["payload"] = try JSONSerialization.data(withJSONObject: payload) as CKRecordValue
                _ = try await db.save(record)
                FileManager.default.createFile(atPath: file.path, contents: try JSONSerialization.data(withJSONObject: ["zone": zone.zoneID.zoneName, "id": tabID]), attributes: [.posixPermissions: 0o600])
                print("PASS: native CloudKit created a disposable RiseTab record")
            } else {
                let data = try Data(contentsOf: file)
                let value = try JSONSerialization.jsonObject(with: data) as! [String: String]
                let zone = value["zone"]!
                guard zone.hasPrefix("RiseWebAudit-"), UUID(uuidString: String(zone.dropFirst(13))) != nil else { fatalError("Not an audit zone") }
                let zoneID = CKRecordZone.ID(zoneName: zone)
                var failure: Error?
                if mode == "verify" {
                    do {
                        let r = try await db.record(for: CKRecord.ID(recordName: value["id"]!, zoneID: zoneID))
                        let payload = try JSONSerialization.jsonObject(with: r["payload"] as! Data) as! [String: Any]
                        let tab = payload["tab"] as! [String: Any]
                        guard tab["title"] as? String == "Web → native 🌅", payload["closedAt"] != nil else { throw NSError(domain:"audit",code:1) }
                        print("PASS: native CloudKit reads the web-written title and closure tombstone")
                    } catch { failure = error }
                }
                _ = try await db.deleteRecordZone(withID: zoneID)
                try FileManager.default.removeItem(at: file)
                print("PASS: disposable CloudKit zone and authentication file removed")
                if let failure { throw failure }
            }
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
