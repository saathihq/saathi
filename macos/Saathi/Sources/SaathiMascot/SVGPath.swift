//
//  SVGPath.swift
//  SaathiMascot
//
//  Just enough of the SVG path grammar for the mascot body: absolute M, L, C and Z. Anything else
//  is an error, because a silently wrong outline is worse than a loud one.
//

import CoreGraphics

enum SVGPath {

    enum ParseError: Error, Equatable {
        case unsupportedCommand(Character)
        case malformedNumber(String)
        case wrongArgumentCount(command: Character, found: Int)
    }

    static func cgPath(from d: String) throws -> CGPath {
        let path = CGMutablePath()
        var command: Character?
        var numbers: [CGFloat] = []
        var token = ""

        func flushToken() throws {
            guard !token.isEmpty else { return }
            guard let value = Double(token) else { throw ParseError.malformedNumber(token) }
            numbers.append(CGFloat(value))
            token = ""
        }

        func apply() throws {
            guard let c = command else { return }
            switch c {
            case "M":
                guard numbers.count == 2 else { throw ParseError.wrongArgumentCount(command: c, found: numbers.count) }
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L":
                guard numbers.count == 2 else { throw ParseError.wrongArgumentCount(command: c, found: numbers.count) }
                path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C":
                guard !numbers.isEmpty, numbers.count % 6 == 0 else {
                    throw ParseError.wrongArgumentCount(command: c, found: numbers.count)
                }
                for i in stride(from: 0, to: numbers.count, by: 6) {
                    path.addCurve(
                        to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                        control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                        control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3])
                    )
                }
            case "Z":
                guard numbers.isEmpty else { throw ParseError.wrongArgumentCount(command: c, found: numbers.count) }
                path.closeSubpath()
            default:
                throw ParseError.unsupportedCommand(c)
            }
            numbers.removeAll()
        }

        for character in d {
            if character.isLetter {
                try flushToken()
                try apply()
                command = character
            } else if character == " " || character == "," || character == "\n" || character == "\t" {
                try flushToken()
            } else if character == "-", !token.isEmpty, !token.hasSuffix("e"), !token.hasSuffix("E") {
                // "1-2" is two numbers; "1e-2" is one.
                try flushToken()
                token = "-"
            } else {
                token.append(character)
            }
        }
        try flushToken()
        try apply()
        return path
    }
}
