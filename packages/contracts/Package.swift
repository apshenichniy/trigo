// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "TrigoContracts", platforms: [.macOS(.v15)],
  products: [.library(name: "TrigoContracts", targets: ["TrigoContracts"])],
  dependencies: [.package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.13.1")],
  targets: [
    .target(
      name: "TrigoContracts",
      dependencies: [.product(name: "JSONSchema", package: "swift-json-schema")],
      resources: [
        .copy("Resources/v1.schema.json"),
        .copy("Resources/media-profile.v1.json"),
      ]),
    .testTarget(name: "TrigoContractsTests", dependencies: ["TrigoContracts"], path: "Tests"),
  ]
)
