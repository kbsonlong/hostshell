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
    targets: [
        .executableTarget(
            name: "HostShell",
            path: "Sources/HostShell",
            linkerSettings: [
                .unsafeFlags([
                    "-L/Users/kbsonlong/code/hostshell/target/debug",
                    "-lhostshell_core",
                    "-Xlinker", "-rpath", "-Xlinker", "/Users/kbsonlong/code/hostshell/target/debug"
                ])
            ]
        )
    ]
)
