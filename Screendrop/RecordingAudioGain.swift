import AVFoundation
import AudioToolbox
import MediaToolbox

/// Shared by player items and both export paths. A processing tap supports
/// amplification above unity, unlike AVAudioMix's 0...1 volume parameter.
nonisolated enum RecordingAudioGain {
    static func normalized(_ volume: Double) -> Double {
        volume.isFinite ? min(2, max(0, volume)) : 1
    }

    static func makeMix(tracks: [AVAssetTrack], volume: Double) -> AVAudioMix? {
        let parameters = inputParameters(tracks: tracks, volume: volume)
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    /// The parameters that apply `volume` to each track; empty at unity,
    /// which needs none. Shared with mixes that carry other tracks too.
    static func inputParameters(tracks: [AVAssetTrack], volume: Double) -> [AVMutableAudioMixInputParameters] {
        let gain = Float(normalized(volume))
        guard gain != 1 else { return [] }
        return tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            if gain <= 1 {
                parameters.setVolume(gain, at: .zero)
            } else {
                parameters.audioTapProcessor = makeTap(gain: gain)
            }
            return parameters
        }
    }

    private final class State {
        let gain: Float
        var format = AudioStreamBasicDescription()
        init(gain: Float) { self.gain = gain }
    }

    static func makeTap(gain: Float) -> MTAudioProcessingTap? {
        let storage = Unmanaged.passRetained(State(gain: gain)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, tapStorage in tapStorage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = state.format
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let bytes = Int(buffer.mDataByteSize)
                    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                        if format.mBitsPerChannel == 32 {
                            let samples = data.assumingMemoryBound(to: Float.self)
                            for i in 0..<(bytes / 4) { samples[i] = min(1, max(-1, samples[i] * state.gain)) }
                        } else if format.mBitsPerChannel == 64 {
                            let samples = data.assumingMemoryBound(to: Double.self)
                            for i in 0..<(bytes / 8) { samples[i] = min(1, max(-1, samples[i] * Double(state.gain))) }
                        }
                    } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
                        if format.mBitsPerChannel == 16 {
                            let samples = data.assumingMemoryBound(to: Int16.self)
                            for i in 0..<(bytes / 2) {
                                samples[i] = Int16(min(Double(Int16.max), max(Double(Int16.min), Double(samples[i]) * Double(state.gain))))
                            }
                        } else if format.mBitsPerChannel == 32 {
                            let samples = data.assumingMemoryBound(to: Int32.self)
                            for i in 0..<(bytes / 4) {
                                samples[i] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(samples[i]) * Double(state.gain))))
                            }
                        }
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            Unmanaged<State>.fromOpaque(storage).release()
            return nil
        }
        return tap
    }

    // MARK: Envelope

    /// A stretch of a track and the gain it plays at, sliding evenly from
    /// `startGain` to `endGain`.
    struct EnvelopeSpan: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var startGain: Float
        var endGain: Float
    }

    private final class EnvelopeState {
        let spans: [EnvelopeSpan]
        var format = AudioStreamBasicDescription()
        /// Where the last lookup landed; audio arrives in order, so the
        /// next one is almost always the same span or the one after.
        var cursor = 0
        init(spans: [EnvelopeSpan]) { self.spans = spans }

        func gain(at time: Double) -> Float {
            guard !spans.isEmpty else { return 1 }
            if cursor >= spans.count || time < spans[cursor].start { cursor = 0 }
            while cursor < spans.count - 1, time >= spans[cursor].end { cursor += 1 }
            let span = spans[cursor]
            // Between two sounds there is nothing to play; before the
            // first and after the last, hold the nearest level.
            if time <= span.start { return span.startGain }
            if time >= span.end { return span.endGain }
            let progress = Float((time - span.start) / max(span.end - span.start, 0.000_001))
            return span.startGain + (span.endGain - span.startGain) * progress
        }
    }

    /// A tap that plays a track at a gain that changes over time, exact to
    /// the sample. The mix's own volume ramps can't do this: they smear a
    /// change over the audio around it, so a muted clip would fade into its
    /// neighbour instead of ending at the cut. Gains above 1 amplify.
    static func makeEnvelopeTap(spans: [EnvelopeSpan]) -> MTAudioProcessingTap? {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let storage = Unmanaged.passRetained(EnvelopeState(spans: sorted)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, tapStorage in tapStorage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<EnvelopeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<EnvelopeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                let count = Int(framesOut.pointee)
                guard count > 0, range.start.isNumeric else { return }
                let state = Unmanaged<EnvelopeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = state.format
                let start = range.start.seconds
                let duration = range.duration.isNumeric && range.duration.seconds > 0
                    ? range.duration.seconds
                    : Double(count) / max(format.mSampleRate, 1)
                let step = duration / Double(count)
                let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                let isSigned = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
                let bits = format.mBitsPerChannel

                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let bytesPerSample = Int(bits / 8)
                    guard bytesPerSample > 0 else { continue }
                    let available = Int(buffer.mDataByteSize) / (bytesPerSample * channels)
                    for frame in 0..<min(count, available) {
                        let gain = state.gain(at: start + Double(frame) * step)
                        if gain == 1 { continue }
                        for channel in 0..<channels {
                            let index = frame * channels + channel
                            if isFloat, bits == 32 {
                                let samples = data.assumingMemoryBound(to: Float.self)
                                samples[index] = min(1, max(-1, samples[index] * gain))
                            } else if isFloat, bits == 64 {
                                let samples = data.assumingMemoryBound(to: Double.self)
                                samples[index] = min(1, max(-1, samples[index] * Double(gain)))
                            } else if isSigned, bits == 16 {
                                let samples = data.assumingMemoryBound(to: Int16.self)
                                samples[index] = Int16(min(Double(Int16.max), max(Double(Int16.min), Double(samples[index]) * Double(gain))))
                            } else if isSigned, bits == 32 {
                                let samples = data.assumingMemoryBound(to: Int32.self)
                                samples[index] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(samples[index]) * Double(gain))))
                            }
                        }
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            Unmanaged<EnvelopeState>.fromOpaque(storage).release()
            return nil
        }
        return tap
    }
}
