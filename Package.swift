// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YapYap",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios.git", exact: "1.0.11"),
        // Pinned to what kokoro-ios 1.0.11 pins, for MLXArray and the voices.npz reader.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
        // What MLXUtilsLibrary resolves to; used directly to read one voice out of voices.npz.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // Anonymous usage stats, only when the user opts in. See Telemetry.swift.
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK.git", exact: "2.14.2"),
    ],
    targets: [
        .target(name: "YapYapCore"),
        .executableTarget(name: "YapYap", dependencies: [
            "YapYapCore",
            .product(name: "KokoroSwift", package: "kokoro-ios"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "TelemetryDeck", package: "SwiftSDK"),
        ]),
        .testTarget(name: "YapYapCoreTests", dependencies: ["YapYapCore"]),
        .testTarget(name: "YapYapTests", dependencies: ["YapYap", "YapYapCore"]),
    ],
    swiftLanguageModes: [.v5]
)
