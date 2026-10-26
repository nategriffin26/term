// swift-tools-version: 6.0
import PackageDescription

// Term Screen Host: the Mac side of Term's Screen. The ScreenProtocol module
// is also compiled into the iOS app (app/project.yml), so both ends share it.
let package = Package(
  name: "ScreenHost",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "ScreenProtocol"),
  ]
)
