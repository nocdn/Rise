import Foundation

public struct SearchableTab: Equatable, Sendable {
    public var id: String, title: String, url: String, detail: String
    public init(id: String, title: String, url: String, detail: String = "") {
        self.id=id; self.title=String(title.prefix(160)); self.url=String(Self.safeAddress(url).prefix(350)); self.detail=String(detail.prefix(650))
    }
    private static func safeAddress(_ value: String) -> String {
        guard var parts=URLComponents(string:value) else { return "" }
        parts.user=nil;parts.password=nil
        let secretKeys:Set<String>=["access_token","refresh_token","id_token","token","api_key","apikey","key","password","passwd","secret","signature","authorization","code"]
        if let items=parts.queryItems { parts.queryItems=items.filter { !secretKeys.contains($0.name.lowercased()) } }
        if let fragment=parts.fragment, secretKeys.contains(where:{ fragment.lowercased().contains($0+"=") }) { parts.fragment=nil }
        return parts.string ?? ""
    }
    public var searchableText: String { title+" "+url+" "+detail }
}
public enum TabSearchIndex {
    public static let maximumCandidates = 120, characterBudget = 40_000
    public static func candidates(_ tabs: [SearchableTab], query: String) -> [SearchableTab] {
        let ignored: Set<String> = ["find","me","the","a","an","of","for","page","tab","that","with","please","show","i","was","looking","at"]
        let words=query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !ignored.contains($0) }
        guard tabs.count > maximumCandidates else { return tabs }
        return tabs.enumerated().sorted { a,b in
            func score(_ tab: SearchableTab) -> Int {
                words.reduce(0) { $0+(tab.searchableText.localizedCaseInsensitiveContains($1) ? 1 : 0) }
            }
            let left=score(a.element),right=score(b.element)
            return left == right ? a.offset < b.offset : left > right
        }.prefix(maximumCandidates).map(\.element)
    }
    /// A bounded record per tab, not the contents of every page. All supplied IDs remain available.
    public static func packet(_ candidates: [SearchableTab]) -> String {
        var perTab=max(40,min(900,characterBudget/max(1,candidates.count)-100))
        while true {
            let records=candidates.prefix(maximumCandidates).map { tab -> [String:String] in
                let title=String(tab.title.prefix(min(120,perTab/3))),url=String(tab.url.prefix(min(240,perTab/2)))
                return ["id":tab.id,"title":title,"url":url,"metadata":String(tab.detail.prefix(max(0,perTab-title.count-url.count)))]
            }
            let data=(try? JSONSerialization.data(withJSONObject:records,options:[.sortedKeys,.withoutEscapingSlashes])) ?? Data("[]".utf8)
            if data.count<=characterBudget || perTab<=8 { return String(decoding:data,as:UTF8.self) }
            perTab=max(8,perTab*3/4)
        }
    }
    public static func resultIDs(_ response: String, allowed: Set<String>) throws -> [String] {
        let trimmed=response.trimmingCharacters(in:.whitespacesAndNewlines)
        let source: String
        if trimmed.hasPrefix("```"), let first=trimmed.firstIndex(of:"\n"),let last=trimmed.range(of:"```",options:.backwards),first<last.lowerBound { source=String(trimmed[trimmed.index(after:first)..<last.lowerBound]) }
        else { source=trimmed }
        struct Result: Decodable { var tabs: [String] }
        let decoded=try JSONDecoder().decode(Result.self,from:Data(source.utf8))
        var seen=Set<String>()
        return decoded.tabs.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(30).map { $0 }
    }
}
