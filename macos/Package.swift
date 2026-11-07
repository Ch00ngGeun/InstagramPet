// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InstagramPet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
        .executable(name: "PetNativeHost", targets: ["PetNativeHost"]),
        .executable(name: "InstagramPet", targets: ["InstagramPet"]),
        .executable(name: "PetCoreChecks", targets: ["PetCoreChecks"]),
        .executable(name: "PetSourcesChecks", targets: ["PetSourcesChecks"])
    ],
    targets: [
        .target(name: "PetCore"),
        .target(name: "PetSources", dependencies: ["PetCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PetNativeHost", dependencies: ["PetCore"]),
        .executableTarget(name: "InstagramPet", dependencies: ["PetCore", "PetSources"]),
        .executableTarget(name: "PetCoreChecks", dependencies: ["PetCore"], path: "Tests/PetCoreChecks"),
        .executableTarget(name: "PetSourcesChecks", dependencies: ["PetCore", "PetSources"], path: "Tests/PetSourcesChecks")
    ],
    swiftLanguageVersions: [.v5]
)
