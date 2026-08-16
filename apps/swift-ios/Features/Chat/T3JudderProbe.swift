import SwiftUI
import UIKit

/// Embedded-only geometry probe. Samples the window / navigation bar / safe area for
/// 2.5 seconds after a thread opens and logs every CHANGE to the shared import log,
/// so a top-bar judder can be traced to the exact moving element and frame time.
enum T3JudderProbe {
    private static var driver: Driver?

    static func start() {
        guard driver == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }
        driver = Driver(window: window)
        driver?.start()
    }

    static func stop() {
        driver?.stop()
        driver = nil
    }

    private final class Driver {
        private var displayLink: CADisplayLink?
        private let startTime = CACurrentMediaTime()
        private var last: String?
        private weak var window: UIWindow?
        private weak var navBar: UINavigationBar?

        init(window: UIWindow) {
            self.window = window
            self.navBar = Self.findView(of: UINavigationBar.self, in: window)
        }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let window else { return }
            let t = CACurrentMediaTime() - startTime
            if t > 2.5 {
                stop()
                T3JudderProbe.driver = nil
                return
            }
            let safeTop = window.safeAreaInsets.top
            let winY = window.frame.origin.y
            let winH = window.frame.size.height
            let barY = navBar.map { $0.convert($0.bounds, to: nil).origin.y } ?? -1
            let barH = navBar?.bounds.height ?? -1

            // Track the transcript's collection view and the embedded root view:
            // whatever visibly moves must show up in one of these frames.
            let transcript = Self.findTranscript(in: window)
            let transcriptY = transcript?.convert(transcript!.bounds, to: nil).origin.y ?? -1
            let transcriptH = transcript?.bounds.height ?? -1
            let rootView = Self.findRootView(in: window)
            let rootY = rootView?.convert(rootView!.bounds, to: nil).origin.y ?? -1
            let rootH = rootView?.bounds.height ?? -1

            let line = String(
                format: "probe t=%.3f safeTop=%.1f winY=%.1f winH=%.1f barY=%.1f barH=%.1f transY=%.1f transH=%.1f rootY=%.1f rootH=%.1f",
                t, safeTop, winY, winH, barY, barH, transcriptY, transcriptH, rootY, rootH
            )
            guard line != last else { return }
            last = line
            T3JudderProbeLog.write(line)
        }

        private static func findTranscript(in root: UIView) -> UIView? {
            if root.accessibilityIdentifier == "thread-transcript" { return root }
            for subview in root.subviews {
                if let found = findTranscript(in: subview) { return found }
            }
            return nil
        }

        private static func findRootView(in root: UIView) -> UIView? {
            // The embedded root hosting view is the direct UIView of a hosting
            // controller; the probe just needs A stable content view, so use the
            // first subview of the window that covers the full width.
            let candidates = root.subviews.filter {
                $0.frame.width >= root.frame.width * 0.8 && $0.bounds.height > 200
            }
            if let first = candidates.first {
                for subview in first.subviews {
                    if let found = findRootView(in: subview) { return found }
                }
                return first
            }
            return nil
        }

        private static func findView<T: UIView>(of type: T.Type, in root: UIView) -> T? {
            if let match = root as? T { return match }
            for subview in root.subviews {
                if let found = findView(of: type, in: subview) { return found }
            }
            return nil
        }
    }
}

private enum T3JudderProbeLog {
    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logURL = docs.appendingPathComponent("t3-live-import-log.txt")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
