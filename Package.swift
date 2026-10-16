// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhaleFloat",
    // 部署目标必须够新，否则系统会按「兼容模式」渲染 —— 拿不到 Liquid Glass。
    // 实测：原来写 .v13，编译出的二进制 LC_BUILD_VERSION 里 sdk=13.0，
    // 系统据此认为这是老 app，NSPopover 给的是纯白背景而不是系统材质。
    // macOS 26 是引入 Liquid Glass 的版本，以它为基准即可。
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "WhaleFloat",
            path: "Sources/WhaleFloat"
        )
    ]
)
