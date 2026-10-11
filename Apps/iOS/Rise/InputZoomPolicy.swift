import WebKit

/// WebKit honors an author-defined maximum scale for input focus even when manual scaling is allowed.
/// This changes viewport metadata, preserving the site's input fonts and layout directives.
@MainActor enum InputZoomPolicy {
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
    }

    static let source = #"""
    (() => {
        const head = document.head;
        if (!head) return;
        let fallbackScale = window.visualViewport?.scale || 1;

        function apply() {
            let viewports = [...head.querySelectorAll('meta')].filter(meta =>
                meta.name.trim().toLowerCase() === 'viewport');
            if (!viewports.length) {
                const meta = document.createElement('meta');
                meta.name = 'viewport';
                head.appendChild(meta);
                viewports = [meta];
            }
            for (const meta of viewports) {
                const parts = meta.content.split(/[,;]/).map(part => part.trim()).filter(Boolean);
                const value = key => {
                    const part = parts.find(part => part.split('=')[0].trim().toLowerCase() === key);
                    return part ? Number.parseFloat(part.slice(part.indexOf('=') + 1)) : NaN;
                };
                const initial = value('initial-scale');
                const minimum = value('minimum-scale');
                const scale = Math.max(Number.isFinite(initial) && initial > 0 ? initial : fallbackScale,
                                       Number.isFinite(minimum) && minimum > 0 ? minimum : 0);
                const kept = parts.filter(part => part.split('=')[0].trim().toLowerCase() !== 'maximum-scale');
                kept.push(`maximum-scale=${scale}`);
                const content = kept.join(', ');
                if (meta.content !== content) meta.content = content;
            }
        }

        apply();
        // Pages without an explicit initial scale settle at an auto-fit scale after their first layout.
        requestAnimationFrame(() => {
            fallbackScale = window.visualViewport?.scale || 1;
            apply();
        });
        // Sites and SPAs can insert or replace viewport metadata after the initial document load.
        new MutationObserver(apply).observe(head, {
            childList: true, subtree: true, attributes: true, attributeFilter: ['content', 'name']
        });
    })();
    """#
}
