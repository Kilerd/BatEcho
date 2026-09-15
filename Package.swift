// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatEcho",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6")
    ],
    targets: [
        .executableTarget(
            name: "BatEcho",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift")
            ],
            path: "Sources/BatEcho",
            resources: [.copy("ASRResources")]
        ),
        .testTarget(
            name: "BatEchoTests",
            dependencies: ["BatEcho"],
            resources: [.copy("Fixtures")]
        )
    ]
)
