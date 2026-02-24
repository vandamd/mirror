// DaylightMirrorApp.swift — Menu bar app for Daylight Mirror.
//
// On first launch (or missing permissions), shows a setup wizard window that guides
// the user through granting Screen Recording permission and connecting their
// Daylight DC-1. Once setup is complete, the app lives entirely in the menu bar.

import SwiftUI
import AppKit
import MirrorEngine

// MARK: - App Delegate

/// Owns the MirrorEngine, setup window, and AppKit status menu.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSMenuDelegate {
    let engine = MirrorEngine()
    var setupWindow: NSWindow?

    private var statusItem: NSStatusItem?
    private var menuRefreshTimer: DispatchSourceTimer?
    private var openMenu: NSMenu?
    private var currentMenuLayout: MenuLayout?

    private struct MenuLayout: Equatable {
        let showsRunningControls: Bool
        let showsSetupItem: Bool
    }

    private enum MenuTag {
        static let primary = 1001
        static let status = 1002
        static let fps = 1003
        static let resolution = 1004
        static let autoReconnect = 1005
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] didFinishLaunching")
        setupStatusItem()

        // Show setup window if first run or permissions missing
        if !MirrorEngine.setupCompleted || !MirrorEngine.allPermissionsGranted {
            showSetupWindow()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        guard let button = item.button else { return }
        let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "Daylight Mirror")
        icon?.isTemplate = true
        button.image = icon
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        guard let item = statusItem else { return }
        if openMenu == nil {
            let menu = NSMenu()
            menu.delegate = self
            openMenu = menu
        }
        refreshOpenMenu()
        item.menu = openMenu
        item.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuRefreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(600))
        timer.setEventHandler { [weak self] in
            self?.refreshOpenMenu()
        }
        timer.resume()
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.cancel()
        menuRefreshTimer = nil
        statusItem?.menu = nil
        currentMenuLayout = nil
    }

    private func refreshOpenMenu() {
        guard let menu = openMenu else { return }
        let layout = currentMenuLayoutSignature()
        if menu.items.isEmpty || layout != currentMenuLayout {
            menu.removeAllItems()
            buildMenu(into: menu)
            currentMenuLayout = layout
        } else {
            updateMenuDynamicItems(in: menu)
        }
    }

    private func buildMenu(into menu: NSMenu) {
        let primaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        primaryItem.tag = MenuTag.primary
        configurePrimaryMenuItem(primaryItem)
        menu.addItem(primaryItem)

        if engine.status == .running {
            let restartItem = NSMenuItem(title: "Restart", action: #selector(restartMirror), keyEquivalent: "")
            restartItem.target = self
            restartItem.image = NSImage(systemSymbolName: "restart", accessibilityDescription: "Restart")
            menu.addItem(restartItem)
        }

        let statusItem = NSMenuItem(title: statusMenuText(), action: nil, keyEquivalent: "")
        statusItem.tag = MenuTag.status
        statusItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Status")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let fpsItem = NSMenuItem(title: fpsMenuText(), action: nil, keyEquivalent: "")
        fpsItem.tag = MenuTag.fps
        fpsItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "FPS")
        fpsItem.isEnabled = false
        menu.addItem(fpsItem)

        menu.addItem(.separator())

        let resolutionItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        resolutionItem.tag = MenuTag.resolution
        resolutionItem.image = NSImage(systemSymbolName: "rectangle.resize", accessibilityDescription: "Resolution")
        let resolutionSubmenu = NSMenu(title: "Resolution")
        for res in DisplayResolution.allCases {
            let item = NSMenuItem(title: "\(res.label) (\(res.rawValue))", action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = res
            item.state = (engine.resolution == res) ? .on : .off
            resolutionSubmenu.addItem(item)
        }
        resolutionItem.submenu = resolutionSubmenu
        menu.addItem(resolutionItem)

        if engine.status == .running {
            menu.addItem(.separator())
            menu.addItem(makeBrightnessSliderItem())
            menu.addItem(makeWarmthSliderItem())
        }

        if !MirrorEngine.allPermissionsGranted {
            let setupItem = NSMenuItem(title: "Open Setup…", action: #selector(openSetup), keyEquivalent: "")
            setupItem.target = self
            setupItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Open Setup")
            menu.addItem(setupItem)
        }

        menu.addItem(.separator())

        let autoReconnectItem = NSMenuItem(title: "Start mirroring on USB connect", action: #selector(toggleAutoReconnect), keyEquivalent: "")
        autoReconnectItem.tag = MenuTag.autoReconnect
        autoReconnectItem.target = self
        autoReconnectItem.image = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "Auto-reconnect on USB")
        autoReconnectItem.state = engine.autoMirrorEnabled ? .on : .off
        menu.addItem(autoReconnectItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quitItem)

    }

    private func currentMenuLayoutSignature() -> MenuLayout {
        MenuLayout(
            showsRunningControls: engine.status == .running,
            showsSetupItem: !MirrorEngine.allPermissionsGranted
        )
    }

    private func configurePrimaryMenuItem(_ item: NSMenuItem) {
        let primaryIsStop = (engine.status == .running || engine.status == .starting)
        item.title = primaryIsStop ? "Stop Mirror" : "Start Mirror"
        item.action = primaryIsStop ? #selector(stopMirror) : #selector(startMirror)
        item.target = self
        item.image = NSImage(
            systemSymbolName: primaryIsStop ? "stop.fill" : "play.fill",
            accessibilityDescription: primaryIsStop ? "Stop Mirror" : "Start Mirror"
        )
        item.isEnabled = (engine.status != .stopping)
    }

    private func statusMenuText() -> String {
        if case .error(let msg) = engine.status {
            return "Error: \(msg)"
        } else if engine.status == .starting {
            return "Starting..."
        } else if engine.status == .stopping {
            return "Stopping..."
        } else if engine.status == .running {
            return engine.clientCount > 0 ? "Daylight connected" : "Waiting for client..."
        } else {
            return engine.deviceDetected ? "DC-1 detected via USB" : "No device connected"
        }
    }

    private func fpsMenuText() -> String {
        if engine.status == .running {
            return String(format: "FPS: %.0f", engine.fps)
        }
        return "FPS: --"
    }

    private func updateMenuDynamicItems(in menu: NSMenu) {
        if let primaryItem = menu.item(withTag: MenuTag.primary) {
            configurePrimaryMenuItem(primaryItem)
        }

        if let statusItem = menu.item(withTag: MenuTag.status) {
            statusItem.title = statusMenuText()
        }

        if let fpsItem = menu.item(withTag: MenuTag.fps) {
            fpsItem.title = fpsMenuText()
        }

        if let resolutionItem = menu.item(withTag: MenuTag.resolution),
           let resolutionSubmenu = resolutionItem.submenu {
            for item in resolutionSubmenu.items {
                guard let res = item.representedObject as? DisplayResolution else { continue }
                item.state = (engine.resolution == res) ? .on : .off
            }
        }

        if let autoReconnectItem = menu.item(withTag: MenuTag.autoReconnect) {
            autoReconnectItem.state = engine.autoMirrorEnabled ? .on : .off
        }
    }

    private func makeBrightnessSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 285, height: 30))

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")
        iconView.contentTintColor = .labelColor
        container.addSubview(iconView)

        let sliderPos = engine.brightness == 0 ? 0.0 : sqrt(Double(engine.brightness) / 255.0)
        let slider = NSSlider(value: sliderPos, minValue: 0, maxValue: 1, target: self, action: #selector(brightnessSliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        item.view = container
        return item
    }

    private func makeWarmthSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 285, height: 30))

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "flame", accessibilityDescription: "Warmth")
        iconView.contentTintColor = .labelColor
        container.addSubview(iconView)

        let slider = NSSlider(value: Double(engine.warmth), minValue: 0, maxValue: 255, target: self, action: #selector(warmthSliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        item.view = container
        return item
    }

    @objc private func startMirror() {
        if !MirrorEngine.hasScreenRecordingPermission() {
            showSetupWindow()
            return
        }
        Task { await engine.start() }
    }

    @objc private func openSetup() {
        showSetupWindow()
    }

    @objc private func stopMirror() {
        engine.stop()
    }

    @objc private func restartMirror() {
        engine.stop()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            await engine.start()
        }
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let newRes = sender.representedObject as? DisplayResolution else { return }
        guard engine.resolution != newRes else { return }
        engine.resolution = newRes
        if engine.status == .running {
            restartMirror()
        }
    }

    @objc private func toggleAutoReconnect(_ sender: NSMenuItem) {
        engine.autoMirrorEnabled.toggle()
        sender.state = engine.autoMirrorEnabled ? .on : .off
    }

    @objc private func brightnessSliderChanged(_ sender: NSSlider) {
        engine.setBrightness(MirrorEngine.brightnessFromSliderPos(sender.doubleValue))
    }

    @objc private func warmthSliderChanged(_ sender: NSSlider) {
        engine.setWarmth(Int(sender.doubleValue.rounded()))
    }

    @objc func quit() {
        engine.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    func showSetupWindow() {
        // Temporarily show in dock so the window is visible
        NSApplication.shared.setActivationPolicy(.regular)

        let setupView = SetupView(engine: engine, onComplete: { [weak self] in
            self?.dismissSetupWindow()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daylight Mirror"
        window.contentView = NSHostingView(rootView: setupView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    func dismissSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
        // Back to menu bar only
        NSApplication.shared.setActivationPolicy(.accessory)
        MirrorEngine.setupCompleted = true
    }
}

// MARK: - App Entry Point

@main
struct DaylightMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Setup Wizard

enum SetupStep: Int, CaseIterable {
    case welcome
    case permissions
    case ready
}

struct SetupView: View {
    @ObservedObject var engine: MirrorEngine
    let onComplete: () -> Void

    @State private var step: SetupStep = .welcome
    @State private var hasScreenRecording = MirrorEngine.hasScreenRecordingPermission()
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SetupStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 520)
        .onDisappear { pollTimer?.invalidate() }
    }

    var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "display")
                .font(.system(size: 56))
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                Text("Daylight Mirror")
                    .font(.largeTitle.weight(.medium))
                Text("Mirror your Mac to a Daylight DC-1")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow("bolt.fill", "60 FPS, under 11ms latency")
                featureRow("eye", "Lossless greyscale — no compression artifacts")
                featureRow("slider.horizontal.3", "Brightness and warmth controls in the menu")
            }
            .padding(.horizontal, 60)
            .padding(.top, 8)

            Spacer()

            Button(action: { withAnimation { step = .permissions } }) {
                Text("Get Started")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
    }

    func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
        }
    }

    var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("macOS Permissions")
                .font(.title2.weight(.medium))

            Text("Daylight Mirror needs Screen Recording permission to work.\nGrant it, then come back here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                permissionCard(
                    granted: hasScreenRecording,
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Captures your display to send to the Daylight",
                    action: {
                        MirrorEngine.requestScreenRecordingPermission()
                        startPermissionPolling()
                    }
                )
            }
            .padding(.horizontal, 40)

            if hasScreenRecording {
                Text("All permissions granted")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Text("After granting permission, you may need to\nquit and reopen the app for it to take effect.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            HStack {
                Button("Back") { withAnimation { step = .welcome } }
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: { withAnimation { step = .ready } }) {
                    Text("Continue")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasScreenRecording)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    func permissionCard(granted: Bool, icon: String, title: String,
                        description: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(granted ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06))
        )
    }

    func startPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            hasScreenRecording = MirrorEngine.hasScreenRecordingPermission()
            if hasScreenRecording {
                pollTimer?.invalidate()
            }
        }
    }

    var readyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're all set")
                .font(.title2.weight(.medium))

            VStack(alignment: .leading, spacing: 12) {
                howItWorksRow("1", "Connect your Daylight DC-1 via USB-C")
                howItWorksRow("2", "Click Start Mirror in the menu bar")
                howItWorksRow("3", "Your Mac creates a virtual 4:3 display and starts streaming")
                howItWorksRow("4", "The Daylight app launches automatically")
            }
            .padding(.horizontal, 50)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.callout)
                    Text("Daylight Mirror lives in your menu bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Auto-reconnect detects your Daylight when plugged in")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: {
                pollTimer?.invalidate()
                onComplete()
            }) {
                Text("Done")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
    }

    func howItWorksRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}
