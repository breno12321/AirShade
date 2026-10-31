import AppKit
import SwiftUI
import Observation
import ServiceManagement
import CoreMotion
#if SWIFT_PACKAGE
import AirShadeCore
#endif

@MainActor @Observable final class AppModel {
    var engine = PrivacyEngine()
    var motionStatus = "Connect your AirPods to this Mac to get started."
    var captureStatus = "Screen Recording permission is needed for blur."
    var shortcutStatus = ""
    var screenAllowed = CGPreflightScreenCaptureAccess()
    var captureCheckMessage = ""
    func recheckCaptureAccess() {
        refreshSetupStatus()
        captureCheckMessage = screenAllowed
            ? "Screen Recording access confirmed."
            : "macOS has not granted access to this running copy. If AirShade is already enabled in Settings, quit and reopen this app. After a signing change, turn its permission off and on once."
    }
    func openCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    var motionStarted = false
    var motionAuthorization = CMHeadphoneMotionManager.authorizationStatus()
    var statusTime = ProcessInfo.processInfo.systemUptime
    private var lastPermissionCheck: TimeInterval = 0
    var motionAllowed: Bool { simulated == nil && motionAuthorization == .authorized }
    var motionDenied: Bool { motionAuthorization == .denied || motionAuthorization == .restricted }
    var calibrated: Bool { (engine.state == .tracking || engine.state == .covered) && hasFreshMotion }
    var completedSetupSteps: Int { (motionAllowed ? 1 : 0) + (screenAllowed ? 1 : 0) + (calibrated ? 1 : 0) }
    func refreshSetupStatus() {
        motionAuthorization = CMHeadphoneMotionManager.authorizationStatus()
        screenAllowed = CGPreflightScreenCaptureAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if screenAllowed { captureCheckMessage = "" }
        if screenAllowed && captureStatus == "Screen Recording permission is needed for blur." {
            captureStatus = "Screen Recording access is already enabled."
        }
        // Existing authorization can be reused without presenting a new permission prompt.
        if motionAllowed && !motionStarted { connectMotion() }
    }
    func openMotionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")!)
    }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var loginError = ""
    var screenLayout: String { didSet { saveLayout() } }
    var screenSeparation: Double { didSet { saveLayout() } }
    // Captured polarity avoids assuming which yaw sign a headphone uses for left/right.
    var yawPolarity: Double { didSet { saveLayout() } }
    var layoutMessage = "Choose the side of your second screen. Calibrate its direction for the best fit."
    var calibrationCountdown = 0
    var hasMainReference = false
    private var mainReference: MotionSample?
    private var calibrationTask: Task<Void, Never>?
    var displaySecondYaw: Double { screenLayout == "single" ? 0 : (screenLayout == "left" ? -screenSeparation : screenSeparation) }
    var displayHeadYaw: Double { engine.horizontal * yawPolarity }
    var reverseHorizontalTracking: Bool {
        get { yawPolarity > 0 }
        set { yawPolarity = newValue ? 1 : -1 }
    }
    private func saveLayout() {
        UserDefaults.standard.set(screenLayout, forKey: "screenLayout")
        UserDefaults.standard.set(screenSeparation, forKey: "screenSeparation")
        UserDefaults.standard.set(yawPolarity, forKey: "yawPolarity")
        UserDefaults.standard.set(2, forKey: "yawMappingVersion")
        engine.secondScreenYaw = displaySecondYaw * yawPolarity
    }
    func changeLayout(_ layout: String) {
        calibrationTask?.cancel(); calibrationCountdown = 0
        mainReference = nil; hasMainReference = false
        screenLayout = layout
        layoutMessage = "Look at your main screen to start calibration. Protection pauses during setup."
    }
    func captureScreen(main: Bool) {
        calibrationTask?.cancel()
        pause()
        if !motionStarted { connectMotion() }
        let expectedLayout = screenLayout
        layoutMessage = main ? "Look at the center of your MAIN screen…" : "Look at the center of your \(screenLayout.uppercased()) screen…"
        calibrationCountdown = 3
        calibrationTask = Task { [weak self] in
            for remaining in (0...2).reversed() {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.calibrationCountdown = remaining
            }
            guard let self, !Task.isCancelled, expectedLayout == self.screenLayout else { return }
            guard self.hasFreshMotion, let sample = self.engine.latest else {
                self.layoutMessage = "No fresh motion. Connect your AirPods and try again."; return
            }
            if main {
                self.mainReference = sample; self.hasMainReference = true
                self.layoutMessage = "Main screen saved. Now capture your \(self.screenLayout) screen."
            } else if let reference = self.mainReference, self.now - reference.time < 60 {
                let degrees = PrivacyEngine.wrapped(sample.yaw - reference.yaw) * 180 / .pi
                guard abs(degrees) >= 5, abs(degrees) <= 90 else {
                    self.layoutMessage = "The screens must be 5–90° apart. Capture the main screen, then turn toward the second screen."; return
                }
                self.yawPolarity = (degrees > 0 ? 1 : -1) * (self.screenLayout == "left" ? -1 : 1)
                self.screenSeparation = abs(degrees)
                self.mainReference = nil; self.hasMainReference = false
                self.layoutMessage = "Both directions saved. Look back at your MAIN screen and choose Calibrate & enable."
            } else {
                self.mainReference = nil; self.hasMainReference = false
                self.layoutMessage = "Capture the main screen again, then the second screen within a minute."
            }
        }
    }
    var threshold: Double { didSet { UserDefaults.standard.set(threshold, forKey: "threshold"); engine.threshold = threshold } }
    var transition: Double { didSet { UserDefaults.standard.set(transition, forKey: "transition"); engine.transition = transition } }
    var blurStrength: Double { didSet { UserDefaults.standard.set(blurStrength, forKey: "blurStrength") } }
    let simulated: SimulatedMotion?
    private let motion: MotionProviding
    private let overlay = OverlayService()
    private let shortcuts = GlobalShortcuts()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(simulation: Bool = false) {
        let defaults = UserDefaults.standard
        let screens = NSScreen.screens
        let detectedLayout = screens.count > 1 ? (screens[1].frame.midX < screens[0].frame.midX ? "left" : "right") : "single"
        screenLayout = defaults.string(forKey: "screenLayout") ?? detectedLayout
        screenSeparation = defaults.object(forKey: "screenSeparation") as? Double ?? 35
        // Headphone yaw increases toward the user's left; the diagram increases right.
        // Version 1 incorrectly assumed identical coordinate directions.
        let initialPolarity = defaults.integer(forKey: "yawMappingVersion") >= 2
            ? (defaults.object(forKey: "yawPolarity") as? Double ?? -1) : -1
        yawPolarity = initialPolarity
        defaults.set(initialPolarity, forKey: "yawPolarity")
        defaults.set(2, forKey: "yawMappingVersion")
        threshold = defaults.object(forKey: "threshold") as? Double ?? 15
        transition = defaults.object(forKey: "transition") as? Double ?? 18
        blurStrength = defaults.object(forKey: "blurStrength") as? Double ?? 36
        let mock = simulation ? SimulatedMotion() : nil
        simulated = mock; motion = mock ?? HeadphoneMotion()
        engine.threshold = threshold; engine.transition = transition
        engine.secondScreenYaw = displaySecondYaw * yawPolarity
        motion.onSample = { [weak self] sample in
            guard let self else { return }
            self.engine.receive(sample)
            self.motionStatus = simulation ? "SIMULATED motion is active" : "Live AirPods motion received"
            self.render()
        }
        motion.onLoss = { [weak self] reason in
            guard let self else { return }
            self.motionStatus = reason; self.cancelLayoutCapture(); self.engine.loseTracking(); self.render()
        }
        motion.onStatus = { [weak self] in self?.motionStatus = $0 }
        overlay.onCaptureStatus = { [weak self] in self?.captureStatus = $0 }
        shortcuts.onToggle = { [weak self] in self?.toggle() }
        shortcuts.onRecenter = { [weak self] in self?.recenter() }
        shortcuts.register()
        shortcutStatus = shortcuts.registered ? "Global shortcuts ready" : "A shortcut is unavailable. Use the menu or shield buttons."
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusTime = self.now
                if self.now - self.lastPermissionCheck >= 2 {
                    self.lastPermissionCheck = self.now
                    self.refreshSetupStatus()
                }
                self.engine.tick(at: self.now); self.render()
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.render() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSetupStatus() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.cancelLayoutCapture(); self.engine.loseTracking(); self.render()
                    if name == NSWorkspace.didWakeNotification && self.motionStarted {
                        self.motion.stop(); self.motion.start()
                    }
                }
            })
        }
    }
    var isEnabled: Bool { engine.state != .disabled }
    var hasFreshMotion: Bool { engine.latest.map { max(now, statusTime) - $0.time >= 0 && max(now, statusTime) - $0.time < 0.5 } ?? false }
    var stateTitle: String {
        switch engine.state {
        case .disabled: return "Paused"
        case .calibrating: return "Look forward to calibrate"
        case .tracking: return "Watching your head position"
        case .covered: return "Screen covered"
        case .recoveryRequired: return "Resume required"
        }
    }
    func connectMotion() {
        motionStarted = true; motion.stop(); motion.start()
    }
    func requestCapture() {
        screenAllowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !screenAllowed {
            captureStatus = "Allow AirShade in System Settings → Privacy & Security → Screen Recording. You may need to restart AirShade."
            captureCheckMessage = "After enabling AirShade, quit and reopen it if macOS requests a restart. If access still fails, turn the existing AirShade permission off and on once."
            openCaptureSettings()
        }
    }
    func enable() {
        guard calibrationCountdown == 0 else { return }
        if !motionStarted { connectMotion() }
        guard let sample = engine.latest, hasFreshMotion else {
            motionStatus = "Waiting for fresh motion. Wear compatible AirPods connected to this Mac, then try again."
            return
        }
        engine.enable(at: now); engine.receive(sample)
        _ = engine.calibrate(at: now); render()
    }
    func pause() { engine.pause(); render() }
    func toggle() { isEnabled ? pause() : enable() }
    func recenter() {
        guard isEnabled else { return }
        if !engine.calibrate(at: now) { motionStatus = "Fresh AirPods motion is required before resuming." }
        render()
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Approve AirShade in System Settings → General → Login Items." : ""
        } catch { loginError = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    private func render() {
        let message: String
        switch engine.state {
        case .recoveryRequired: message = "Tracking stopped. Look at your MAIN screen, then resume to recalibrate."
        case .calibrating: message = "Look at your MAIN screen and resume to calibrate."
        default: message = "Look back to clear your screen."
        }
        overlay.update(coverage: engine.coverage, horizontal: displayHeadYaw, vertical: engine.vertical,
                       message: message, canResume: hasFreshMotion, strength: blurStrength,
                       resume: { [weak self] in self?.recenter() }, pause: { [weak self] in self?.pause() })
    }
    private func cancelLayoutCapture() {
        calibrationTask?.cancel(); calibrationCountdown = 0
        mainReference = nil; hasMainReference = false
    }
    func shutdown() {
        cancelLayoutCapture()
        timer?.invalidate(); motion.stop(); overlay.clear(); shortcuts.unregister()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
