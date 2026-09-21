//
//  InputLevel.swift
//  SaathiKit
//
//  How loud the microphone is, as a number a row of bars can be drawn from.
//
//  Loudness is heard logarithmically, so the bars are driven by decibels, not by the raw RMS: on a
//  linear scale ordinary speech sits in the bottom tenth and the bars barely twitch, which reads
//  as "it cannot hear me" — the opposite of what they are there to say.
//

import AVFoundation

public enum InputLevel {

    /// Below this is room noise; at or above `ceiling` the bars are full.
    static let floor: Float = -50
    static let ceiling: Float = -12

    /// 0…1 from a root-mean-square amplitude in 0…1.
    public static func normalised(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// The level of one tap buffer's first channel. 0 for a buffer that is not float PCM.
    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        return normalised(rms: rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }
}
