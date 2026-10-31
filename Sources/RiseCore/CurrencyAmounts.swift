import Foundation
import JavaScriptCore

/// An amount of money selected on a page: one value, or a range's two, in the currency it was written in.
public struct CurrencyAmount: Equatable, Sendable {
    public let values: [Double]
    public let currency: String
    public let written: String
}

/// Amounts of money in text, for the selection menu to convert into the person's own currency, and
/// Replace on Page, which rewrites every amount on a page into it, written as the page writes them:
/// "£66.06" becomes "€76.20" and "1 234,50 zł" "287,08 €", and back again. One script reads them
/// for both, so the menu and the page always agree; the selection's is run here in JavaScriptCore.
public enum CurrencyAmounts {
    static let maximumLength = 400, maximumAmounts = 3

    /// The amounts in `text`, with currencies `rates` knows. "$" is the page's dollar: Canada's on a
    /// .ca site, as `host` says; "kr" with no country to go by is no one's.
    public static func find(in text: String, host: String? = nil, rates: ExchangeRates) -> [CurrencyAmount] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength, text.contains(where: \.isNumber) else { return [] }
        let found = engine.call("find", text, ["rates": rates.rates, "host": host ?? ""]) as? [[String: Any]] ?? []
        return found.prefix(maximumAmounts).compactMap { match in
            guard let currency = match["currency"] as? String, let values = match["values"] as? [Double],
                  let written = match["written"] as? String, !values.isEmpty else { return nil }
            return CurrencyAmount(values: values, currency: currency, written: written)
        }
    }

    /// `text` with its amounts in `target`, as Replace on Page writes them.
    public static func rewrite(_ text: String, to target: String, rates: ExchangeRates, host: String? = nil, lang: String? = nil,
                               locale: Locale = .current) -> String {
        var options = replaceOptions(to: target, rates: rates, locale: locale)
        options["host"] = host ?? ""; options["lang"] = lang ?? ""
        return engine.call("rewrite", text, options) as? String ?? text
    }

    /// What Replace on Page is given, as `options`: the rates, and the currency and how it's written.
    public static func replaceOptions(to target: String, rates: ExchangeRates, locale: Locale = .current) -> [String: Any] {
        ["rates": rates.rates, "target": target, "format": format(of: target, locale: locale)]
    }

    /// How the person's region writes an amount in `currency`: its symbol, before or after the
    /// number, with a space or not, and its decimal and thousands separators. "£1,234.50" in
    /// Britain; "1 234,50 zł" in Poland.
    static func format(of currency: String, locale: Locale) -> [String: Any] {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .currency; formatter.currencyCode = currency
        let sample = formatter.string(from: 1234.5) ?? "", spaces = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{a0}\u{202f}"))
        let digits = sample.indices.filter { sample[$0].isNumber }
        guard let first = digits.first, let last = digits.last else {
            return ["symbol": currency, "before": true, "space": true, "decimal": ".", "group": ","]
        }
        let before = String(sample[..<first]), after = String(sample[sample.index(after: last)...])
        let symbol = (before + after).trimmingCharacters(in: spaces.union(CharacterSet(charactersIn: "-−")))
        let leads = !before.trimmingCharacters(in: spaces.union(CharacterSet(charactersIn: "-−"))).isEmpty
        let space = leads ? before.unicodeScalars.last.map(spaces.contains) ?? false : after.unicodeScalars.first.map(spaces.contains) ?? false
        return ["symbol": symbol.isEmpty ? currency : symbol, "before": leads, "space": space,
                "decimal": formatter.currencyDecimalSeparator ?? ".", "group": formatter.usesGroupingSeparator ? formatter.currencyGroupingSeparator ?? "" : ""]
    }

    /// An amount as the person reads money: "€76.20", "US$88.12".
    public static func format(_ value: Double, in currency: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .currency; formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
    }

    /// `amount` in `currency`, a range's ends joined: "€11.53 – €23.06".
    public static func converted(_ amount: CurrencyAmount, to currency: String, rates: ExchangeRates, locale: Locale = .current) -> String? {
        let values = amount.values.compactMap { rates.convert($0, from: amount.currency, to: currency) }
        guard values.count == amount.values.count else { return nil }
        return values.map { format($0, in: currency, locale: locale) }.joined(separator: " – ")
    }

    /// How the menu heads an amount: its value in `currency`, and of several, what each was written as.
    public static func label(_ amount: CurrencyAmount, of count: Int = 1, to currency: String, rates: ExchangeRates, locale: Locale = .current) -> String? {
        guard let converted = converted(amount, to: currency, rates: rates, locale: locale) else { return nil }
        return count > 1 ? "\(amount.written) → \(converted)" : converted
    }

    /// "Euro", "US Dollar": a currency's name as the person would say it.
    public static func name(of code: String, locale: Locale = .current) -> String? {
        guard let name = locale.localizedString(forCurrencyCode: code), name != code else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    public typealias Currency = (code: String, name: String)
    /// The most traded currencies, most first (the BIS's survey of foreign exchange), to head lists of them.
    public static let popular = ["USD", "EUR", "JPY", "GBP", "CNY", "AUD", "CAD", "CHF", "HKD", "SGD"]

    /// Every currency in `codes` with a name: the popular ones, most traded first, then the rest by name.
    public static func currencies(_ codes: some Sequence<String>, locale: Locale = .current) -> (popular: [Currency], others: [Currency]) {
        let named = Dictionary(codes.compactMap { code in name(of: code, locale: locale).map { (code, $0) } }, uniquingKeysWith: { first, _ in first })
        let popular = Self.popular.compactMap { code in named[code].map { (code: code, name: $0) } }
        let others = named.filter { !Self.popular.contains($0.key) }.map { (code: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (popular, others)
    }

    /// Every currency `rates` has, as `currencies(_:)` lists them.
    public static func currencies(in rates: ExchangeRates, locale: Locale = .current) -> (popular: [Currency], others: [Currency]) {
        currencies(rates.rates.keys, locale: locale)
    }

    /// Run in the page, as a function body with `options` (`rates`, `target`): rewrites its amounts
    /// into `target`, then keeps doing so as the page changes, until `restoreBody`. Returns how many.
    public static let applyBody = script + "\nreturn riseCurrency.apply(options);"
    /// Puts back what the page said, and says whether anything was replaced.
    public static let restoreBody = script + "\nreturn riseCurrency.restore();"
    public static let isReplacedBody = "return !!globalThis.riseCurrency?.active;"

    private static let engine = Engine()

    /// One JavaScriptCore context, made once, for any thread to use in turn.
    private final class Engine: @unchecked Sendable {
        private let lock = NSLock()
        private var context: JSContext?
        func call(_ name: String, _ text: String, _ options: [String: Any]) -> Any? {
            lock.lock(); defer { lock.unlock() }
            if context == nil {
                context = JSContext()
                context?.evaluateScript(CurrencyAmounts.script)
            }
            guard let context, let function = context.objectForKeyedSubscript("riseCurrency")?.objectForKeyedSubscript(name),
                  let result = function.call(withArguments: [text, options]), !result.isUndefined else { return nil }
            return result.toObject()
        }
    }

    /// The reader and writer of amounts. `find` and `rewrite` are plain text; `apply` and `restore`
    /// walk a page's text, only where there are digits, and set nothing but the text they change.
    public static let script = #"""
    (() => {
    if (globalThis.riseCurrency) return;
    // Signs written beside an amount. One several currencies share is the page's own: '$' is
    // Canada's on a .ca site; 'kr' with no country to go by is skipped.
    const SIGNS = {
      'US$': 'USD', 'CA$': 'CAD', 'C$': 'CAD', 'AU$': 'AUD', 'A$': 'AUD', 'NZ$': 'NZD', 'HK$': 'HKD', 'S$': 'SGD',
      'R$': 'BRL', 'MX$': 'MXN', 'NT$': 'TWD', '$': '$', '€': 'EUR', '£': 'GBP', '¥': '¥', '￥': '¥', '₹': 'INR',
      '₩': 'KRW', '₽': 'RUB', '₺': 'TRY', '₪': 'ILS', '₫': 'VND', '฿': 'THB', '₱': 'PHP', '₴': 'UAH', '₦': 'NGN',
      '₸': 'KZT', '₼': 'AZN', '₾': 'GEL', '৳': 'BDT', '₡': 'CRC', '₲': 'PYG', '₵': 'GHS',
      'zł': 'PLN', 'Kč': 'CZK', 'Ft': 'HUF', 'lei': 'RON', 'kr': 'kr', 'Rp': 'IDR', 'RM': 'MYR', 'лв': 'BGN',
    };
    const WORDS = { euro: 'EUR', euros: 'EUR', dollar: '$', dollars: '$', yen: '¥', 'złotych': 'PLN', 'złote': 'PLN', 'złoty': 'PLN', zloty: 'PLN', zlotys: 'PLN' };
    // What an amount in each currency is written with, where it isn't its code.
    const OUT = {
      USD: '$', EUR: '€', GBP: '£', JPY: '¥', CNY: '¥', INR: '₹', KRW: '₩', RUB: '₽', TRY: '₺', ILS: '₪', VND: '₫',
      THB: '฿', PHP: '₱', UAH: '₴', NGN: '₦', KZT: '₸', AZN: '₼', GEL: '₾', BDT: '৳', CRC: '₡', PYG: '₲', GHS: '₵',
      PLN: 'zł', CZK: 'Kč', HUF: 'Ft', RON: 'lei', SEK: 'kr', NOK: 'kr', DKK: 'kr', ISK: 'kr', IDR: 'Rp', MYR: 'RM',
      BGN: 'лв', CAD: 'CA$', AUD: 'A$', NZD: 'NZ$', HKD: 'HK$', SGD: 'S$', BRL: 'R$', MXN: 'MX$', TWD: 'NT$',
    };
    // Written in whole units.
    const WHOLE = new Set('JPY KRW VND CLP ISK PYG UGX XAF XOF XPF KMF GNF RWF BIF DJF VUV IDR HUF TWD COP'.split(' '));
    // Codes that are also words written in capitals.
    const STOP = new Set('ALL CUP TOP MOP PEN MAD GEL SOS BOB AMD BAM'.split(' '));
    const SCALE = { k: 1e3, K: 1e3, thousand: 1e3, m: 1e6, M: 1e6, mn: 1e6, million: 1e6, mln: 1e6, bn: 1e9, B: 1e9, billion: 1e9, mld: 1e9 };
    const DOLLARS = { ca: 'CAD', au: 'AUD', nz: 'NZD', sg: 'SGD', hk: 'HKD', mx: 'MXN', ar: 'ARS', cl: 'CLP', co: 'COP', tw: 'TWD' };
    const KRONOR = { se: 'SEK', sv: 'SEK', no: 'NOK', nb: 'NOK', nn: 'NOK', dk: 'DKK', da: 'DKK', is: 'ISK' };

    const escape = s => s.replace(/[.*+?^${}()|[\]\\\/]/g, '\\$&');
    const signs = Object.keys(SIGNS).sort((a, b) => b.length - a.length).map(escape).join('|');
    const SP = '[ \\u00a0\\u202f]?';
    const NUM = "\\d{1,3}(?:[,.\\u00a0\\u202f' ]\\d{3})+(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d{1,2})?";
    const DASH = '(?:[.,][-–—])?';
    const words = '[Ee]uros?|[Dd]ollars?|yen|[Zz]ł(?:otych|ote|oty)|[Zz]lotys?';
    // "$66.06", "USD 66.06", "£2.5bn", "$100 USD".
    const PREFIX = new RegExp(`(?<![\\p{L}\\p{N}])(${signs}|[A-Z]{3})(${SP})(${NUM})${DASH}(?:${SP}(million|billion|thousand|mln|mld|bn|mn|k|K|m|M|B)(?![\\p{L}]))?(?![\\p{N}])`, 'gdu');
    const CODE = new RegExp(`(${SP})([A-Z]{3})(?![\\p{L}\\p{N}])`, 'dyu');
    // "66.06 GBP", "1 234,50 zł", "12,- €", "5 million euros".
    const SUFFIX = new RegExp(`(?<![\\p{L}\\p{N}.,$€£¥])(${NUM})${DASH}(?:${SP}(million|billion|mln|mld|bn|mn)(?![\\p{L}]))?(${SP})(${words}|${signs}|[A-Z]{3})(?![\\p{L}\\p{N}])`, 'gdu');
    const AFTER = new RegExp(`${SP}[-–—]${SP}(${NUM})(?![\\p{N}.,]?\\d)`, 'dyu');
    const BEFORE = new RegExp(`(?<![\\p{L}\\p{N}.,])(${NUM})${SP}[-–—]${SP}$`, 'du');
    const PARTS = /^(\d{1,3}(?:([,.  ' ])\d{3})+|\d+)(?:([.,])(\d{1,2}))?$/u;

    function context(options) {
      const rates = options.rates || {}, host = String(options.host || '').toLowerCase(), lang = String(options.lang || '').toLowerCase();
      const tld = host.split('.').pop(), [language, region = ''] = lang.split(/[-_]/);
      return {
        rates, target: options.target, codes: rates,
        dollar: DOLLARS[tld] || DOLLARS[region] || 'USD',
        yen: tld === 'cn' || region === 'cn' || language === 'zh' ? 'CNY' : 'JPY',
        krona: KRONOR[tld] || KRONOR[region] || KRONOR[language] || null,
        format: options.format || null,
      };
    }

    function currency(written, ctx) {
      const known = SIGNS[written] ?? WORDS[written.toLowerCase()];
      const code = known === '$' ? ctx.dollar : known === '¥' ? ctx.yen : known === 'kr' ? ctx.krona
        : known ?? (/^[A-Z]{3}$/.test(written) && !STOP.has(written) ? written : null);
      return code && ctx.codes[code] ? code : null;
    }

    // A number as written: its value, and how it's written, for its replacement to follow.
    function number(text, at) {
      const parts = PARTS.exec(text);
      if (!parts) return null;
      const whole = parts[1], group = parts[2] ?? null, decimal = parts[3] ?? null, fraction = parts[4] ?? '';
      if (group && (decimal === group || whole.replace(/\d/g, '').split('').some(c => c !== group))) return null;
      const integer = Number(whole.replace(/\D/g, ''));
      return { value: Number(`${integer}.${fraction || 0}`), integer, group, decimal, places: fraction.length,
        whole: [at, at + whole.length], point: decimal ? [at + whole.length, at + whole.length + 1] : null,
        fraction: decimal ? [at + whole.length + 1, at + text.length] : null };
    }

    // Every amount in `text`, earliest first, none overlapping, each with the parts its rewrite replaces.
    function scan(text, ctx) {
      const found = [];
      for (const m of text.matchAll(PREFIX)) {
        const sign = currency(m[1], ctx), n = sign && number(m[3], m.indices[3][0]);
        if (!n) continue;
        const amount = { start: m.index, end: m.index + m[0].length, currency: sign, numbers: [n], magnitude: m[4] || null,
          signs: [{ range: m.indices[1], spaced: [m.indices[1][0], m.indices[2][1]], kind: /^[A-Z]{3}$/.test(m[1]) ? 'code' : 'sign', before: true }] };
        // "$10–20".
        AFTER.lastIndex = amount.end;
        const more = !m[4] && AFTER.exec(text), second = more && number(more[1], more.indices[1][0]);
        if (second) { amount.numbers.push(second); amount.end = AFTER.lastIndex; }
        // "$100 USD": the code after it says which dollar it is.
        CODE.lastIndex = amount.end;
        const after = CODE.exec(text), code = after && currency(after[2], ctx);
        if (code && (SIGNS[m[1]] === '$' || SIGNS[m[1]] === '¥' || code === sign)) {
          amount.currency = code; amount.end = CODE.lastIndex;
          amount.signs.push({ range: after.indices[2], kind: 'code', before: false });
        }
        found.push(amount);
      }
      for (const m of text.matchAll(SUFFIX)) {
        const which = currency(m[4], ctx), n = which && number(m[1], m.index);
        if (!n) continue;
        const word = WORDS[m[4].toLowerCase()] !== undefined && m[4].length > 2;
        const amount = { start: m.index, end: m.index + m[0].length, currency: which, numbers: [n], magnitude: m[2] || null,
          signs: [{ range: m.indices[4], spaced: [m.indices[3][0], m.indices[4][1]], kind: /^[A-Z]{3}$/.test(m[4]) || word ? 'code' : 'sign', before: false }] };
        const lead = BEFORE.exec(text.slice(Math.max(0, m.index - 40), m.index));
        if (lead && !m[2]) {
          const at = Math.max(0, m.index - 40) + lead.indices[1][0], first = number(lead[1], at);
          if (first) { amount.numbers.unshift(first); amount.start = at; }
        }
        found.push(amount);
      }
      found.sort((a, b) => a.start - b.start || b.end - a.end);
      const kept = [];
      for (const amount of found) if (!kept.length || amount.start >= kept[kept.length - 1].end) kept.push(amount);
      return kept;
    }

    function find(text, options) {
      const ctx = context(options);
      return scan(text, ctx).map(a => ({ currency: a.currency, values: a.numbers.map(n => n.value * (SCALE[a.magnitude] || 1)),
        written: text.slice(a.start, a.end) }));
    }

    // How an amount in the target is written: as the person's region writes it, from the app's
    // formatter ("£66.40", "1 234,50 zł"), or failing that, its sign before a point-decimal number.
    function style(ctx) {
      if (ctx.format) return ctx.format;
      const target = ctx.target;
      const symbol = target === ctx.dollar ? '$' : target === 'USD' && ctx.dollar !== 'USD' ? 'US$' : OUT[target] || target;
      return { symbol, before: true, space: /\p{L}$/u.test(symbol), decimal: '.', group: ',' };
    }

    function digits(value, n, magnitude, format, ctx) {
      const whole = WHOLE.has(ctx.target);
      let places = whole ? 0 : n.places;
      if (magnitude) places = Math.max(places, value < 100 ? 1 : 0);
      else if (!whole && places === 0 && value > 0 && Math.round(value) === 0) places = 2;
      let fixed = value.toFixed(places);
      if (magnitude && fixed.includes('.')) fixed = fixed.replace(/\.?0+$/, '');
      const [integer, fraction = ''] = fixed.split('.');
      const group = format.group === format.decimal ? '' : format.group;
      return { integer: group ? integer.replace(/\B(?=(\d{3})+(?!\d))/g, group) : integer, decimal: fraction ? format.decimal : '', fraction };
    }

    // What replaces each written part of `amount`, or nothing where it's already in the target.
    // Its number and sign are written as the target's are: "349,00 zł" becomes "£66.40", not
    // "66,40 £". A code stays a code where it was, and whole amounts stay whole.
    function render(amount, ctx) {
      const from = ctx.rates[amount.currency], to = ctx.rates[ctx.target];
      if (amount.currency === ctx.target || !from || !to) return [];
      const parts = [], format = style(ctx), gap = format.space ? '\u00a0' : '';
      let moved = false;
      for (const s of amount.signs) {
        if (s.kind === 'code') { parts.push({ start: s.range[0], end: s.range[1], text: ctx.target }); continue; }
        // The sign, with the space beside it, where the target's goes; on its other side, nothing.
        const here = s.before === format.before;
        moved = moved || !here;
        parts.push({ start: s.spaced[0], end: s.spaced[1], text: !here ? '' : s.before ? format.symbol + gap : gap + format.symbol });
      }
      const numbers = [];
      for (const n of amount.numbers) {
        const d = digits(n.value / from * to, n, amount.magnitude, format, ctx);
        const pieces = n.point
          ? [{ start: n.whole[0], end: n.whole[1], text: d.integer }, { start: n.point[0], end: n.point[1], text: d.decimal },
             { start: n.fraction[0], end: n.fraction[1], text: d.fraction }]
          : [{ start: n.whole[0], end: n.whole[1], text: d.integer + d.decimal + d.fraction }];
        numbers.push(...pieces);
      }
      if (moved && format.before) numbers[0].text = format.symbol + gap + numbers[0].text;
      else if (moved) numbers[numbers.length - 1].text += gap + format.symbol;
      return parts.concat(numbers);
    }

    // The new text of each of `lengths`' consecutive pieces of `text`: a part's replacement goes
    // where it starts, so "£", "66", ".", "06" in their own elements each keep theirs.
    function distribute(text, lengths, parts) {
      const starts = new Map(parts.map(p => [p.start, p])), covered = new Uint8Array(text.length);
      for (const p of parts) covered.fill(1, p.start + 1, p.end);
      const out = [];
      let at = 0;
      for (const length of lengths) {
        let piece = '';
        for (let i = at; i < at + length; i++) {
          const part = starts.get(i);
          if (part) piece += part.text; else if (!covered[i]) piece += text[i];
        }
        out.push(piece); at += length;
      }
      return out;
    }

    function rewrite(text, options) {
      const ctx = context(options);
      const parts = scan(text, ctx).flatMap(a => render(a, ctx));
      return parts.length ? distribute(text, [text.length], parts)[0] : text;
    }

    // Replace on Page.
    const SKIPPED = 'script,style,noscript,textarea,input,select,option,code,template,svg,math,[contenteditable=""],[contenteditable="true"]';
    let state = null;

    function accepts(node) {
      const parent = node.parentElement;
      return !!parent && !parent.closest(SKIPPED);
    }

    // An element's few, short texts, for an amount split between elements: "£", "66", ".", "06".
    function shortTexts(element) {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT), nodes = [];
      let length = 0;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        length += node.data.length;
        if (length > 40 || nodes.push(node) > 8) return null;
      }
      return nodes;
    }

    // What in `root` to rewrite: each text with amounts, and each short element with one split between its texts.
    function collect(root, plans) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node = root.nodeType === 3 ? root : walker.nextNode(); node; node = root.nodeType === 3 ? null : walker.nextNode()) {
        if (state.done.has(node) || !/\d/.test(node.data) || !accepts(node)) continue;
        const record = state.records.get(node);
        if (record && record.written === node.data) continue;
        const amounts = scan(node.data, state.ctx);
        if (amounts.length) { plans.push({ nodes: [node], text: node.data, amounts }); continue; }
        if (node.data.trim().length > 12) continue;
        let element = node.parentElement;
        for (let depth = 0; element && depth < 3; depth++, element = element.parentElement) {
          const nodes = shortTexts(element);
          if (!nodes) break;
          if (nodes.length < 2) continue;
          if (nodes.some(n => state.done.has(n) || state.records.has(n))) break;
          const text = nodes.map(n => n.data).join(''), found = scan(text, state.ctx), bounds = [];
          nodes.reduce((at, n) => (bounds.push(at + n.data.length), at + n.data.length), 0);
          if (found.some(a => bounds.some(b => a.start < b && b < a.end))) {
            nodes.forEach(n => state.done.add(n));
            plans.push({ nodes, text, amounts: found });
            break;
          }
        }
      }
    }

    function write(plans) {
      let count = 0;
      for (const plan of plans) {
        const parts = plan.amounts.flatMap(a => render(a, state.ctx));
        if (!parts.length) continue;
        count += plan.amounts.length;
        const texts = distribute(plan.text, plan.nodes.map(n => n.data.length), parts);
        plan.nodes.forEach((node, i) => {
          if (texts[i] === node.data) return;
          const record = state.records.get(node), changes = (record?.changes ?? 0) + 1;
          // A page that keeps putting its own back is left to it.
          if (changes > 20) return;
          if (!record) state.nodes.push(new WeakRef(node));
          state.records.set(node, { original: node.data, written: texts[i], changes });
          node.data = texts[i];
        });
      }
      return count;
    }

    function flush() {
      state.timer = null;
      const roots = [...state.pending]; state.pending.clear();
      const plans = [];
      for (const root of roots) {
        if (!root.isConnected) continue;
        if (root.nodeType === 3) {
          const record = state.records.get(root);
          if (record && record.written === root.data) continue;
          // The page wrote this itself: what it says now is the original.
          if (record) state.records.set(root, { ...record, original: root.data, written: null });
          state.done.delete(root);
        }
        collect(root, plans);
      }
      write(plans);
    }

    function apply(options) {
      if (state) restore();
      const root = document.body || document.documentElement;
      state = { ctx: context({ ...options, host: location.hostname, lang: document.documentElement.lang }),
        records: new WeakMap(), nodes: [], done: new WeakSet(), pending: new Set(), timer: null };
      const plans = [];
      collect(root, plans);
      const count = write(plans);
      state.observer = new MutationObserver(list => {
        for (const m of list) {
          if (m.type === 'characterData') state.pending.add(m.target);
          else for (const node of m.addedNodes) if (node.nodeType === 1 || node.nodeType === 3) state.pending.add(node);
        }
        if (state.pending.size && !state.timer) state.timer = setTimeout(flush, 250);
      });
      state.observer.observe(root, { subtree: true, childList: true, characterData: true });
      return count;
    }

    function restore() {
      if (!state) return false;
      state.observer.disconnect(); clearTimeout(state.timer);
      for (const ref of state.nodes) {
        const node = ref.deref(), record = node && state.records.get(node);
        if (record && record.written === node.data) node.data = record.original;
      }
      state = null;
      return true;
    }

    globalThis.riseCurrency = { find, rewrite, apply, restore, get active() { return !!state; } };
    })();
    """#
}

/// What a dollar of each currency is worth, from one day's rates.
public struct ExchangeRates: Codable, Equatable, Sendable {
    public var base: String
    public var rates: [String: Double]
    public var updated: Date

    public init(base: String, rates: [String: Double], updated: Date) {
        self.base = base; self.rates = rates; self.updated = updated
    }

    public func convert(_ value: Double, from: String, to: String) -> Double? {
        guard let source = rates[from], let target = rates[to], source > 0 else { return nil }
        return value/source*target
    }

    /// The open ExchangeRate-API's day of rates (https://www.exchangerate-api.com/docs/free).
    public init?(response data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["result"] as? String == "success",
              let base = object["base_code"] as? String, let rates = object["rates"] as? [String: Double], !rates.isEmpty else { return nil }
        let updated = (object["time_last_update_unix"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        self.init(base: base, rates: rates, updated: updated)
    }
}

/// The day's exchange rates, kept between launches and fetched again twice a day as they're used.
/// Only the rates are fetched: nothing selected or visited leaves the device.
public final class ExchangeRateStore: @unchecked Sendable {
    public static let shared = ExchangeRateStore()
    static let source = URL(string: "https://open.er-api.com/v6/latest/USD")!
    static let refreshInterval: TimeInterval = 12*3600, retryInterval: TimeInterval = 10*60

    private let lock = NSLock()
    private let file: URL?
    private var cached: ExchangeRates?
    private var loaded = false
    private var lastAttempt: Date?

    init(file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Rise").appendingPathComponent("ExchangeRates.json")) {
        self.file = file
    }

    /// The latest rates there are, however old.
    public var rates: ExchangeRates? {
        lock.lock(); defer { lock.unlock() }
        if !loaded, let file, let data = try? Data(contentsOf: file) { cached = try? JSONDecoder().decode(ExchangeRates.self, from: data) }
        loaded = true
        return cached
    }

    /// Rates from elsewhere, as a check's, used until the next fetch.
    public func use(_ rates: ExchangeRates) {
        lock.lock(); cached = rates; loaded = true; lastAttempt = Date(); lock.unlock()
    }

    /// Fetches the day's rates if those kept are old, at most every few minutes.
    public func refreshIfStale(now: Date = Date()) {
        let current = rates
        lock.lock()
        let stale = current.map { now.timeIntervalSince($0.updated) > Self.refreshInterval } ?? true
        guard stale, lastAttempt.map({ now.timeIntervalSince($0) > Self.retryInterval }) ?? true else { lock.unlock(); return }
        lastAttempt = now
        lock.unlock()
        URLSession.shared.dataTask(with: URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) { [weak self] data, _, _ in
            guard let self, let data, var fetched = ExchangeRates(response: data) else { return }
            // Rates published long ago are still today's to Rise until the next.
            fetched.updated = max(fetched.updated, now)
            lock.lock(); cached = fetched; loaded = true; lock.unlock()
            if let file {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(fetched).write(to: file, options: .atomic)
            }
        }.resume()
    }
}

/// The currency amounts are converted into: the person's choice, or their region's.
public enum PrimaryCurrency {
    public static let key = "Rise.PrimaryCurrency"
    public static func code(in defaults: UserDefaults = .standard, locale: Locale = .current) -> String {
        defaults.string(forKey: key) ?? locale.currency?.identifier ?? "USD"
    }
    public static func set(_ code: String, in defaults: UserDefaults = .standard) { defaults.set(code, forKey: key) }
}
