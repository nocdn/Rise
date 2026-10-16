import UIKit

/// Geometry measured from Arc's horizontal switcher. The cards behind the focused one
/// compress towards the left edge; the next card overlaps its right-hand edge.
@MainActor struct TabDeckLayout {
    let size: CGSize
    let stripHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let count: Int
    let focus: CGFloat

    var step: CGFloat { max(1, size.width*0.57) }
    var cardSize: CGSize {
        let width = max(1, size.width*0.70)
        let available = max(1, size.height-topInset-bottomInset-TabSwitcherView.titleHeight)
        return CGSize(width: width, height: min(available, max(1, (size.height-stripHeight)*0.70)))
    }
    func frame(at slot: Int) -> CGRect {
        let distance = CGFloat(slot)-focus
        let depth = min(4, max(0, -distance))
        let scale = 1-0.020*depth
        let last = CGFloat(max(0, count-1))
        let edge = count < 2 ? 1 : min(1, max(0, focus-(last-1)))
        let middle = size.width*(0.55-0.05*edge)
        let displacement = distance >= 0 ? distance*step
            : size.width*0.18*distance/(1+0.5*max(0, -distance-1))
        let card = cardSize
        let proposedTop = (size.height-card.height)/2+size.height*0.015
        let top = max(topInset+TabSwitcherView.titleHeight, min(proposedTop, size.height-bottomInset-card.height))
        let body = CGSize(width: card.width*scale, height: card.height*scale)
        return CGRect(x: middle+displacement-body.width/2,
                      y: top+(card.height-body.height)/2-TabSwitcherView.titleHeight,
                      width: body.width, height: body.height+TabSwitcherView.titleHeight)
    }

    /// Only the centred card names its page. Adjacent favicons remain visible, but
    /// title text fades away before the next title starts to appear.
    func titleOpacity(at slot: Int) -> CGFloat {
        let progress = min(1, max(0, (0.5-abs(CGFloat(slot)-focus))/0.4))
        return progress*progress*(3-2*progress)
    }

    func shadeOpacity(at slot: Int) -> CGFloat {
        min(0.36, max(0, focus-CGFloat(slot))*0.14)
    }
}

/// Tab-specific springs: keep Summarise's independently tuned motion unchanged.
enum TabDeckMotion {
    static let entryScale = SummariseSpring(26, 1, 8)
    static let entryMove = SummariseSpring(25, 1, 9)
    static let entryShape = SummariseSpring(28, 1)
    static let stack = SummariseSpring(22, 1)
    static let releaseScale = SummariseSpring(18, 0.86)
    static let releaseMove = SummariseSpring(16, 0.92)
    static let open = SummariseSpring(21, 0.96, 7)
    static let cancel = SummariseSpring(22, 1)
}
