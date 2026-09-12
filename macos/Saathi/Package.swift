// swift-tools-version: 5.9
//
// The macOS Saathi client.
//
// Deliberately a SwiftPM package rather than an Xcode project for now: it builds and tests from the
// command line on any Mac and in CI with no signing, no scheme, and no .pbxproj to merge. The
// menu-bar / overlay shell will need an app target eventually; `SaathiKit` is written so that shell
// links against it rather than reimplementing anything.

import PackageDescription

let package = Package(
    name: "Saathi",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SaathiKit", targets: ["SaathiKit"]),
        .executable(name: "saathi", targets: ["saathi"]),
    ],
    targets: [
        // Generated from contract/schema/saathi.json. Never edited by hand; `npm run generate -w
        // contract` rewrites it and CI fails if what is checked in here is stale.
        .target(name: "SaathiContract"),

        // Everything that is not the user interface: config, the backend client, and performing an
        // action. A CLI today, a menu-bar app later, the same code underneath both.
        .target(name: "SaathiKit", dependencies: ["SaathiContract"]),

        .executableTarget(name: "saathi", dependencies: ["SaathiKit"]),

        .testTarget(name: "SaathiKitTests", dependencies: ["SaathiKit"]),
    ]
)
