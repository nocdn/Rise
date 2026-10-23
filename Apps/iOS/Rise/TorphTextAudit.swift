#if DEBUG
import UIKit

@MainActor enum TorphTextAudit {
    static let argument = "-RiseTorphTextAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("TorphTextAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                try await exercise(browser,folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"),atomically: true,encoding: .utf8)
            } catch { try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"),atomically: true,encoding: .utf8) }
        }
    }
    private static func exercise(_ browser: BrowserViewController,folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String,_ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks,options: [.sortedKeys,.prettyPrinted]).write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func capture(_ name: String) throws {
            let window = browser.view.window!
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds,afterScreenUpdates: false) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let repository = GitHubRepository(url: URL(string: "https://github.com/nocdn/Rise"))!
        func install(action: MobileGitHubStarrer.Action = .star) -> GitHubStarToast {
            let toast = GitHubStarToast(repository: repository,action: action)
            browser.githubStarToast = toast
            browser.view.insertSubview(toast,belowSubview: browser.bottomBar)
            toast.place(above: browser.bottomBar.frame.minY,in: browser.view.bounds,safeTop: browser.view.safeAreaInsets.top)
            toast.appear(); return toast
        }
        browser.view.layoutIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("-RiseToastInteractionAudit") {
            try await ToastInteractionAudit.exercise(browser,check: check)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-RiseTorphWidthAudit") {
            func holdCommit(_ milliseconds: Int) { Thread.sleep(forTimeInterval: Double(milliseconds)/1000) }
            for outcome in [MobileGitHubStarrer.Outcome.starred,.alreadyStarred,.unstarred,.alreadyUnstarred] {
                for stall in [0,450] {
                    let toast = install(action: outcome == .unstarred || outcome == .alreadyUnstarred ? .unstar : .star)
                    try await Task.sleep(for: .milliseconds(650))
                    let initial = toast.bounds.width
                    CATransaction.begin()
                    toast.finish(outcome)
                    holdCommit(stall)
                    CATransaction.commit()
                    var samples: [[String: Double]] = []
                    let start = CACurrentMediaTime()
                    for _ in 0..<24 {
                        browser.view.setNeedsLayout(); browser.view.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(8))
                        samples.append(["t":CACurrentMediaTime()-start,"root":toast.layer.presentation()?.bounds.width ?? -1,"surface":toast.subviews[0].layer.presentation()?.bounds.width ?? -1,"initial":initial,"final":toast.bounds.width])
                    }
                    try JSONSerialization.data(withJSONObject: samples,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("width-\(outcome)-\(stall)ms-commit.json"))
                    try check("\(outcome)-\(stall)ms-commit-painted-background-has-intermediate-width",samples.contains { abs($0["surface"]! - initial) > 1 && abs($0["surface"]! - toast.bounds.width) > 1 })
                    toast.dismiss(animated: false)
                }
            }
            return
        }
        // Values evaluated by the pinned TypeScript implementation's parseEasing.
        for (input, expected) in [(0.01,0.05246013190502469),(0.1,0.47975464162673004),(0.25,0.8435142987085287),(0.5,0.9778245961651955),(0.75,0.9982713546960718)] {
            try check("curve-matches-upstream-at-\(input)",abs(TorphAnimation.cubic(input)-expected) < 0.00000001)
        }
        for outcome in [MobileGitHubStarrer.Outcome.starred,.alreadyStarred,.unstarred,.alreadyUnstarred] {
            for delay in [0,1,12,45,150,600] {
                let toast = install(action: outcome == .unstarred || outcome == .alreadyUnstarred ? .unstar : .star), startWidth = toast.bounds.width, center = toast.center.x
                var widthDuringLayout: CGFloat = -1
                toast.label.onAnimationStart = {
                    browser.view.setNeedsLayout(); browser.view.layoutIfNeeded()
                    widthDuringLayout = toast.bounds.width
                }
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                toast.finish(outcome)
                let name = "\(outcome)-\(delay)ms"
                let animation = TorphAnimation.keyframes(in: toast.layer,key: "toast.width")
                let widths = animation?.values?.compactMap { ($0 as? NSValue)?.cgSizeValue.width } ?? []
                try check(name+"-parent-layout-cannot-preempt-resizing",abs(widthDuringLayout-startWidth) < 0.01)
                try check(name+"-always-has-an-explicit-width-transition",toast.widthAnimationCount == 1 && widths.count >= 32)
                try check(name+"-starts-at-the-previous-size-even-before-first-commit",abs((widths.first ?? 0)-startWidth) < 0.01)
                try check(name+"-ends-at-the-measured-content-width",abs((widths.last ?? 0)-toast.bounds.width) < 0.01 && abs(startWidth-toast.bounds.width) > 1)
                try check(name+"-uses-torphs-original-400ms-duration",abs((animation?.duration ?? 0)-0.4) < 0.001)
                let sampleIndex = widths.count/4
                let expected = TorphAnimation.mix(startWidth,toast.bounds.width,TorphAnimation.cubic(Double(sampleIndex)/Double(widths.count-1)))
                try check(name+"-uses-torphs-original-cubic-curve",abs(widths[sampleIndex]-expected) < 0.01)
                try check(name+"-morphs-the-text-instead-of-replacing-the-label",toast.label.animating && toast.label.fragments.values.contains { $0.layer.animation(forKey: "torph.position") != nil })
                for _ in 0..<12 { browser.view.setNeedsLayout(); browser.view.layoutIfNeeded() }
                try check(name+"-layout-storm-keeps-the-animation",toast.layer.animation(forKey: "toast.width") != nil && abs(toast.center.x-center) < 0.01)
                try await Task.sleep(for: .milliseconds(35))
                let visual = toast.layer.presentation()?.bounds.width ?? 0
                try check(name+"-has-visible-intermediate-width",abs(visual-startWidth) > 0.01 && abs(visual-toast.bounds.width) > 0.01)
                if delay == 150 && outcome == .starred { try capture("morphing-starred") }
                try await Task.sleep(for: .milliseconds(410))
                try check(name+"-settles-without-leaving-old-glyphs",!toast.label.animating && toast.label.subviews.count == toast.label.fragments.count)
                toast.dismiss(animated: false); browser.githubStarToast = nil
            }
        }
        let toast = install()
        toast.label.onAnimationStart = { browser.view.setNeedsLayout(); browser.view.layoutIfNeeded() }
        let messages = ["Already starred","Starring repository...","Starred repository","Couldn’t star repository","Sign in to GitHub to star"]
        for i in 0..<80 {
            let previous = toast.layer.presentation()?.bounds.width ?? toast.bounds.width
            toast.setMessage(messages[i%messages.count])
            let animation = TorphAnimation.keyframes(in: toast.layer,key: "toast.width")
            let first = (animation?.values?.first as? NSValue)?.cgSizeValue.width ?? previous
            try check("rapid-update-\(i)-continues-from-screen",abs(first-previous) < 7)
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(430))
        try check("rapid-updates-settle-on-the-last-message",toast.label.text == messages[79%messages.count] && !toast.label.animating)
        try check("interrupted-morphs-do-not-leak-exiting-fragments",toast.label.subviews.count == toast.label.fragments.count)
        let firstRun = TorphSizeTransition()
        let timing = TorphAnimation.Timing.standard
        _ = firstRun.retarget(from: 100,to: 200,timing: timing,now: 0)
        let state = firstRun.run!
        try check("same-target-resumes-instead-of-restarting-the-opening-sliver",firstRun.retarget(from: 120,to: 200.2,timing: timing,now: 0.05) == nil && firstRun.run!.started == state.started)
        let run = firstRun.retarget(from: 120,to: 250,timing: timing,now: 0.05)!
        try check("changed-target-carries-current-position",abs(run.from-state.value(0.05)) < 0.001)
        try check("carried-easing-has-exact-endpoints",abs(run.timing.curve(0)) < 0.001 && run.timing.curve(1) == 1)
        let bounded = TorphAnimation.carried({ $0*$0 },velocity: 10000)
        try check("momentum-carry-is-finite-and-bounded",(0...1000).allSatisfy { bounded(Double($0)/1000).isFinite && bounded(Double($0)/1000) < 1.11 })
        toast.dismiss(animated: false); browser.githubStarToast = nil
        let text = TorphTextView()
        text.frame = CGRect(x: 20,y: 140,width: browser.view.bounds.width-40,height: 90)
        browser.view.addSubview(text)
        text.setText("a",animated: false)
        let departing = text.fragments.values.first!
        text.setText("b")
        let arriving = text.fragments.values.first!
        let enterScale = TorphAnimation.keyframes(in: arriving.layer,key: "torph.scale")!
        let exitScale = TorphAnimation.keyframes(in: departing.layer,key: "torph.scale")!
        let enterFade = TorphAnimation.keyframes(in: arriving.layer,key: "torph.opacity")!
        let exitFade = TorphAnimation.keyframes(in: departing.layer,key: "torph.opacity")!
        try check("individual-entry-scales-from-upstreams-095",abs((enterScale.values!.first as! NSNumber).doubleValue-0.95) < 0.000001)
        try check("individual-exit-scales-to-upstreams-095",abs((exitScale.values!.last as! NSNumber).doubleValue-0.95) < 0.000001)
        try check("individual-entry-fades-over-200ms",abs(enterFade.duration-0.2) < 0.000001)
        try check("individual-entry-fade-is-delayed-100ms",abs(enterFade.beginTime-enterScale.beginTime-0.1) < 0.005)
        try check("individual-exit-fades-over-100ms",abs(exitFade.duration-0.1) < 0.000001)
        text.setText("abcdef",animated: false)
        let groupDeparting = text.fragments.values.first!
        text.setText("uvwxyz")
        let groupArriving = text.fragments.values.first!
        let groupEnterScale = TorphAnimation.keyframes(in: groupArriving.layer,key: "torph.scale")!
        let groupExitScale = TorphAnimation.keyframes(in: groupDeparting.layer,key: "torph.scale")!
        let groupEnterFade = TorphAnimation.keyframes(in: groupArriving.layer,key: "torph.opacity")!
        let groupExitFade = TorphAnimation.keyframes(in: groupDeparting.layer,key: "torph.opacity")!
        try check("replacement-group-entry-scales-from-upstreams-08",abs((groupEnterScale.values!.first as! NSNumber).doubleValue-0.8) < 0.000001)
        try check("replacement-group-exit-scales-to-upstreams-08",abs((groupExitScale.values!.last as! NSNumber).doubleValue-0.8) < 0.000001)
        try check("replacement-group-entry-fades-over-140ms",abs(groupEnterFade.duration-0.14) < 0.000001)
        try check("replacement-group-exit-fades-over-180ms",abs(groupExitFade.duration-0.18) < 0.000001)
        try check("replacement-group-entry-has-no-delay",abs(groupEnterFade.beginTime-groupEnterScale.beginTime) < 0.005)
        text.setText("Starring repository...",animated: false)
        var starts = 0, completes = 0, cancels = 0
        text.onAnimationStart = { starts += 1 }; text.onAnimationComplete = { completes += 1 }; text.onAnimationCancel = { cancels += 1 }
        for value in ["Starred repository","Already starred","hello world","world hello","café 👩🏽‍💻 ready","مرحبا بالعالم","你好 世界","first\nsecond\n","","new words"] {
            text.setText(value)
            try check("accessible-whole-value-\(starts)",text.accessibilityLabel == value && text.subviews.allSatisfy(\.accessibilityElementsHidden))
            try check("unicode-glyph-layout-remains-finite-\(starts)",text.fragments.values.allSatisfy { $0.frame.minX.isFinite && $0.frame.minY.isFinite && $0.frame.width.isFinite })
            try await Task.sleep(for: .milliseconds(14))
        }
        try await Task.sleep(for: .milliseconds(430))
        try check("interruption-fires-one-terminal-callback-per-morph",starts == completes+cancels && completes == 1)
        let before = starts
        text.setText("new words")
        try check("same-value-is-a-no-op",starts == before)
        text.disabled = true; text.setText("Disabled motion")
        try check("disabled-mode-renders-whole-text-without-animation",!text.animating && text.text == "Disabled motion" && text.fragments.values.allSatisfy { $0.layer.animationKeys()?.isEmpty != false })
        text.disabled = false; text.setText("new animation")
        text.removeFromSuperview()
        try check("detaching-cancels-animations-and-cleanup-timers",!text.animating)
        var visual = install()
        visual.finish(.starred)
        try await Task.sleep(for: .milliseconds(450)); try capture("starred-torph-toast")
        if ProcessInfo.processInfo.arguments.contains("-RiseTorphPreview") {
            visual.dismiss(animated: false)
            visual = install()
            for _ in 0..<20 {
                visual.setMessage("Starring repository..."); try await Task.sleep(for: .milliseconds(900))
                visual.setMessage("Starred repository"); try await Task.sleep(for: .milliseconds(900))
                visual.setMessage("Already starred"); try await Task.sleep(for: .milliseconds(900))
            }
        }
        visual.dismiss(animated: false); browser.githubStarToast = nil
    }
}
#endif
