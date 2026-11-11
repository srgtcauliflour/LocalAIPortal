// swift-tools-version: 5.8
// Vendored copy of Apple's ml-stable-diffusion Swift library (see LICENSE.md),
// with the Stable Diffusion 3 files removed so it has no external dependencies.

import PackageDescription

let package = Package(
    name: "StableDiffusion",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "StableDiffusion", targets: ["StableDiffusion"])
    ],
    targets: [
        .target(name: "StableDiffusion", path: "Sources/StableDiffusion")
    ]
)
