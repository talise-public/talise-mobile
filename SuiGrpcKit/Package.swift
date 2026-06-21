// swift-tools-version: 6.0
//
// SuiGrpcKit — a Swift package wrapping Sui's gRPC API (sui.rpc.v2.*)
// with a multi-endpoint fallback chain. Built for the Talise app but
// generic enough to drop into any iOS 18+ Sui project.
//
// The library bundles:
//   - SuiGrpcClient: a long-lived gRPC client over HTTP/2 + TLS with
//     8s per-request deadlines, one-retry-on-transient-failure, and
//     NSLog-based telemetry.
//   - SuiEndpoints: an ordered registry of mainnet endpoints and a
//     `withFallback` helper that walks the list on UNAVAILABLE /
//     DEADLINE_EXCEEDED.
//   - Generated/: pre-generated Swift bindings for 39 vendored .proto
//     files, so consumers do NOT need protoc installed.
//
// Dependencies match the upstream grpc-swift v2 split package layout
// (https://github.com/grpc/grpc-swift-2#quick-start), pinned to the
// same major versions the Talise app ships with.

import PackageDescription

let package = Package(
    name: "SuiGrpcKit",
    platforms: [
        // grpc-swift v2 transports require iOS 18+ / macOS 15+.
        // macOS is declared so the package can be exercised with
        // `swift build` / `swift test` on a Mac host, even though
        // iOS is the only first-class target.
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "SuiGrpcKit",
            targets: ["SuiGrpcKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SuiGrpcKit",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                // Posix-only transport (not the umbrella HTTP2 product).
                // The umbrella also pulls in HTTP2TransportServices which
                // currently fails to build against iOS 18.2 because
                // SecCertificate is not Sendable. Posix is sufficient
                // for client-side HTTP/2 on iOS via NIOSSL.
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/SuiGrpcKit",
            swiftSettings: [
                // Match the host Talise app, which sets
                // SWIFT_STRICT_CONCURRENCY=minimal. The Swift 6 default
                // (`complete`) flags every generic crossing an actor
                // boundary as non-Sendable, including grpc-swift v2's
                // own response messages. Pinning to language mode 5
                // keeps the package buildable under the Swift 6
                // toolchain without re-auditing every dependency.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "SuiGrpcKitTests",
            dependencies: [
                "SuiGrpcKit",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
            ],
            path: "Tests/SuiGrpcKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
