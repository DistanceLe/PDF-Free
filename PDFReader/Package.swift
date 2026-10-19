// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PDFReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PDFReader", targets: ["PDFReaderApp"])
    ],
    targets: [
        .executableTarget(name: "PDFReaderApp")
    ]
)
