//
//  MenuBarIconTests.swift
//  SaathiShellTests
//

import AppKit
import XCTest
import SaathiMascot
@testable import SaathiShell

final class MenuBarIconTests: XCTestCase {

    func testTheIconIsATemplateOfTheRightSizeWithSomethingDrawnInIt() throws {
        let image = MenuBarIcon.image(data: try MascotData.load(), side: 18)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))

        // Draw it into a bitmap of known layout and count the opaque pixels.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var opaque = 0
        for y in 0..<18 {
            for x in 0..<18 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
        }
        XCTAssertGreaterThan(opaque, 40, "the pointer should cover a good part of 18×18")
        XCTAssertLessThan(opaque, 18 * 18 - 40, "and not all of it")
    }

    func testTheBodyOutlineIsInTheBodySquare() throws {
        let data = try MascotData.load()
        let box = try data.bodyOutline().boundingBoxOfPath
        XCTAssertGreaterThan(box.minX, 0)
        XCTAssertLessThan(box.maxX, CGFloat(data.eyeRefX) * 2)
        XCTAssertEqual(box.maxY, CGFloat(data.eyeRefX) * 2, accuracy: 0.5)
    }
}
