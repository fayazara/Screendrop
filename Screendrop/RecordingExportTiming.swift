import CoreGraphics
import CoreMedia
import Foundation

/// One source of truth for output timestamps and the compositor's shutter.
/// Capture and interactive preview keep their independent 60 fps clocks.
nonisolated struct RecordingExportTiming: Sendable {
    let framesPerSecond: Double
    let motionBlurEnabled: Bool

    init(settings: VideoCompressionSettings) {
        framesPerSecond = settings.effectiveFrameRate.framesPerSecond
        motionBlurEnabled = settings.effectiveMotionBlurEnabled
    }

    var frameInterval: TimeInterval { 1 / framesPerSecond }

    func frameCount(for duration: TimeInterval) -> Int {
        max(1, Int((duration * framesPerSecond).rounded()))
    }

    func time(forFrame frame: Int) -> TimeInterval { Double(frame) / framesPerSecond }

    func presentationTime(forFrame frame: Int) -> CMTime {
        // Integer ticks avoid the one-tick rounding jitter introduced by
        // converting a floating-point second value back into CMTime.
        CMTime(value: Int64(frame), timescale: CMTimeScale(framesPerSecond))
    }

    func screenSampleRects(at time: TimeInterval, frameRect: (TimeInterval) -> CGRect) -> [CGRect] {
        guard motionBlurEnabled else { return [frameRect(time)] }

        // Preserve the one-frame shutter and adaptive 1–24-sample policy.
        // Sampling spans 1/30 s at 30 fps and 1/60 s at 60 fps.
        let shutter = frameInterval
        let a = frameRect(time - shutter / 2)
        let b = frameRect(time + shutter / 2)
        let displacement = max(
            max(abs(a.minX - b.minX), abs(a.minY - b.minY)),
            max(abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
        )
        let count = displacement > 1.5 ? min(24, max(2, Int((displacement / 2).rounded(.up)))) : 1
        return (0..<count).map { sample in
            let sampleTime = time - shutter / 2 + shutter * (Double(sample) + 0.5) / Double(count)
            return frameRect(sampleTime)
        }
    }
}
