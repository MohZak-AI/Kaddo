// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kaddo",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KaddoCanvas", targets: ["KaddoCanvas"]),
        .executable(name: "Kaddo", targets: ["KaddoApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "KaddoCanvas", dependencies: ["CZlib", "CSQLite", .product(name: "PostgresNIO", package: "postgres-nio")], resources: [.process("Resources")]),
        .executableTarget(name: "KaddoApp", dependencies: ["KaddoCanvas"]),
        .testTarget(name: "KaddoCanvasTests", dependencies: ["KaddoCanvas"]),
        .testTarget(
            name: "KaddoAcceptanceTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
