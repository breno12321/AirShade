import CoreMotion
import Foundation
#if SWIFT_PACKAGE
import AirShadeCore
#endif

@MainActor protocol MotionProviding: AnyObject {
    var onSample: ((MotionSample) -> Void)? { get set }
    var onLoss: ((String) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor final class HeadphoneMotion: NSObject, MotionProviding, CMHeadphoneMotionManagerDelegate {
    var onSample: ((MotionSample) -> Void)?
    var onLoss: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let manager = CMHeadphoneMotionManager()
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        manager.delegate = self
        manager.startConnectionStatusUpdates()
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            onStatus?("Motion permission denied. Enable AirShade in System Settings → Privacy & Security → Motion & Fitness.")
        default:
            onStatus?("Waiting for compatible AirPods connected to this Mac…")
        }
        startSamples()
    }
    private func startSamples() {
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            Task { @MainActor in
                guard let self, self.running else { return }
                if let error { self.onLoss?(error.localizedDescription); return }
                guard let motion else { return }
                self.onSample?(MotionSample(yaw: motion.attitude.yaw, pitch: motion.attitude.pitch,
                                            time: motion.timestamp))
            }
        }
    }
    func stop() {
        running = false
        manager.stopDeviceMotionUpdates(); manager.stopConnectionStatusUpdates()
    }
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.onStatus?("AirPods connected. Waiting for motion…")
            self.startSamples()
        }
    }
    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.onLoss?("AirPods disconnected") }
    }
}

/// Opt-in development source. Never selected automatically after a hardware failure.
@MainActor final class SimulatedMotion: MotionProviding {
    var onSample: ((MotionSample) -> Void)?
    var onLoss: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var yaw: Double = 0
    var pitch: Double = 0
    var connected = true
    private var timer: Timer?
    func start() {
        onStatus?("SIMULATED motion — no AirPods connected")
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.onSample?(MotionSample(yaw: self.yaw * .pi / 180, pitch: self.pitch * .pi / 180,
                                            time: ProcessInfo.processInfo.systemUptime))
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}
