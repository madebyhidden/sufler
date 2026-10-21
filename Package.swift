// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sufler",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.0")
    ],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .executableTarget(
            name: "Sufler",
            dependencies: ["whisper", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Sufler",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Путь к whisper.framework внутри .app
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
