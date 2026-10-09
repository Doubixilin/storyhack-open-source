import Foundation

public struct AdaptationExport: Sendable {
  public let assembly: AdaptationAssembly
  public let textURL: URL
  public let epubURL: URL
  public let comparisonURL: URL
  public let epubHash: String
}

private struct AdaptationExportReceipt: Codable {
  let assemblyHash: String
  let fileHashes: [String: String]
  let acknowledgedUnchangedChapterIDs: [String]
}

extension AdaptationJobStore {
  /// Keep the reviewed source/draft state locked until a synchronous consumer
  /// finishes installing this export. The consumer may acquire its destination
  /// journal lock, but must not await actors or network work under these locks.
  /// A plain export URL does not carry continuing publication authorization.
  public func withValidatedExport<Result: Sendable>(_ assembly: AdaptationAssembly,
    acknowledgeUnchangedChapters: Bool = false,
    consume: @Sendable (AdaptationExport) throws -> Result) throws -> Result {
    try locked {
      let export = try exportAssembly(assembly, acknowledgeUnchangedChapters: acknowledgeUnchangedChapters)
      return try consume(export)
    }
  }

  public func exportAssembly(_ assembly: AdaptationAssembly,
    acknowledgeUnchangedChapters: Bool = false) throws -> AdaptationExport {
    try locked {
      try validateAssembly(assembly, acknowledgeUnchangedChapters: acknowledgeUnchangedChapters)
      let source = try document(for: job(assembly.jobID)), hash = try assembly.fingerprint()
      let baseName = (source.sourceFileName as NSString).deletingPathExtension
      let names = [baseName + ".txt", baseName + ".epub", "comparison.md"]
      // Source names such as comparison.md must not collide with the report.
      guard Set(names).count == names.count else { throw AdaptationError.invalidSource }
      let folder = try path(assembly.jobID, "exports/" + hash)
      func result(_ epubHash: String) -> AdaptationExport {
        .init(assembly: assembly, textURL: folder.appendingPathComponent(names[0]),
          epubURL: folder.appendingPathComponent(names[1]), comparisonURL: folder.appendingPathComponent(names[2]), epubHash: epubHash)
      }
      if files.fileExists(atPath: folder.path) {
        let receipt = try AdaptationCoding.decoder().decode(AdaptationExportReceipt.self,
          from: readData(try path(assembly.jobID, "exports/" + hash + "/receipt.json"), maximum: 16_384))
        guard receipt.assemblyHash == hash, Set(receipt.fileHashes.keys) == Set(names),
          receipt.acknowledgedUnchangedChapterIDs == assembly.unchangedChapterIDs else { throw AdaptationError.corruptPackage }
        for name in names {
          let bytes = try readData(try path(assembly.jobID, "exports/" + hash + "/" + name), maximum: 100 * 1_048_576)
          guard AdaptationCoding.hash(bytes) == receipt.fileHashes[name] else { throw AdaptationError.corruptPackage }
        }
        guard let epubHash = receipt.fileHashes[names[1]] else { throw AdaptationError.corruptPackage }
        return result(epubHash)
      }
      let staging = try path(assembly.jobID, ".exporting-" + UUID().uuidString.lowercased())
      try files.createDirectory(at: staging, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: staging) }
      let original = source.sourceFormat == .epub ? try originalFileURL(assembly.jobID) : nil
      if source.sourceFormat == .epub && original == nil { throw AdaptationAssemblyError.unsupportedSource }
      try Data(assembly.plainText.utf8).write(to: staging.appendingPathComponent(names[0]))
      try Data(assembly.comparisonMarkdown.utf8).write(to: staging.appendingPathComponent(names[2]))
      try AdaptationEPUBAssembler().write(assembly, originalURL: original, to: staging.appendingPathComponent(names[1]))
      var hashes: [String: String] = [:]
      for name in names { hashes[name] = AdaptationCoding.hash(try readData(staging.appendingPathComponent(name), maximum: 100 * 1_048_576)) }
      let receipt = AdaptationExportReceipt(assemblyHash: hash, fileHashes: hashes, acknowledgedUnchangedChapterIDs: assembly.unchangedChapterIDs)
      try AdaptationCoding.encoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"))
      try AdaptationCoding.encoder().encode(assembly).write(to: staging.appendingPathComponent("assembly.json"))
      try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
      try files.moveItem(at: staging, to: folder)
      guard let epubHash = hashes[names[1]] else { throw AdaptationError.corruptPackage }
      return result(epubHash)
    }
  }
}
