#!/usr/bin/env bash
#
# Renders Resources/Saathi.svg into a .icns at the path given as the first argument.
#
#   scripts/make-icon.sh dist/Saathi.icns
#
# The SVG is drawn at each size the iconset needs rather than drawn once and scaled down, so the
# 16 px menu-bar version is a real render and not a blurred thumbnail of the 1024 one. AppKit has
# loaded SVG since macOS 11, which is what lets this run with nothing installed beyond Xcode's
# command-line tools — no librsvg, no ImageMagick — and `iconutil` ships with macOS.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$PACKAGE_DIR/Resources/Saathi.svg"
OUT="${1:?usage: make-icon.sh <output.icns>}"

[[ -f "$SVG" ]] || { echo "no icon source at $SVG" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Saathi.iconset"
mkdir -p "$ICONSET"

cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
let svgPath = args[1], outDir = args[2]
guard let full = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write("could not load \(svgPath)\n".data(using: .utf8)!); exit(1)
}

// The 16 px image is drawn without the eyes: at under a pixel each they only muddy the triangle.
// The SVG keeps them in a group with id="eyes" so they can be cut here with a text edit rather
// than a second source file that would drift from the first.
let source = try! String(contentsOfFile: svgPath, encoding: .utf8)
let stripped = source.replacingOccurrences(of: #"<g id="eyes">[\s\S]*?</g>"#, with: "",
                                           options: .regularExpression)
guard stripped != source, let plain = NSImage(data: stripped.data(using: .utf8)!) else {
    FileHandle.standardError.write("no <g id=\"eyes\"> group in \(svgPath)\n".data(using: .utf8)!)
    exit(1)
}

// (file name, pixel width) — the ten entries iconutil expects in an iconset.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let svg = px <= 16 ? plain : full
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero,
             operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
SWIFT

# `swiftc` rather than `swift script.swift`: the interpreter path is noticeably slower to start and
# has been flaky under sandboxes, while compiling a 30-line file is a couple of seconds.
swiftc -O -o "$WORK/render" "$WORK/render.swift" 2>&1 | grep -v "^$" >&2 || true
[[ -x "$WORK/render" ]] || { echo "failed to compile the icon renderer" >&2; exit 1; }
"$WORK/render" "$SVG" "$ICONSET"

iconutil --convert icns --output "$OUT" "$ICONSET"
echo "  icon: $OUT"
