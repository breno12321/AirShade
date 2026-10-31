import Foundation

public struct MotionSample: Sendable {
    public let yaw: Double
    public let pitch: Double
    public let time: TimeInterval
    public init(yaw: Double, pitch: Double, time: TimeInterval) {
        self.yaw = yaw; self.pitch = pitch; self.time = time
    }
}

public enum PrivacyState: String, Sendable {
    case disabled, calibrating, tracking, covered, recoveryRequired
}

public struct PrivacyEngine {
    public private(set) var state: PrivacyState = .disabled
    public private(set) var coverage: Double = 0
    public private(set) var horizontal: Double = 0
    public private(set) var vertical: Double = 0
    public private(set) var latest: MotionSample?
    /// Signed yaw of the second screen relative to the main screen, in degrees.
    public var secondScreenYaw: Double = 0
    public var threshold: Double = 15
    public var transition: Double = 18
    private var center: MotionSample?
    private var startedAt: TimeInterval = 0
    private var returnSince: TimeInterval?
    private var previousTime: TimeInterval?
    public init() {}

    public static func wrapped(_ radians: Double) -> Double {
        atan2(sin(radians), cos(radians))
    }

    /// The entire sweep between displays is clear, with the comfort margin outside it.
    public static func distanceFromScreens(yaw: Double, pitch: Double, secondScreenYaw: Double) -> Double {
        let side = secondScreenYaw.isFinite ? min(90, max(-90, secondScreenYaw)) : 0
        let low = min(0, side), high = max(0, side)
        let outside = max(low - yaw, yaw - high, 0)
        return max(outside, abs(pitch))
    }

    public mutating func enable(at time: TimeInterval) {
        guard state == .disabled else { return }
        startedAt = time; state = .calibrating
        center = nil; latest = nil; previousTime = nil
        coverage = 1
    }

    public mutating func pause() {
        state = .disabled; coverage = 0; center = nil
        returnSince = nil; previousTime = nil
    }

    /// Explicit user action only. Never called automatically when a device reconnects.
    @discardableResult public mutating func calibrate(at time: TimeInterval) -> Bool {
        guard state != .disabled, let sample = latest,
              time - sample.time >= 0, time - sample.time < 0.5 else { return false }
        center = sample; horizontal = 0; vertical = 0
        returnSince = nil; previousTime = sample.time
        state = .tracking; coverage = 0
        return true
    }

    public mutating func loseTracking() {
        latest = nil
        guard state != .disabled else { return }
        state = .recoveryRequired; coverage = 1
        center = nil; returnSince = nil; previousTime = nil; latest = nil
    }

    public mutating func tick(at time: TimeInterval) {
        guard state != .disabled, state != .recoveryRequired else { return }
        if time - (latest?.time ?? startedAt) >= 2 { loseTracking() }
    }

    public mutating func receive(_ sample: MotionSample) {
        guard sample.yaw.isFinite, sample.pitch.isFinite, sample.time.isFinite else { return }
        // Detect a gap even if the watchdog and a newly arrived sample race.
        if state != .disabled && state != .recoveryRequired,
           sample.time - (latest?.time ?? startedAt) >= 2 { loseTracking() }
        if let latest, sample.time < latest.time { return }
        latest = sample
        guard state == .tracking || state == .covered, let center else { return }
        let dt = max(0, sample.time - (previousTime ?? sample.time))
        previousTime = sample.time
        let alpha = 1 - exp(-dt / 0.08)
        let yaw = Self.wrapped(sample.yaw - center.yaw) * 180 / .pi
        let pitch = Self.wrapped(sample.pitch - center.pitch) * 180 / .pi
        horizontal += alpha * (yaw - horizontal)
        vertical += alpha * (pitch - vertical)
        let angle = Self.distanceFromScreens(yaw: horizontal, pitch: vertical, secondScreenYaw: secondScreenYaw)
        let begin = min(30, max(2, threshold))
        let span = min(30, max(5, transition))
        if state == .tracking && angle > begin { state = .covered }
        if state == .covered {
            if angle <= max(0, begin - 3) {
                if returnSince == nil { returnSince = sample.time }
                if sample.time - (returnSince ?? sample.time) >= 0.25 {
                    state = .tracking; coverage = 0; returnSince = nil
                    return
                }
            } else { returnSince = nil }
            // Retain a small cover until the return dwell completes.
            coverage = max(0.08, min(1, (angle - begin) / span))
        } else { coverage = 0 }
    }
}
