// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KoyoriKit",
    // macOS は `swift build` / `swift test` で検証するためだけに入れている
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "KoyoriKit", targets: ["KoyoriKit"])],
    dependencies: [
        // 説明・コメントの Markdown を Web と同じ GFM で表示する
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(name: "KoyoriKit", dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")]),
        .testTarget(name: "KoyoriKitTests", dependencies: ["KoyoriKit"]),
    ]
)
