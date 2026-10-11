// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyMounterPrototype",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "transfer-bench", targets: ["TransferBench"])],
    targets: [
        .target(name: "TransferCore"),
        .executableTarget(name: "TransferBench", dependencies: ["TransferCore"]),
        .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"])
    ],
    swiftLanguageModes: [.v5]
)
