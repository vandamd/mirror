// USBDeviceMonitor.swift — USB device detection via ADB polling.
//
// Polls `adb devices` every 2 seconds to detect USB connect/disconnect.
// Calls onDeviceConnected/onDeviceDisconnected on the main queue when state changes.
// Used by MirrorEngine for auto-start/stop based on DC-1 presence.

import Foundation

class USBDeviceMonitor {
    private var timer: DispatchSourceTimer?
    private var wasConnected = false
    var onDeviceConnected: (() -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    func start() {
        guard ADBBridge.isAvailable() else {
            print("[USB] No adb available — device monitoring disabled")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let connected = ADBBridge.connectedDevice() != nil
            if connected && !self.wasConnected {
                self.wasConnected = true
                print("[USB] Device connected")
                DispatchQueue.main.async { self.onDeviceConnected?() }
            } else if !connected && self.wasConnected {
                self.wasConnected = false
                print("[USB] Device disconnected")
                DispatchQueue.main.async { self.onDeviceDisconnected?() }
            }
        }
        t.resume()
        timer = t
        print("[USB] Device monitoring started (polling adb every 2s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var isDeviceConnected: Bool { wasConnected }
}
