// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "voicer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6")
    ],
    targets: [
        .executableTarget(
            name: "voicer",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift")
            ],
            path: "Sources/voicer",
            resources: [.copy("ASRResources")]
        ),
        .testTarget(
            name: "voicerTests",
            dependencies: ["voicer"],
            resources: [.copy("Fixtures")]
        )
    ]
)
