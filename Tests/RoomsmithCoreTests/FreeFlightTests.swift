import Testing
import Foundation
import simd
@testable import RoomsmithCore

struct FreeFlightTests {
    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double = 1e-9) -> Bool { simd_length(a - b) <= tol }

    @Test func forwardFollowsYawAtLevelPitch() {
        // Yaw 0 looks north (+Y); yaw 90 looks west (-X).
        #expect(near(FreeFlight.direction(for: .init(forward: 1), yawDeg: 0, pitchDeg: 0), SIMD3(0, 1, 0)))
        #expect(near(FreeFlight.direction(for: .init(forward: 1), yawDeg: 90, pitchDeg: 0), SIMD3(-1, 0, 0)))
        #expect(near(FreeFlight.direction(for: .init(forward: -1), yawDeg: 0, pitchDeg: 0), SIMD3(0, -1, 0)))
    }

    @Test func forwardFollowsPitch() {
        let up = FreeFlight.direction(for: .init(forward: 1), yawDeg: 0, pitchDeg: 45)
        #expect(up.z > 0.7 && up.y > 0.7 && abs(simd_length(up) - 1) < 1e-12)
        let down = FreeFlight.direction(for: .init(forward: 1), yawDeg: 0, pitchDeg: -89)
        #expect(down.z < -0.999 && abs(down.y) < 0.02)
    }

    @Test func strafeFollowsRightAndVerticalIsWorldUp() {
        #expect(near(FreeFlight.direction(for: .init(strafe: 1), yawDeg: 0, pitchDeg: 0), SIMD3(1, 0, 0)))
        #expect(near(FreeFlight.direction(for: .init(strafe: 1), yawDeg: 90, pitchDeg: 0), SIMD3(0, 1, 0)))
        // Strafing ignores pitch; E/Q only change Z whatever the view direction is.
        #expect(near(FreeFlight.direction(for: .init(strafe: 1), yawDeg: 30, pitchDeg: -60), SIMD3(cos(30 * .pi / 180), sin(30 * .pi / 180), 0)))
        for (yaw, pitch) in [(0.0, 0.0), (47.0, -60.0), (-120.0, 85.0)] {
            #expect(near(FreeFlight.direction(for: .init(vertical: 1), yawDeg: yaw, pitchDeg: pitch), SIMD3(0, 0, 1)))
            #expect(near(FreeFlight.direction(for: .init(vertical: -1), yawDeg: yaw, pitchDeg: pitch), SIMD3(0, 0, -1)))
        }
    }

    @Test func diagonalInputIsNormalised() {
        let d = FreeFlight.direction(for: .init(forward: 1, strafe: 1, vertical: 1), yawDeg: 20, pitchDeg: 10)
        #expect(simd_length(d) <= 1 + 1e-12)
        #expect(abs(simd_length(d) - 1) < 1e-12)
        // Partial input (a stick) is not stretched to full length.
        #expect(abs(simd_length(FreeFlight.direction(for: .init(forward: 0.4), yawDeg: 0, pitchDeg: 0)) - 0.4) < 1e-12)
    }

    @Test func oneTimeConstantReachesTheExpectedSpeed() {
        var f = FreeFlight()
        let move = f.advance(dt: FreeFlight.responseSeconds, input: .init(forward: 1), yawDeg: 0, pitchDeg: 0)
        #expect(abs(f.velocity.y - 1580.3) < 0.5, "\(f.velocity)")
        #expect(abs(f.velocity.x) < 1e-9 && abs(f.velocity.z) < 1e-9)
        #expect(abs(move.y - 94.8) < 0.5, "\(move)")
        #expect(f.isMoving)
    }

    @Test func speedStepsScaleTheCruiseSpeed() {
        func settled(_ step: FlightSpeedStep) -> Double {
            var f = FreeFlight()
            for _ in 0 ..< 200 { f.advance(dt: 0.05, input: .init(forward: 1, step: step), yawDeg: 0, pitchDeg: 0) }
            return f.velocity.y
        }
        #expect(abs(settled(.normal) - FreeFlight.baseSpeedMmPerSecond) < 1e-6)
        #expect(abs(settled(.fast) / settled(.normal) - 3) < 1e-9)
        #expect(abs(settled(.slow) / settled(.normal) - 0.3) < 1e-9)
        // Same time, same input: the first step is 3x / 0.3x as far.
        func firstStep(_ step: FlightSpeedStep) -> Double {
            var f = FreeFlight()
            return f.advance(dt: 0.05, input: .init(forward: 1, step: step), yawDeg: 0, pitchDeg: 0).y
        }
        #expect(abs(firstStep(.fast) / firstStep(.normal) - 3) < 1e-9)
        #expect(abs(firstStep(.slow) / firstStep(.normal) - 0.3) < 1e-9)
    }

    @Test func glidesToAnExactStopWithoutInput() {
        var f = FreeFlight()
        for _ in 0 ..< 100 { f.advance(dt: 0.016, input: .init(forward: 1, strafe: 1), yawDeg: 10, pitchDeg: 0) }
        #expect(f.isMoving)
        var last = simd_length(f.velocity)
        var steps = 0
        while f.isMoving, steps < 1000 {
            f.advance(dt: 0.016, input: .init(), yawDeg: 10, pitchDeg: 0)
            let now = simd_length(f.velocity)
            #expect(now < last, "speed must fall monotonically")
            last = now
            steps += 1
        }
        #expect(!f.isMoving && f.velocity == .zero)
        #expect(steps < 1000)
    }

    @Test func resultDoesNotDependOnTheFrameRate() {
        func run(dt: Double, steps: Int) -> (v: SIMD3<Double>, p: SIMD3<Double>) {
            var f = FreeFlight(); var p = SIMD3<Double>.zero
            for _ in 0 ..< steps { p += f.advance(dt: dt, input: .init(forward: 1, strafe: 0.5, vertical: 0.2), yawDeg: 25, pitchDeg: -15) }
            return (f.velocity, p)
        }
        let a = run(dt: 0.016, steps: 50), b = run(dt: 0.008, steps: 100)
        #expect(simd_length(a.v - b.v) < 1e-6, "velocity is exact for constant input")
        #expect(simd_length(a.p - b.p) < 2, "\(a.p) vs \(b.p)")
    }

    @Test func zeroNegativeAndNonFiniteTimeDoNothing() {
        var f = FreeFlight()
        f.advance(dt: 0.1, input: .init(forward: 1), yawDeg: 0, pitchDeg: 0)
        let before = f
        for dt in [0.0, -0.5, .nan, .infinity] {
            let d = f.advance(dt: dt, input: .init(forward: 1), yawDeg: 0, pitchDeg: 0)
            #expect(d == .zero && f == before, "dt \(dt)")
        }
    }

    @Test func stopDropsAllSpeed() {
        var f = FreeFlight()
        f.advance(dt: 0.2, input: .init(vertical: 1), yawDeg: 0, pitchDeg: 0)
        #expect(f.isMoving)
        f.stop()
        #expect(!f.isMoving && f.velocity == .zero)
    }

    @Test func freeModeIsAPlainCameraModeValue() throws {
        #expect(CameraMode(rawValue: "free") == .free)
        let data = try JSONEncoder().encode(CameraState(mode: .free, target: P3(1, 2, 3), distance: 3000, yawDeg: 1, pitchDeg: -2))
        #expect(try JSONDecoder().decode(CameraState.self, from: data).mode == .free)
    }
}
