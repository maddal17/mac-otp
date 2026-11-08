// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacOTP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacOTPCore", targets: ["MacOTPCore"]),
        .executable(name: "MacOTPApp", targets: ["MacOTPApp"]),
        .executable(name: "mac-otp-mcp", targets: ["MacOTPMCP"])
    ],
    targets: [
        .target(
            name: "MacOTPCore",
            path: "Sources/MacOTPCore"
        ),
        .executableTarget(
            name: "MacOTPApp",
            dependencies: ["MacOTPCore"],
            path: "Sources/MacOTPApp"
        ),
        .executableTarget(
            name: "MacOTPMCP",
            dependencies: ["MacOTPCore"],
            path: "Sources/MacOTPMCP"
        ),
        .testTarget(
            name: "MacOTPCoreTests",
            dependencies: ["MacOTPCore"],
            path: "Tests/MacOTPCoreTests"
        )
    ]
)
