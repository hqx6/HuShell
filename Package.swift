// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HuShell",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HuShell", targets: ["HuShell"])],
    targets: [
        .executableTarget(name: "HuShell", path: "Sources/HuShell", resources: [.copy("Resources")]),
        .testTarget(name: "HuShellTests", dependencies: ["HuShell"])
    ]
)
