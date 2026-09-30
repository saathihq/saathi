//
//  WaveFile.swift
//  SaathiKit
//
//  PCM16 into a WAV file, and how long a WAV is.
//
//  A WAV is the one audio container every speech service takes without being told what is in it:
//  forty-four bytes that say the rate, the width and the length, and then the samples. Saaras is
//  sent a turn in one; Bulbul answers in one.
//

import Foundation

public enum WaveFile {

    /// `pcm16` — mono, 16-bit, little-endian — as a WAV file at `sampleRate`.
    public static func wrap(pcm16: Data, sampleRate: Int) -> Data {
        var header = Data(capacity: 44)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm16.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); put(UInt32(pcm16.count))
        return header + pcm16
    }

    /// How long a WAV plays for, from its own header: the bytes of sound over the bytes a second.
    /// Nil for anything that is not a WAV with both of those in it.
    public static func seconds(of wav: Data) -> Double? {
        // A slice keeps its parent's indices; a copy starts at zero, which is what the offsets
        // below assume.
        let wav = Data(wav)
        guard wav.count >= 12,
              wav.subdata(in: 0..<4) == Data("RIFF".utf8),
              wav.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }

        func u32(_ offset: Int) -> UInt32 {
            wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        var bytesPerSecond: UInt32?
        var soundBytes: Int?
        var offset = 12
        while offset + 8 <= wav.count {
            let id = wav.subdata(in: offset..<offset + 4)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == Data("fmt ".utf8), body + 12 <= wav.count {
                bytesPerSecond = u32(body + 8)
            } else if id == Data("data".utf8) {
                // A streamed WAV may claim more than it holds; what is there is what plays.
                soundBytes = min(size, wav.count - body)
            }
            offset = body + size + size % 2
        }
        guard let bytesPerSecond, bytesPerSecond > 0, let soundBytes else { return nil }
        return Double(soundBytes) / Double(bytesPerSecond)
    }
}
