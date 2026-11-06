// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InstagramPet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
        .executable(name: "PetNativeHost", targets: ["PetNativeHost"]),
        .executable(name: "InstagramPet", targets: ["InstagramPet"]),
        .executable(name: "PetCoreChecks", targets: ["PetCoreChecks"])
    ],
    targets: [
        .target(name: "PetCore"),
        .executableTarget(name: "PetNativeHost", dependencies: ["PetCore"]),
        .executableTarget(name: "InstagramPet", dependencies: ["PetCore"]),
        .executableTarget(name: "PetCoreChecks", dependencies: ["PetCore"], path: "Tests/PetCoreChecks")
    ],
    swiftLanguageVersions: [.v5]
)
