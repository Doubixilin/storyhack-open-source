// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "WorldbookApp",
  defaultLocalization: "zh-Hans",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "NovelDocumentCore", targets: ["NovelDocumentCore"]),
    .library(name: "DirectoryJournalCore", targets: ["DirectoryJournalCore"]),
    .library(name: "LibraryCore", targets: ["LibraryCore"]),
    .library(name: "StoryworldCore", targets: ["StoryworldCore"]),
    .library(name: "StorySessionCore", targets: ["StorySessionCore"]),
    .library(name: "StoryMaterialKit", targets: ["StoryMaterialKit"]),
    .library(name: "LLMProviderKit", targets: ["LLMProviderKit"]),
    .library(name: "StoryworldFactory", targets: ["StoryworldFactory"]),
    .library(name: "MediaCore", targets: ["MediaCore"]),
    .library(name: "SpeechProviderKit", targets: ["SpeechProviderKit"]),
    .library(name: "WritingCore", targets: ["WritingCore"]),
    .library(name: "VisualMediaCore", targets: ["VisualMediaCore"]),
    .library(name: "CharacterLibraryCore", targets: ["CharacterLibraryCore"]),
    .library(name: "WorldbookUI", targets: ["WorldbookUI"]),
    .executable(name: "WorldbookMac", targets: ["WorldbookMac"]),
    .executable(name: "WorldbookLibraryTool", targets: ["WorldbookLibraryTool"]),
    .executable(name: "StoryworldMigrationTool", targets: ["StoryworldMigrationTool"]),
    .executable(name: "WorldbookTaskTool", targets: ["WorldbookTaskTool"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/weichsel/ZIPFoundation.git",
      from: "0.9.18"
    ),
  ],
  targets: [
    .target(
      name: "NovelDocumentCore",
      dependencies: ["ZIPFoundation"]
    ),
    .target(name: "DirectoryJournalCore"),
    .target(
      name: "LibraryCore",
      dependencies: ["NovelDocumentCore", "WritingCore", "DirectoryJournalCore"]
    ),
    .target(
      name: "StoryworldCore",
      dependencies: ["DirectoryJournalCore"]
    ),
    .target(
      name: "StorySessionCore",
      dependencies: ["StoryworldCore", "StoryMaterialKit", "LLMProviderKit"]
    ),
    .target(
      name: "StoryMaterialKit",
      resources: [.copy("Resources/materials-v1")]
    ),
    .target(name: "LLMProviderKit"),
    .target(name: "MediaCore"),
    .target(
      name: "WritingCore",
      dependencies: ["DirectoryJournalCore", "NovelDocumentCore", "StoryworldCore", "ZIPFoundation"]
    ),
    .target(
      name: "WritingAssistantCore",
      dependencies: ["WritingCore", "LLMProviderKit", "StoryworldCore"]
    ),
    .target(name: "VisualMediaCore"),
    .target(name: "CharacterLibraryCore"),
    .target(
      name: "SpeechProviderKit",
      dependencies: ["MediaCore"]
    ),
    .target(
      name: "StoryworldFactory",
      dependencies: ["LibraryCore", "NovelDocumentCore", "StoryworldCore", "LLMProviderKit", "DirectoryJournalCore"]
    ),
    .target(
      name: "WorldbookUI",
      dependencies: [
        "LibraryCore",
        "NovelDocumentCore",
        "StoryworldCore",
        "StorySessionCore",
        "StoryworldFactory",
        "LLMProviderKit",
        "MediaCore",
        "SpeechProviderKit",
        "WritingCore",
        "WritingAssistantCore",
        "VisualMediaCore",
        "CharacterLibraryCore",
      ]
    ),
    .executableTarget(
      name: "WorldbookMac",
      dependencies: ["WorldbookUI", "StoryworldFactory", "StoryMaterialKit"],
      path: "Apps/macOS/Sources"
    ),
    .executableTarget(
      name: "WorldbookLibraryTool",
      dependencies: ["LibraryCore"],
      path: "Tools/WorldbookLibraryTool"
    ),
    // CLI-only credentials and command handling are never dependencies of App targets.
    .target(name: "WorldbookTaskCLI", dependencies: ["WritingAssistantCore", "WritingCore", "StoryworldFactory",
      "LibraryCore", "NovelDocumentCore", "StoryworldCore", "LLMProviderKit", "DirectoryJournalCore"]),
    .executableTarget(name: "WorldbookTaskTool", dependencies: ["WorldbookTaskCLI"], path: "Tools/WorldbookTaskTool"),
    .testTarget(name: "WorldbookTaskCLITests", dependencies: ["WorldbookTaskCLI"]),
    .executableTarget(
      name: "StoryworldMigrationTool",
      dependencies: ["NovelDocumentCore", "StoryworldCore"],
      path: "Tools/StoryworldMigrationTool"
    ),
    .testTarget(
      name: "StoryworldCoreTests",
      dependencies: ["StoryworldCore"]
    ),
    .testTarget(
      name: "StorySessionCoreTests",
      dependencies: ["StorySessionCore", "StoryworldCore", "StoryMaterialKit", "LLMProviderKit"]
    ),
    .testTarget(
      name: "StoryMaterialKitTests",
      dependencies: ["StoryMaterialKit"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "LLMProviderKitTests",
      dependencies: ["LLMProviderKit"]
    ),
    .testTarget(
      name: "NovelDocumentCoreTests",
      dependencies: ["NovelDocumentCore", "ZIPFoundation"]
    ),
    .testTarget(
      name: "LibraryCoreTests",
      dependencies: ["LibraryCore", "NovelDocumentCore"]
    ),
    .testTarget(
      name: "StoryworldFactoryTests",
      dependencies: ["StoryworldFactory", "LibraryCore", "NovelDocumentCore", "StoryworldCore"]
    ),
    .testTarget(
      name: "MediaCoreTests",
      dependencies: ["MediaCore"]
    ),
    .testTarget(
      name: "SpeechProviderKitTests",
      dependencies: ["SpeechProviderKit", "MediaCore"]
    ),
    .testTarget(
      name: "WorldbookUITests",
      dependencies: [
        "WorldbookUI", "LibraryCore", "StoryworldCore", "LLMProviderKit",
        "WritingCore", "StoryworldFactory", "CharacterLibraryCore", "VisualMediaCore", "MediaCore",
      ]
    ),
    .testTarget(
      name: "WritingCoreTests",
      dependencies: ["WritingCore", "LibraryCore", "StoryworldCore", "ZIPFoundation"]
    ),
    .testTarget(
      name: "WritingAssistantCoreTests",
      dependencies: ["WritingAssistantCore", "WritingCore", "LLMProviderKit"]
    ),
    .testTarget(
      name: "VisualMediaCoreTests",
      dependencies: ["VisualMediaCore"]
    ),
    .testTarget(
      name: "CharacterLibraryCoreTests",
      dependencies: ["CharacterLibraryCore"]
    ),
    .testTarget(
      name: "DirectoryJournalCoreTests",
      dependencies: ["DirectoryJournalCore"]
    ),
    .testTarget(
      name: "EndToEndTests",
      dependencies: [
        "WorldbookUI",
        "LibraryCore",
        "NovelDocumentCore",
        "StorySessionCore",
        "StoryMaterialKit",
        "StoryworldCore",
        "StoryworldFactory",
        "LLMProviderKit",
        "WritingCore",
      ],
      resources: [.copy("Fixtures")]
    ),
  ]
)
