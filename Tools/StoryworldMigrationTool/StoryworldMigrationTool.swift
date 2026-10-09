import Darwin
import Foundation
import NovelDocumentCore
import StoryworldCore

@main
struct StoryworldMigrationTool {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3 else {
      FileHandle.standardError.write(
        Data(
          "用法：StoryworldMigrationTool <旧版世界书目录> <原小说文件> <输出目录>\n".utf8
        )
      )
      exit(2)
    }

    let legacyURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let novelURL = URL(fileURLWithPath: arguments[1])
    let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("StoryworldMigration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let novel = try NovelDocumentParser().parse(at: novelURL)
    let sourceReference = StoryworldSourceReference(
      contentHash: novel.contentHash,
      sourceFormat: novel.sourceFormat.rawValue,
      sourceFileName: novel.sourceFileName,
      title: novel.title
    )
    let library = StoryworldLibrary(rootURL: temporaryRoot)
    let receipt = try await library.importLegacyWorldbook(
      from: legacyURL,
      sourceReference: sourceReference,
      associateWith: StoryworldAssociationTarget(
        documentID: novel.id,
        contentHash: novel.contentHash
      )
    )
    let exported = try await library.exportPackage(
      storyworldID: receipt.record.id,
      to: outputURL
    )
    _ = try StoryworldPackageValidator().validate(at: exported)
    let migratedSnapshot = try await StoryworldRuntimeStore(packageURL: exported).load(
      address: receipt.playthrough.address
    )

    let result: [String: Any] = [
      "storyworld_id": receipt.record.id.uuidString.lowercased(),
      "title": receipt.record.manifest.title,
      "lore_entries": receipt.record.lorebookEntryCount,
      "preserved_legacy_files": receipt.preservedFileCount,
      "initial_state_fields": migratedSnapshot.state.values.count,
      "source_content_hash": novel.contentHash,
      "output": exported.path,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: result,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    print(String(decoding: data, as: UTF8.self))
  }
}
