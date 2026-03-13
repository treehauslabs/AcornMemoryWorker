// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcornMemoryWorker",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AcornMemoryWorker", targets: ["AcornMemoryWorker"]),
    ],
    dependencies: [
        .package(path: "../Acorn"),
    ],
    targets: [
        .target(
            name: "AcornMemoryWorker",
            dependencies: ["Acorn"]
        ),
        .testTarget(
            name: "AcornMemoryWorkerTests",
            dependencies: ["AcornMemoryWorker"]
        ),
        .executableTarget(
            name: "MemoryCASBenchmarks",
            dependencies: ["AcornMemoryWorker", "Acorn"],
            path: "Benchmarks/MemoryCASBenchmarks"
        ),
    ]
)
