// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HostShell",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HostShell", targets: ["HostShell"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.19.0"))
    ],
    targets: [
        .executableTarget(
            name: "HostShell",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/HostShell"
        )
    ]
)
