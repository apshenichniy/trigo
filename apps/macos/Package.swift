// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "TrigoNative", platforms: [.macOS(.v15)],
  products: [.library(name: "TrigoNative", targets: ["TrigoNative"])],
  dependencies: [.package(path: "../../packages/contracts")],
  targets: [
    .target(
      name: "TrigoNative", dependencies: [.product(name: "TrigoContracts", package: "contracts")],
      path: "Native"),
    .testTarget(name: "TrigoNativeTests", dependencies: ["TrigoNative"], path: "Tests"),
  ])
