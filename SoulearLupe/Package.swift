// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoulearLupe",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SoulearLupe", targets: ["SoulearLupe"])],
    targets: [.executableTarget(name: "SoulearLupe", path: "Sources/SoulearLupe")]
)
