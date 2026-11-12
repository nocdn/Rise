import AppKit

/// Relaunch on rise://flags and in rise://settings: Chrome's own quits Rise without opening it
/// again, as it relaunches Chrome's way. Rise quits as ⌘Q does, saving its tabs, and opens again
/// once it's gone.
@MainActor enum RiseRelaunch {
    static let handler = "riseRelaunch"
    static func install(on page: WebPage) {
        page.addMessageHandler(handler, world: .page) { message in
            guard message.frame.isMain, message.page?.url?.scheme == "rise" else { return }
            relaunch()
        }
        page.addUserScript(script, world: .page, mainFrameOnly: true, handlers: [handler])
    }
    static func relaunch() {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Opened once it's gone; a quit called off isn't waited on for long, or Rise would open
        // again whenever it next quits.
        wait.arguments = ["-c", "for _ in $(/usr/bin/seq 150); do /bin/kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$2\"; /bin/sleep 0.2; done", "sh",
                          "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundlePath]
        guard (try? wait.run()) != nil else { return }
        NSApp.terminate(nil)
    }
    // Chrome's pages ask for it with chrome.send: rise://flags's Relaunch, Settings' restart and relaunch.
    static let script = #"""
    (() => {
      if (location.protocol !== 'chrome:' || !window.chrome?.send || chrome.send.rise) return;
      const send = chrome.send;
      chrome.send = Object.assign(function (name, args) {
        if (name === 'restartBrowser' || name === 'restart' || name === 'relaunch') {
          riseHandlers.riseRelaunch.postMessage(null); return;
        }
        return send.apply(this, arguments);
      }, {rise: true});
    })();
    """#
}
