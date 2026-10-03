// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Gonzo",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "Gonzo", targets: ["Gonzo"])],
    targets: [
        .target(name: "GonzoCore"),
        .executableTarget(name: "Gonzo", dependencies: ["GonzoCore"]),
        .testTarget(name: "GonzoCoreTests", dependencies: ["GonzoCore"]),
        .testTarget(name: "GonzoTests", dependencies: ["Gonzo", "GonzoCore"])
    ]
)
