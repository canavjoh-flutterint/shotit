// swift-tools-version: 6.0
import PackageDescription

// The tests are an executable, not a test target. With Command Line Tools only (no Xcode),
// `swift test` finds zero Swift Testing tests (CLT Testing build 1902 with the Swift 6.3 compiler).
// Linking Testing into an executable and calling its entry point works. Run: swift run shotit-tests
let cltDev = "/Library/Developer/CommandLineTools/Library/Developer"

let package = Package(
    name: "shotit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShotitCore"),
        .executableTarget(name: "shotit", dependencies: ["ShotitCore"]),
        // Draws the app icon at bundle time. See scripts/bundle.py.
        .executableTarget(name: "shotit-icon", dependencies: ["ShotitCore"]),
        .executableTarget(
            name: "shotit-tests", dependencies: ["ShotitCore"], path: "Tests/ShotitCoreTests",
            swiftSettings: [.unsafeFlags(["-F", "\(cltDev)/Frameworks"])],
            linkerSettings: [.unsafeFlags([
                "-F", "\(cltDev)/Frameworks", "-framework", "Testing",
                "-Xlinker", "-rpath", "-Xlinker", "\(cltDev)/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "\(cltDev)/usr/lib",
            ])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
