import AppKit

// ghostty-copy-toast
// Background helper: when text is copied while Ghostty is the frontmost app,
// show a fading bottom-right toast with the character/line count.
// Clipboard contents are only counted — never stored, logged, or transmitted.

// MARK: - Toast

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ToastController {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(_ text: String) {
        hideTimer?.invalidate()
        panel?.orderOut(nil)
        panel = nil

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(srgbRed: 0.753, green: 0.792, blue: 0.961, alpha: 1) // #c0caf5
        label.alignment = .center
        label.sizeToFit()

        let hPad: CGFloat = 16, vPad: CGFloat = 10
        let contentRect = NSRect(x: 0, y: 0,
                                 width: label.frame.width + hPad * 2,
                                 height: label.frame.height + vPad * 2)

        let panel = ToastPanel(contentRect: contentRect,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: contentRect)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(srgbRed: 0.478, green: 0.635, blue: 0.968, alpha: 0.55).cgColor // #7aa2f7

        label.frame = NSRect(x: hPad, y: vPad, width: label.frame.width, height: label.frame.height)
        bg.addSubview(label)
        panel.contentView = bg

        // Place bottom-right of whichever screen the pointer is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let vf = screen?.visibleFrame {
            let margin: CGFloat = 24
            panel.setFrameOrigin(NSPoint(x: vf.maxX - contentRect.width - margin,
                                         y: vf.minY + margin))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        })
    }
}

// MARK: - Clipboard watcher

final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private let toast = ToastController()
    private let ghosttyBundleID = "com.mitchellh.ghostty"

    init() { lastChangeCount = pasteboard.changeCount }

    func start() {
        // .common mode so the timer keeps firing during UI tracking.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Only react to copies made while Ghostty is frontmost. This also
        // sidesteps password-manager copies (their app is frontmost, not Ghostty).
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID,
              let string = pasteboard.string(forType: .string), !string.isEmpty
        else { return }

        toast.show(Self.describe(string))
    }

    private static func describe(_ s: String) -> String {
        let chars = s.count
        let newlines = s.filter { $0 == "\n" }.count
        let lines = s.hasSuffix("\n") ? newlines : newlines + 1

        let nf = NumberFormatter(); nf.numberStyle = .decimal
        func fmt(_ n: Int) -> String { nf.string(from: NSNumber(value: n)) ?? "\(n)" }
        let charWord = chars == 1 ? "character" : "characters"
        let lineWord = lines == 1 ? "line" : "lines"
        return "Copied \(fmt(chars)) \(charWord) · \(fmt(lines)) \(lineWord)"
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
let watcher = ClipboardWatcher()
watcher.start()
app.run()
