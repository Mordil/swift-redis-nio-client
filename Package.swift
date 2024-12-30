// swift-tools-version:5.6
//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2019-2023 Apple Inc. and the RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "RediStack",
    products: [
        .library(name: "RediStack", targets: ["RediStack"]),
        .library(name: "RediStackTestUtils", targets: ["RediStackTestUtils"]),
        .library(name: "RedisTypes", targets: ["RedisTypes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0"..<"3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.43.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.23.1"),
    ],
    targets: [
        .target(
            name: "RediStack",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .target(name: "RedisTypes", dependencies: ["RediStack"]),
        .target(
            name: "RediStackTestUtils",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                "RediStack",
            ]
        ),
        .target(
            name: "RESP3",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "RediStackTests",
            dependencies: [
                "RediStack",
                "RediStackTestUtils",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RedisTypesTests",
            dependencies: [
                "RediStack", "RedisTypes", "RediStackTestUtils",
                .product(name: "NIO", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RESP3Tests",
            dependencies: [
                "RESP3",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RediStackIntegrationTests",
            dependencies: [
                "RediStack", "RediStackTestUtils",
                .product(name: "NIO", package: "swift-nio"),
            ]
        ),
    ]
)
