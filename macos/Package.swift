// swift-tools-version: 5.9
import PackageDescription

// 패키지 구성: 공통 코어, 로컬 메시지 리더, Chrome 네이티브 메시징 호스트, 펫 앱,
// 그리고 검사 실행 파일 두 개(직접 실행하며 XCTest 타깃은 없음).

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
