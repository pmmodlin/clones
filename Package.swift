// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clones",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "clones", targets: ["clones"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.5.0")),
    ],
    targets: [
        .target(name: "ClonesCore"),
        .executableTarget(
            name: "clones",
            dependencies: [
                "ClonesCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ClonesCoreTests", dependencies: ["ClonesCore"]),
    ]
)
