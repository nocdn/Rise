import Foundation

/// The shared text-node writer for currency and time conversion. Inverse patches let either
/// feature restore its own values when the other has since changed the same paragraph.
enum PageTextEdits {
    static let script = #"""
    (() => {
      if (globalThis.riseTextEdits) return;
      function distribute(text, lengths, parts) {
        const starts = new Map(parts.map(p => [p.start, p])), covered = new Uint8Array(text.length);
        for (const p of parts) covered.fill(1, p.start+1, p.end);
        let at = 0;
        return lengths.map(length => {
          const end = at+length, original = text.slice(at, end), patches = [];
          let written = '';
          for (let i = at; i < end; i++) written += starts.has(i) ? starts.get(i).text : covered[i] ? '' : text[i];
          for (const p of [...parts].sort((a, b) => a.start-b.start)) {
            const first = Math.max(at, p.start), last = Math.min(end, p.end);
            if (last <= first) continue;
            const previous = patches[patches.length-1], replacement = p.start >= at ? p.text : '';
            // A sign, integer, decimal and currency code form one recognizable value. Do not
            // later mistake a standalone matching number elsewhere for the amount we wrote.
            if (previous && first-previous.end <= 1) {
              previous.original += text.slice(previous.end, last);
              previous.written += text.slice(previous.end, first)+replacement;
              previous.end = last;
            } else patches.push({original: text.slice(first, last), written: replacement, end: last});
          }
          at = end;
          return {original, written, patches};
        });
      }
      function restore(record, current) {
        if (record.written === current) return record.original;
        // A page or another converter changed this node. Restore only the exact values we
        // still recognize; never overwrite somebody else's edit or guess among duplicates.
        let text = current;
        for (const patch of [...(record.patches || [])].reverse()) {
          if (!patch.written || patch.original === patch.written) continue;
          const known = record.written ?? record.lastWritten ?? '';
          if (known.indexOf(patch.written) !== known.lastIndexOf(patch.written)) continue;
          const at = text.indexOf(patch.written);
          if (at < 0 || at !== text.lastIndexOf(patch.written)) continue;
          text = text.slice(0, at)+patch.original+text.slice(at+patch.written.length);
        }
        return text;
      }
      function record(previous, piece) {
        if (!previous) return {...piece, lastWritten: piece.written, changes: 1};
        return {...piece, lastWritten: piece.written, original: restore(previous, piece.original), changes: previous.changes+1,
          patches: (previous.patches || []).filter(p => p.written && piece.original.includes(p.written)).concat(piece.patches)};
      }
      globalThis.riseTextEdits = {distribute, restore, record};
    })();
    """#
}
