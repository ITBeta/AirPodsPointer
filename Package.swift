// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirHeadMouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AirHeadMouse", targets: ["AirHeadMouse"]),
        .library(name: "HeadMouseCore", targets: ["HeadMouseCore"]),
    ],
    targets: [
        // 純邏輯（只依賴 Foundation），可單元測試，日後 Windows/iPhone 版也可複用。
        .target(name: "HeadMouseCore"),
        // macOS 菜單欄 App：CoreMotion + MediaPlayer + CGEvent。
        .executableTarget(
            name: "AirHeadMouse",
            dependencies: ["HeadMouseCore"]
        ),
        .testTarget(name: "HeadMouseCoreTests", dependencies: ["HeadMouseCore"]),
    ]
)
