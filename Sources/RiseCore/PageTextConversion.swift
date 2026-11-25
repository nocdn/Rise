import Foundation

/// Replace on Page for what Rise reads natively, times and measurements: the page hands over its
/// text, the native parser says what to change, and one DOM writer changes it, on both platforms.
/// Only changed text nodes are written; exact originals, inline markup, live page changes and
/// independent edits (another conversion's, a currency's) are retained.
@MainActor public final class PageTextConversion {
    public typealias Evaluate = @MainActor (String, [String: Any]) async throws -> Any?
    /// What to change in a passage of the page's text.
    public typealias Editor = @Sendable (String) -> [Edit]
    public private(set) var isActive = false
    public private(set) var count = 0
    public var onChange: (() -> Void)?
    private let evaluate: Evaluate
    /// The page's name for this conversion's script.
    private let global: String
    private var session = ""
    private var polling: Task<Void, Never>?
    private var editor: Editor = { _ in [] }
    private var cache: [String: [Edit]] = [:]
    private var preparing = false
    private var ready: [CheckedContinuation<Void, Never>] = []
    public init(global: String, evaluate: @escaping Evaluate) { self.global = global; self.evaluate = evaluate }
    deinit { polling?.cancel() }
    public func waitUntilReady() async {
        if preparing { await withCheckedContinuation { ready.append($0) } }
    }

    public struct Edit: Sendable {
        public let start: Int, end: Int, text: String
        var object: [String: Any] { ["start": start, "end": end, "text": text] }
    }
    /// Converts the page with `editor`, keeping on as it changes, or puts it back.
    @discardableResult public func set(_ on: Bool, editor: @escaping Editor = { _ in [] }) async throws -> Int {
        polling?.cancel(); polling = nil
        let previous = session
        session = UUID().uuidString
        let token = session
        preparing = on
        defer {
            if session == token {
                preparing = false
                let waiting = ready; ready.removeAll(); waiting.forEach { $0.resume() }
            }
        }
        if !on {
            isActive = false; count = 0; cache.removeAll(); onChange?()
            _ = try await evaluate(script + "\nreturn globalThis.\(global).restore(session);", ["session": previous])
            return 0
        }
        self.editor = editor; cache.removeAll(); count = 0
        isActive = true; onChange?()
        do {
            _ = try await evaluate(script + "\nreturn globalThis.\(global).begin(session);", ["session": token])
            guard session == token else { return 0 }
            try await refresh(token)
        } catch {
            if session == token { _ = try? await set(false) }
            throw error
        }
        guard session == token, isActive else { return 0 }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, self.session == token, self.isActive else { return }
                do { try await self.refresh(token) } catch { /* A navigating/sleeping page will be checked again. */ }
            }
        }
        return count
    }

    private func refresh(_ token: String) async throws {
        guard session == token else { return }
        let response = try await evaluate("return globalThis.\(global)?.take(session) ?? null;", ["session": token]) as? [String: Any]
        guard session == token else { return }
        guard let response, response["active"] as? Bool == true else {
            isActive = false; count = 0; polling?.cancel(); polling = nil; onChange?(); return
        }
        let passages = response["passages"] as? [[String: Any]] ?? []
        guard !passages.isEmpty else { return }
        let texts = Set(passages.compactMap { $0["text"] as? String }).filter { cache[$0] == nil }
        let editor = editor
        let computed = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: texts.map { ($0, editor($0)) })
        }.value
        guard session == token else { return }
        cache.merge(computed) { _, new in new }
        if cache.count > 2000 { cache = computed }
        let plans: [[String: Any]] = passages.compactMap { passage in
            guard let id = passage["id"] as? Int, let text = passage["text"] as? String, let edits = cache[text] else { return nil }
            return ["id": id, "text": text, "edits": edits.map(\.object)]
        }
        let value = try await evaluate("return globalThis.\(global)?.write(session, plans) ?? 0;", ["session": token, "plans": plans]) as? NSNumber
        guard session == token else { return }
        count += value?.intValue ?? 0
    }

    var script: String { Self.script(global: global) }

    /// The page's half: hands over its text where it has digits, and writes what it's told to.
    public static func script(global: String) -> String { PageTextEdits.script + #"""
    (() => {
      if (globalThis.__GLOBAL__) return;
      const SKIP = 'script,style,noscript,textarea,input,select,option,code,pre,template,svg,math,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"]';
      let state = null;
      const accepts = node => node.parentElement && !node.parentElement.closest(SKIP);
      function texts(root, limit = 32000) {
        const nodes = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let length = 0;
        for (let n = root.nodeType === 3 ? root : walker.nextNode(); n; n = root.nodeType === 3 ? null : walker.nextNode()) {
          if (!accepts(n)) return null;
          length += n.data.length;
          if (length > limit || nodes.length > 80) return null;
          nodes.push(n);
        }
        return nodes;
      }
      function take(session) {
        if (!state || state.session !== session) return {active: false};
        const passages = [], used = new Set();
        const roots = [...state.pending]; state.pending.clear();
        for (const root of roots) {
          if (!root.isConnected) continue;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          for (let n = root.nodeType === 3 ? root : walker.nextNode(); n; n = root.nodeType === 3 ? null : walker.nextNode()) {
            if (used.has(n) || !accepts(n) || !/\d|noon|midnight/i.test(n.data)) continue;
            const record = state.records.get(n);
            if (record?.written === n.data) continue;
            let nodes = [n];
            // Include an inline-split clock and its zone, but never combine separate block rows.
            for (let e = n.parentElement, depth = 0; e && depth < 3; e = e.parentElement, depth++) {
              if (e.matches('body,article,section,main,ul,ol,table,tbody,tr') || e.querySelector('div,p,li,td,th,h1,h2,h3,h4,h5,h6,br')) break;
              const group = texts(e, 400);
              if (!group || group.some(x => used.has(x) || state.records.get(x)?.written === x.data)) break;
              nodes = group;
            }
            if (nodes.reduce((sum, n) => sum+n.data.length, 0) > 32000) continue;
            nodes.forEach(n => used.add(n));
            const text = nodes.map(n => n.data).join(''), id = ++state.next;
            state.plans.set(id, {nodes: nodes.map(n => new WeakRef(n)), text});
            passages.push({id, text});
          }
        }
        return {active: true, passages};
      }
      function write(session, plans) {
        if (!state || state.session !== session) return 0;
        let count = 0;
        for (const plan of plans) {
          const saved = state.plans.get(plan.id); state.plans.delete(plan.id);
          if (!saved) continue;
          const nodes = saved.nodes.map(r => r.deref());
          if (nodes.some(n => !n?.isConnected || !accepts(n)) || nodes.map(n => n.data).join('') !== plan.text) {
            nodes.filter(n => n?.isConnected).forEach(n => state.pending.add(n)); continue;
          }
          const pieces = riseTextEdits.distribute(plan.text, nodes.map(n => n.data.length), plan.edits);
          for (const [i, node] of nodes.entries()) {
            const piece = pieces[i];
            if (node.data === piece.written) continue;
            const old = state.records.get(node);
            if ((old?.changes ?? 0) >= 20) continue;
            if (!old) state.nodes.push(new WeakRef(node));
            state.records.set(node, riseTextEdits.record(old, piece));
            node.data = piece.written;
          }
          count += plan.edits.length;
        }
        return count;
      }
      function restore(session) {
        if (!state || session && state.session !== session) return false;
        state.observer.disconnect();
        for (const ref of state.nodes) {
          const node = ref.deref(), record = node && state.records.get(node);
          if (record) node.data = riseTextEdits.restore(record, node.data);
        }
        state = null; return true;
      }
      function begin(session) {
        restore();
        const root = document.body || document.documentElement;
        state = {session, pending: new Set([root]), records: new WeakMap(), nodes: [], plans: new Map(), next: 0};
        state.observer = new MutationObserver(changes => {
          for (const change of changes) {
            if (change.type === 'characterData') {
              if (state.records.get(change.target)?.written !== change.target.data) state.pending.add(change.target.parentElement || change.target);
            } else if (change.type === 'attributes') state.pending.add(change.target);
            else for (const node of change.addedNodes) if (node.nodeType === 1 || node.nodeType === 3) state.pending.add(node.parentElement || node);
          }
        });
        state.observer.observe(root, {subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['contenteditable']});
        return true;
      }
      addEventListener('pagehide', () => restore());
      globalThis.__GLOBAL__ = {begin, take, write, restore, get active() {return !!state;}};
    })();
    """#.replacingOccurrences(of: "__GLOBAL__", with: global) }
}
