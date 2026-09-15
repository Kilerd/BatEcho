// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "voicer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "voicer",
            path: "Sources/voicer"
        )
    ]
)
