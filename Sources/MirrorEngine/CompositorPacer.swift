// CompositorPacer.swift — Dirty pixel trick to force frame delivery.
//
// Forces the macOS compositor to continuously redraw by toggling a 4x4 pixel
// window between two nearly-identical colors at TARGET_FPS. Without this, CGDisplayStream
// only delivers ~13fps for mirrored virtual displays because WindowServer
// considers static content "clean" and skips recompositing.
//
// The pixel toggles between #000000 and #010000 (1/255 red channel diff) —
// completely imperceptible on any display, especially e-ink.
//
// Uses CADisplayLink (macOS 14+) for vsync-aligned timing. The 4x4 dirty
// region forces WindowServer to recomposite the target display every frame.
//
// IMPORTANT: The dirty-pixel window must live on the virtual display's
// NSScreen, not NSScreen.main. If the window is on the built-in display,
// only that display's compositor sees dirty regions — the virtual display
// compositor stays idle and CGDisplayStream delivers frames at ~13 FPS.

import AppKit

class CompositorPacer {
    private var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var timer: DispatchSourceTimer?
    private var toggle = false
    private let targetDisplayID: CGDirectDisplayID
    private var tickCount: UInt64 = 0
    private var lastTickTime: Double = 0
    private var tickStatStart: Double = 0
    private var tickGapSumMs: Double = 0
    private var tickGapMaxMs: Double = 0
    private var tickOverruns: UInt64 = 0
    private let dirtySize: CGFloat = {
        guard let raw = ProcessInfo.processInfo.environment["DAYLIGHT_DIRTY_SIZE"],
              let value = Double(raw),
              value >= 1 else { return 32 }
        return CGFloat(value)
    }()

    init(targetDisplayID: CGDirectDisplayID) {
        self.targetDisplayID = targetDisplayID
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    /// Find the NSScreen matching a CGDirectDisplayID.
    private func screenForDisplay(_ displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                return screen
            }
        }
        return nil
    }

    private func startOnMain() {
        // Find the virtual display's NSScreen; fall back to main
        let targetScreen = screenForDisplay(targetDisplayID)
        let screen = targetScreen ?? NSScreen.main
        let onVirtual = targetScreen != nil

        // Avoid AppKit window tab indexing/background bookkeeping work.
        NSWindow.allowsAutomaticWindowTabbing = false

        let dirtySize = self.dirtySize
        let dirtyLabel = "\(Int(dirtySize))x\(Int(dirtySize))"

        // Dirty region to force compositing every frame.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: dirtySize, height: dirtySize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Position at top-left corner of the target screen
        if let s = screen {
            window.setFrameOrigin(NSPoint(x: s.frame.minX, y: s.frame.maxY - dirtySize))
        }
        window.orderFrontRegardless()
        self.window = window

        // Use CADisplayLink from the target screen for vsync-aligned ticking.
        // If virtual display has no NSScreen (mirror mode), use a timer.
        if let targetScreen = targetScreen {
            print("[Pacer] Target screen max FPS: \(targetScreen.maximumFramesPerSecond)")
            let dl = targetScreen.displayLink(target: self, selector: #selector(tick))
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: Float(TARGET_FPS), maximum: Float(TARGET_FPS), preferred: Float(TARGET_FPS))
            dl.add(to: .main, forMode: .common)
            self.displayLink = dl
            print("[Pacer] Started on virtual display \(targetDisplayID) (CADisplayLink, \(dirtyLabel), target \(TARGET_FPS)fps)")
        } else {
            // Fallback: DispatchSourceTimer
            let t = DispatchSource.makeTimerSource(queue: .main)
            let intervalMs = max(4, Int((1000.0 / Double(TARGET_FPS)).rounded()))
            t.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
            t.setEventHandler { [weak self] in
                self?.timerTick()
            }
            t.resume()
            self.timer = t
            print("[Pacer] Started on main screen (timer fallback, \(dirtyLabel), target \(TARGET_FPS)fps) — virtual display \(targetDisplayID) has no NSScreen")
        }

        print("[Pacer] Target display: \(targetDisplayID), on virtual screen: \(onVirtual)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        performToggle()
    }

    private func timerTick() {
        performToggle()
    }

    private func performToggle() {
        let now = CACurrentMediaTime()
        let expectedMs = 1000.0 / Double(TARGET_FPS)
        if lastTickTime > 0 {
            let gapMs = (now - lastTickTime) * 1000.0
            tickGapSumMs += gapMs
            tickGapMaxMs = max(tickGapMaxMs, gapMs)
            if gapMs > (expectedMs * 1.5) {
                tickOverruns += 1
            }
        } else {
            tickStatStart = now
        }
        lastTickTime = now

        toggle.toggle()
        window?.backgroundColor = toggle
            ? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
            : NSColor(red: 1.0 / 255.0, green: 0, blue: 0, alpha: 1)
        tickCount += 1

        let elapsed = now - tickStatStart
        if elapsed >= 5.0 {
            let fps = Double(tickCount) / max(elapsed, 0.001)
            let avgGap = tickCount > 1 ? tickGapSumMs / Double(tickCount - 1) : 0
            print(String(format: "[Pacer] fps: %.1f | avg-gap: %.2fms | max-gap: %.2fms | overruns: %llu",
                         fps, avgGap, tickGapMaxMs, tickOverruns))
            tickCount = 0
            tickStatStart = now
            tickGapSumMs = 0
            tickGapMaxMs = 0
            tickOverruns = 0
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
            self?.timer?.cancel()
            self?.timer = nil
            self?.window?.close()
            self?.window = nil
            print("[Pacer] Compositor pacer stopped")
        }
    }
}
