import XCTest
@testable import AirShadeCore

final class PrivacyEngineTests: XCTestCase {
    func sample(_ yaw: Double = 0, _ pitch: Double = 0, at time: Double) -> MotionSample {
        MotionSample(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180, time: time)
    }
    func ready(center: Double = 0) -> PrivacyEngine {
        var engine = PrivacyEngine()
        engine.enable(at: 0)
        engine.receive(sample(center, at: 0))
        XCTAssertTrue(engine.calibrate(at: 0))
        return engine
    }
    func testSecondScreenAndEntireSweepStayClearOnEitherSide() {
        for side in [-1.0, 1.0] {
            var engine = ready()
            engine.secondScreenYaw = 45 * side
            for (index, yaw) in [0.0, 20, 45, 52].enumerated() {
                engine.receive(sample(yaw * side, at: Double(index + 1) * 0.4))
                XCTAssertEqual(engine.state, .tracking)
                XCTAssertEqual(engine.coverage, 0)
            }
        }
    }
    func testSecondScreenOuterEdgeUsesComfortAndTransition() {
        var engine = ready(); engine.secondScreenYaw = 40
        engine.receive(sample(65, at: 0.6))
        XCTAssertEqual(engine.state, .covered)
        XCTAssertGreaterThan(engine.coverage, 0.5)
        engine.receive(sample(80, at: 1.2))
        XCTAssertEqual(engine.coverage, 1)
        engine.receive(sample(40, at: 1.6))
        engine.receive(sample(40, at: 1.9))
        XCTAssertEqual(engine.state, .tracking)
    }
    func testSecondScreenDoesNotWidenOppositeSideOrPitch() {
        XCTAssertEqual(PrivacyEngine.distanceFromScreens(yaw: -25, pitch: 0, secondScreenYaw: 40), 25)
        XCTAssertEqual(PrivacyEngine.distanceFromScreens(yaw: 40, pitch: 25, secondScreenYaw: 40), 25)
        XCTAssertEqual(PrivacyEngine.distanceFromScreens(yaw: 20, pitch: 0, secondScreenYaw: 40), 0)
    }
    func testSecondScreenOffsetsSurviveExplicitRecovery() {
        var engine = ready(); engine.secondScreenYaw = -40
        engine.loseTracking(); engine.receive(sample(20, at: 0.4))
        XCTAssertEqual(engine.state, .recoveryRequired)
        XCTAssertTrue(engine.calibrate(at: 0.4))
        engine.receive(sample(-20, at: 0.8))
        XCTAssertEqual(engine.state, .tracking)
        XCTAssertEqual(engine.secondScreenYaw, -40)
    }
    func testCalibrationRequiresFreshSample() {
        var engine = PrivacyEngine(); engine.enable(at: 0)
        XCTAssertFalse(engine.calibrate(at: 0))
        engine.receive(sample(at: 0))
        XCTAssertFalse(engine.calibrate(at: 0.6))
        engine.receive(sample(30, at: 0.7))
        XCTAssertTrue(engine.calibrate(at: 0.7))
        engine.receive(sample(30, at: 0.8))
        XCTAssertEqual(engine.state, .tracking); XCTAssertEqual(engine.coverage, 0)
    }
    func testWrapAcrossPiDoesNotCover() {
        var engine = ready(center: 179)
        engine.receive(sample(-179, at: 0.4))
        XCTAssertEqual(engine.state, .tracking)
        XCTAssertLessThan(abs(engine.horizontal), 3)
    }
    func testYawAndPitchCoverAtThresholdAndFullTransition() {
        for pitch in [false, true] {
            var engine = ready()
            engine.receive(sample(pitch ? 0 : 10, pitch ? 10 : 0, at: 0.4))
            XCTAssertEqual(engine.coverage, 0)
            engine.receive(sample(pitch ? 0 : 24, pitch ? 24 : 0, at: 0.8))
            XCTAssertEqual(engine.state, .covered)
            XCTAssertGreaterThan(engine.coverage, 0.4); XCTAssertLessThan(engine.coverage, 0.6)
            engine.receive(sample(pitch ? 0 : 50, pitch ? 50 : 0, at: 1.2))
            XCTAssertEqual(engine.coverage, 1)
        }
    }
    func testReturnMarginAndDwell() {
        var engine = ready()
        engine.receive(sample(45, at: 0.4))
        engine.receive(sample(14, at: 0.8))
        engine.receive(sample(14, at: 1.2))
        XCTAssertEqual(engine.state, .covered)
        engine.receive(sample(0, at: 1.3))
        engine.receive(sample(0, at: 1.4))
        XCTAssertEqual(engine.state, .covered)
        engine.receive(sample(0, at: 1.7))
        XCTAssertEqual(engine.state, .tracking)
    }
    func testStaleSamplesLatchUntilExplicitCalibration() {
        var engine = ready()
        engine.tick(at: 2)
        XCTAssertEqual(engine.state, .recoveryRequired); XCTAssertEqual(engine.coverage, 1)
        engine.receive(sample(at: 2.1))
        XCTAssertEqual(engine.state, .recoveryRequired)
        XCTAssertTrue(engine.calibrate(at: 2.1)); XCTAssertEqual(engine.coverage, 0)
    }
    func testGapCannotBeHiddenByNewSample() {
        var engine = ready()
        engine.receive(sample(at: 3))
        XCTAssertEqual(engine.state, .recoveryRequired)
    }
    func testDisconnectionInvalidatesOldSamples() {
        var engine = ready(); engine.loseTracking()
        XCTAssertFalse(engine.calibrate(at: 0.1))
        engine.receive(sample(10, at: 0.2))
        XCTAssertEqual(engine.state, .recoveryRequired)
        XCTAssertTrue(engine.calibrate(at: 0.2))
    }
    func testPauseAlwaysClearsAndDisabledIgnoresLoss() {
        var engine = ready(); engine.loseTracking(); engine.pause()
        engine.loseTracking(); engine.tick(at: 10)
        XCTAssertEqual(engine.state, .disabled); XCTAssertEqual(engine.coverage, 0)
    }
    func testLossWhilePausedInvalidatesCalibrationCandidate() {
        var engine = PrivacyEngine()
        engine.receive(sample(at: 0))
        engine.loseTracking()
        XCTAssertNil(engine.latest)
        XCTAssertEqual(engine.state, .disabled)
    }
    func testReturnDwellResetsWhenHeadMovesAwayAgain() {
        var engine = ready()
        engine.receive(sample(45, at: 0.4))
        engine.receive(sample(0, at: 0.8))
        engine.receive(sample(45, at: 0.9))
        engine.receive(sample(0, at: 1.2))
        engine.receive(sample(0, at: 1.3))
        XCTAssertEqual(engine.state, .covered)
        engine.receive(sample(0, at: 1.5))
        XCTAssertEqual(engine.state, .tracking)
    }
    func testInvalidSamplesCannotRefreshWatchdog() {
        var engine = ready()
        engine.receive(MotionSample(yaw: .nan, pitch: 0, time: 1.9))
        engine.tick(at: 2)
        XCTAssertEqual(engine.state, .recoveryRequired)
    }
}
