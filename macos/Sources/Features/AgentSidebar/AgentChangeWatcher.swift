import AppKit
import CoreServices

/// Triggers an immediate sidebar refresh when something changes, so the once-a-second poll
/// is only a fallback (it still catches processes starting and exiting).
///
/// - Focus: checked after every pass of the event loop. The check is a single comparison,
///   so switching tabs or splits is reflected on the next frame.
/// - Hook status: an FSEvents stream on the status directory.
@MainActor
final class AgentChangeWatcher: NSObject {
    private let onChange: () -> Void
    private var lastFocusedID: UUID?
    private var lastKeyWindow: ObjectIdentifier?
    private var stream: FSEventStreamRef?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidUpdate(_:)),
            name: NSApplication.didUpdateNotification,
            object: nil)

        startStatusStream()
    }

    @objc private func appDidUpdate(_ notification: Notification) {
        let keyWindow = NSApp.keyWindow
        let focusedID = (keyWindow?.windowController as? BaseTerminalController)?.focusedSurface?.id
        let windowID = keyWindow.map(ObjectIdentifier.init)
        guard focusedID != lastFocusedID || windowID != lastKeyWindow else { return }
        lastFocusedID = focusedID
        lastKeyWindow = windowID
        onChange()
    }

    private func startStatusStream() {
        let directory = AgentStatusStore.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            Task { @MainActor in AgentMonitor.shared.statusDidChange() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
