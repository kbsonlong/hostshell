// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HostShellIOS",
    platforms: [.iOS(.v16)],
    products: [.executable(name: "HostShellIOS", targets: ["HostShellIOS"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.2.0"))
    ],
    targets: [
        .executableTarget(
            name: "HostShellIOS",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/HostShellIOS",
            linkerSettings: [
                .unsafeFlags([
                    "-L../../target/ios/HostShellCore.xcframework/ios-arm64",
                    "-lhostshell_core",
                    "-framework", "Security",
                    "-framework", "SystemConfiguration"
                ])
            ]
        )
    ]
)
