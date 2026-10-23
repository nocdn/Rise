#if DEBUG
import UIKit

@MainActor enum ToastInteractionAudit {
    static func exercise(_ browser: BrowserViewController,check: (String,Bool) throws -> Void) async throws {
        let tracked = ToastInteraction.tracked
        try check("downward-drag-tracks-one-to-one",tracked(CGPoint(x: 0,y: 160)).y == 160)
        try check("upward-drag-has-stronger-progressive-resistance",tracked(CGPoint(x: 0,y: -160)).y > -22 && tracked(CGPoint(x: 0,y: -160)).y < -15)
        try check("small-drags-have-resistance-from-the-start",abs(tracked(CGPoint(x: 10,y: -10)).x) < 4 && abs(tracked(CGPoint(x: 10,y: -10)).y) < 4)
        try check("downward-scaling-mirrors-entry",ToastInteraction.dismissalScale(at: 0,travel: 90) == 1 && abs(ToastInteraction.dismissalScale(at: 45,travel: 90)-0.95) < 0.0001 && abs(ToastInteraction.dismissalScale(at: 120,travel: 90)-0.9) < 0.0001)
        for x in [-300.0,-80,-1,1,80,300] {
            let p = tracked(CGPoint(x: x,y: 0))
            try check("sideways-resistance-is-symmetric-and-continuous-\(x)",abs(p.x) < min(abs(x),22) && abs(p.x+tracked(CGPoint(x: -x,y: 0)).x) < 0.0001)
            try check("interrupted-resistance-keeps-visible-position-\(x)",abs(tracked(ToastInteraction.untracked(p)).x-p.x) < 0.0001)
        }
        try check("upward-flick-does-not-dismiss",!ToastInteraction.shouldDismiss(offset: CGPoint(x: 0,y: -12),velocity: CGPoint(x: 0,y: -3000)))
        try check("sideways-flick-does-not-dismiss",!ToastInteraction.shouldDismiss(offset: CGPoint(x: 25,y: 0),velocity: CGPoint(x: 3000,y: 0)))
        try check("sideways-flick-tolerates-a-small-downward-component",!ToastInteraction.shouldDismiss(offset: CGPoint(x: 25,y: 4),velocity: CGPoint(x: 80,y: 200),intendedVelocity: CGPoint(x: 3000,y: 200)))
        try check("reversing-a-downward-drag-returns-instead-of-dismissing",!ToastInteraction.shouldDismiss(offset: CGPoint(x: 0,y: 80),velocity: CGPoint(x: 0,y: -300)))
        try check("short-fast-downward-flick-dismisses",ToastInteraction.shouldDismiss(offset: CGPoint(x: 0,y: 4),velocity: CGPoint(x: 0,y: 1800)))
        var previousDuration = Double.infinity
        for speed in [0.0,400,900,1800,3500,5000] {
            let flight = ToastInteraction.flight(from: CGPoint(x: 0,y: 40),velocity: CGPoint(x: 0,y: speed),exitY: 170)
            try check("stronger-flicks-leave-faster-\(speed)",flight.duration <= previousDuration)
            try check("flight-completes-only-after-clearing-the-screen-\(speed)",flight.points.last!.y >= 170 && flight.points.dropLast().allSatisfy { $0.y < 170 })
            try check("flight-always-moves-outwards-\(speed)",zip(flight.points,flight.points.dropFirst()).allSatisfy { $0.y < $1.y })
            let target: CGFloat = 170+ToastInteraction.flightClearance+speed*0.22
            let firstSpeed = (ToastInteraction.spring(from: 40,to: target,velocity: speed,stiffness: 280,time: 0.000001)-40)/0.000001
            try check("flight-carries-exact-release-velocity-\(speed)",abs(firstSpeed-speed) < 1)
            if speed >= 1800 {
                let visibleSpeeds = zip(flight.points,flight.points.dropFirst()).map { ($1.y-$0.y)*120 }
                try check("hard-flick-does-not-brake-before-leaving-\(speed)",visibleSpeeds.min()! >= speed*0.98)
            }
            previousDuration = flight.duration
        }
        let repository = GitHubRepository(url: URL(string: "https://github.com/owner/motion"))!
        func install() -> GitHubStarToast {
            let toast = GitHubStarToast(repository: repository)
            browser.githubStarToast = toast
            browser.view.insertSubview(toast,belowSubview: browser.bottomBar)
            toast.place(above: browser.bottomBar.frame.minY,in: browser.view.bounds,safeTop: browser.view.safeAreaInsets.top)
            toast.layoutIfNeeded(); return toast
        }
        for translation in [CGPoint(x: 0,y: -180),CGPoint(x: 180,y: 0),CGPoint(x: -180,y: 0)] {
            let toast = install()
            toast.beginDrag(); toast.trackDrag(translation)
            let from = toast.layer.transform
            toast.endDrag(velocity: .zero)
            let animation = toast.layer.animation(forKey: "toast.appear") as! CAKeyframeAnimation
            let initial = (animation.values!.first as! NSValue).caTransform3DValue
            try check("native-resisted-drag-returns-from-current-position-\(translation)",abs(initial.m41-from.m41) < 0.001 && abs(initial.m42-from.m42) < 0.001 && !toast.dismissed)
            try check("native-resisted-drag-returns-to-rest-\(translation)",CATransform3DIsIdentity((animation.values!.last as! NSValue).caTransform3DValue))
            toast.dismiss(animated: false)
        }
        let cancel = install()
        cancel.beginDrag(); cancel.trackDrag(CGPoint(x: 20,y: 70)); cancel.endDrag(velocity: CGPoint(x: 0,y: 3000),cancelled: true)
        try check("cancelled-drag-always-restores-the-toast",!cancel.dismissed && CATransform3DIsIdentity(cancel.layer.transform))
        cancel.dismiss(animated: false)
        let fling = install()
        try check("right-padding-is-reduced-by-three-points",abs(fling.bounds.width-fling.label.intrinsicContentSize.width-69) < 0.001)
        fling.setMessage("Already starred")
        fling.beginDrag(); fling.trackDrag(CGPoint(x: 40,y: 20))
        let releaseScale = fling.layer.transform.m11
        try check("downward-finger-tracking-scales-the-toast-subtly",releaseScale < 1 && releaseScale > 0.9)
        try check("tracking-requests-a-fixed-full-refresh-rate",fling.motion.minimumFPS == Float(min(120,browser.view.window!.screen.maximumFramesPerSecond)))
        fling.endDrag(velocity: CGPoint(x: 500,y: 2600))
        let animation = fling.layer.animation(forKey: "toast.dismiss") as! CAKeyframeAnimation
        try check("native-flick-keeps-the-active-width-animation",fling.layer.animation(forKey: "toast.width") != nil)
        try check("native-flick-duration-responds-to-velocity",animation.duration < 0.15)
        let scales = animation.values!.map { ($0 as! NSValue).caTransform3DValue.m11 }
        try check("native-flick-preserves-opacity",fling.alpha == 1)
        try check("native-flick-scales-down-continuously-from-the-finger-position",abs(scales.first!-releaseScale) < 0.0001 && abs(scales.last!-0.9) < 0.0001 && zip(scales,scales.dropFirst()).allSatisfy { $0 >= $1 })
        try check("native-flick-requests-the-devices-full-refresh-rate",animation.preferredFrameRateRange.preferred == Float(min(120,browser.view.window!.screen.maximumFramesPerSecond)) && animation.preferredFrameRateRange.minimum == animation.preferredFrameRateRange.preferred)
        let cleanupDeadline = CACurrentMediaTime()+1
        while (fling.superview != nil || fling.motion.isHoldingRate), CACurrentMediaTime() < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check("native-flight-cleans-up-view-and-frame-rate-request",fling.superview == nil && !fling.motion.isHoldingRate)
        browser.githubStarToast = nil
    }
}
#endif
