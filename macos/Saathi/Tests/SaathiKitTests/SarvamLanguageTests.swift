//
//  SarvamLanguageTests.swift
//  SaathiKitTests
//
//  The two small things under Sarvam's speech: a language tag in Sarvam's spelling, and sound in
//  the container it is sent and returned in.
//

import Foundation
import XCTest
@testable import SaathiKit

final class SarvamLanguageTests: XCTestCase {

    func testALanguageBecomesSarvamsCodeForIt() {
        XCTAssertEqual(SarvamLanguage.code(for: "ml"), "ml-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "ml-IN"), "ml-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "hi_IN"), "hi-IN")
        XCTAssertEqual(SarvamLanguage.code(for: " TA "), "ta-IN")
    }

    /// Bulbul has one English, and it is India's. Whichever English was asked for, that is the one.
    func testEveryEnglishIsIndianEnglish() {
        XCTAssertEqual(SarvamLanguage.code(for: "en"), "en-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "en-US"), "en-IN")
    }

    /// "or" to everything else on this Mac, "od-IN" to Sarvam.
    func testOdiaIsSpelledSarvamsWay() {
        XCTAssertEqual(SarvamLanguage.code(for: "or"), "od-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "or-IN"), "od-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "od-IN"), "od-IN")
        XCTAssertEqual(SarvamLanguage.name(of: "od-IN"), "Odia")
    }

    /// Saaras hears Urdu and Bulbul does not speak it. A companion has to do both.
    func testALanguageSarvamCannotBothHearAndSpeakIsNotGuessedAt() {
        for tag in ["fr", "ja", "ko-KR", "zh", "ur", "es-ES", "", "   "] {
            XCTAssertNil(SarvamLanguage.code(for: tag), "\"\(tag)\"")
        }
    }

    func testALanguageIsNamedInWordsForTheSentenceThatRefusesIt() {
        XCTAssertEqual(SarvamLanguage.name(of: "fr"), "French")
        XCTAssertEqual(SarvamLanguage.name(of: "ml-IN"), "Malayalam")
        XCTAssertEqual(SarvamLanguage.name(of: "zz"), "zz", "a tag nobody has a name for is shown as it is")
    }
}

final class WaveFileTests: XCTestCase {

    func testPCMIsWrappedAsAMonoSixteenBitWav() {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let wav = WaveFile.wrap(pcm16: pcm, sampleRate: 16_000)

        func u32(_ offset: Int) -> UInt32 {
            wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ offset: Int) -> UInt16 {
            wav.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        func text(_ range: Range<Int>) -> String { String(decoding: wav.subdata(in: range), as: UTF8.self) }

        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(text(0..<4), "RIFF")
        XCTAssertEqual(u32(4), 40, "the file's size, less the eight bytes that say so")
        XCTAssertEqual(text(8..<16), "WAVEfmt ")
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(28), 32_000, "bytes a second")
        XCTAssertEqual(u16(32), 2, "bytes a sample")
        XCTAssertEqual(u16(34), 16, "bits a sample")
        XCTAssertEqual(text(36..<40), "data")
        XCTAssertEqual(u32(40), 4)
        XCTAssertEqual(wav.subdata(in: 44..<48), pcm)
    }

    func testAWavSaysHowLongItIs() {
        let second = WaveFile.wrap(pcm16: Data(count: 48_000), sampleRate: 24_000)
        XCTAssertEqual(WaveFile.seconds(of: second) ?? -1, 1, accuracy: 0.001)
        let half = WaveFile.wrap(pcm16: Data(count: 16_000), sampleRate: 16_000)
        XCTAssertEqual(WaveFile.seconds(of: half) ?? -1, 0.5, accuracy: 0.001)
    }

    func testSomethingThatIsNotAWavHasNoLength() {
        XCTAssertNil(WaveFile.seconds(of: Data()))
        XCTAssertNil(WaveFile.seconds(of: Data("not a wav at all, just some text".utf8)))
        XCTAssertNil(WaveFile.seconds(of: Data("RIFF\0\0\0\0WAVE".utf8)), "a header with no sound in it")
    }

    /// A slice of a larger buffer keeps its parent's indices; reading it from zero would trap.
    func testASliceIsReadFromItsOwnStart() {
        let padded = Data([9, 9, 9]) + WaveFile.wrap(pcm16: Data(count: 32_000), sampleRate: 16_000)
        XCTAssertEqual(WaveFile.seconds(of: padded.dropFirst(3)) ?? -1, 1, accuracy: 0.001)
    }

    /// A streamed WAV can claim more sound than it holds. What is there is what plays.
    func testAWavThatClaimsMoreThanItHoldsIsMeasuredByWhatItHolds() {
        var wav = WaveFile.wrap(pcm16: Data(count: 32_000), sampleRate: 16_000)
        wav.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(WaveFile.seconds(of: wav) ?? -1, 1, accuracy: 0.001)
    }
}
