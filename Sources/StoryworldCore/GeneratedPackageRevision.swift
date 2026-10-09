import CryptoKit
import DirectoryJournalCore
import Foundation

/// Ownership is explicit: only files listed here may be replaced by the
/// factory. Runtime, media, and other manually added files are never candidates.
public struct GeneratedPackageRevision: Codable, Equatable, Sendable {
  public static let relativePath = "factory/generation.json"
  public static let allowedPaths: Set<String> = [
    "lorebook/lorebook.json", "timeline.json", "plotline.json",
    "factory/provenance.json", "material_profile.json", "character_contracts.json",
  ]
  public let inputFingerprint: String
  public let candidateManifestFingerprint: String
  public let assets: [String: String]

  public static func make(at packageURL: URL, inputFingerprint: String) throws -> Self {
    // A candidate is a static artifact. Never import injected playthroughs,
    // provider files, or arbitrary sidecars on a first publication.
    let candidatePaths = allowedPaths.union(["manifest.json", relativePath])
    let rootComponents = packageURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard
      let entries = FileManager.default.enumerator(
        at: packageURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else {
      throw GeneratedPackageError.invalidRevision
    }
    for case let url as URL in entries {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
      guard components.starts(with: rootComponents) else { throw GeneratedPackageError.invalidRevision }
      let path = components.dropFirst(rootComponents.count).joined(separator: "/")
      guard values.isSymbolicLink != true,
        values.isDirectory == true || candidatePaths.contains(path)
      else {
        throw GeneratedPackageError.invalidRevision
      }
    }
    var assets: [String: String] = [:]
    for path in allowedPaths.sorted() {
      let url = packageURL.appendingPathComponent(path)
      if FileManager.default.fileExists(atPath: url.path) {
        assets[path] = try fingerprint(url)
      }
    }
    guard assets["lorebook/lorebook.json"] != nil,
      assets["factory/provenance.json"] != nil
    else { throw GeneratedPackageError.invalidRevision }
    return Self(
      inputFingerprint: inputFingerprint,
      candidateManifestFingerprint: try fingerprint(
        packageURL.appendingPathComponent("manifest.json")), assets: assets)
  }

  public static func load(at packageURL: URL) throws -> Self {
    let result = try StoryworldCoding.makeDecoder().decode(
      Self.self,
      from: Data(contentsOf: packageURL.appendingPathComponent(relativePath)))
    guard !result.inputFingerprint.isEmpty, Set(result.assets.keys).isSubset(of: allowedPaths),
      result.assets["lorebook/lorebook.json"] != nil,
      result.assets["factory/provenance.json"] != nil
    else { throw GeneratedPackageError.invalidRevision }
    return result
  }

  public func matchesFiles(at packageURL: URL, includingCandidateManifest: Bool = false) throws
    -> Bool
  {
    if includingCandidateManifest,
      try Self.fingerprint(packageURL.appendingPathComponent("manifest.json"))
        != candidateManifestFingerprint
    {
      return false
    }
    for (path, hash) in assets {
      let url = packageURL.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: url.path), try Self.fingerprint(url) == hash
      else {
        return false
      }
    }
    return true
  }

  public func write(to packageURL: URL) throws {
    try StoryworldCoding.makeEncoder().encode(self).write(
      to: packageURL.appendingPathComponent(Self.relativePath), options: .atomic)
  }

  /// Replacing a disposable candidate also uses the existing crash journal.
  /// Keep the prior candidate as a backup until the replacement has committed.
  public static func installCandidate(from staging: URL, to destination: URL) throws {
    let root = destination.deletingLastPathComponent()
    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.withExclusiveAccess {
      try journal.recoverPendingReplacements()
      let backup = root.appendingPathComponent(".previous-\(UUID().uuidString).storyworld")
      try journal.replaceDirectory(stagingURL: staging, finalURL: destination, backupURL: backup)
      try? FileManager.default.removeItem(at: backup)
    }
  }

  fileprivate static func fingerprint(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? Int.max) <= 16 * 1_024 * 1_024
    else {
      throw GeneratedPackageError.invalidRevision
    }
    return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
}

public enum GeneratedPackageError: Error, Equatable, LocalizedError {
  case invalidRevision
  case editedGeneratedContent
  public var errorDescription: String? {
    switch self {
    case .invalidRevision: "工坊候选版本无效，请重新生成候选。"
    case .editedGeneratedContent:
      "已发布世界书中的工坊内容被手工修改，已停止更新以保留修改。请先导出备份，再在独立世界书中整理这些内容。"
    }
  }
}

enum GeneratedPackageUpdater {
  /// Must run synchronously inside the shared runtime actor so the backup and
  /// static-file transaction see one runtime head. Unowned files stay in place,
  /// including media that other actors may be writing concurrently.
  static func update(candidate: URL, live: URL, libraryRoot: URL) throws {
    let fm = FileManager.default
    let journal = DirectoryReplacementJournal(rootURL: libraryRoot)
    try journal.withExclusiveAccess {
      try journal.recoverPendingFileUpdates()
      let validator = StoryworldPackageValidator()
      let incoming = try validator.validate(at: candidate)
      var manifest = try validator.validate(at: live)
      guard incoming.storyworldID == manifest.storyworldID,
        incoming.sourceReference?.contentHash == manifest.sourceReference?.contentHash,
        incoming.content.lorebookEntry == "lorebook/lorebook.json",
        manifest.content.lorebookEntry == incoming.content.lorebookEntry
      else {
        throw GeneratedPackageError.invalidRevision
      }
      let next = try GeneratedPackageRevision.load(at: candidate)
      guard
        try GeneratedPackageRevision.make(at: candidate, inputFingerprint: next.inputFingerprint)
          == next
      else {
        throw GeneratedPackageError.invalidRevision
      }
      let previousURL = live.appendingPathComponent(GeneratedPackageRevision.relativePath)
      let previous =
        fm.fileExists(atPath: previousURL.path)
        ? try GeneratedPackageRevision.load(at: live) : nil
      if let previous {
        if previous == next { return }
        guard try previous.matchesFiles(at: live) else {
          throw GeneratedPackageError.editedGeneratedContent
        }
      } else {
        // Legacy published packages must still prove ownership by this job.
        let provenance =
          try JSONSerialization.jsonObject(
            with:
              Data(contentsOf: live.appendingPathComponent("factory/provenance.json")))
          as? [String: Any]
        guard let id = provenance?["jobID"] as? String,
          UUID(uuidString: id) == incoming.storyworldID,
          provenance?["sourceContentHash"] as? String == incoming.sourceReference?.contentHash
        else {
          throw GeneratedPackageError.invalidRevision
        }
      }
      let legacyPaths: Set<String> = [
        "lorebook/lorebook.json", "timeline.json", "plotline.json", "factory/provenance.json",
      ]
      let previouslyOwned = Set(previous?.assets.keys.map { $0 } ?? Array(legacyPaths))
      for path in Set(next.assets.keys).subtracting(previouslyOwned) {
        let existing = live.appendingPathComponent(path)
        if fm.fileExists(atPath: existing.path),
          try GeneratedPackageRevision.fingerprint(existing) != next.assets[path]
        {
          throw GeneratedPackageError.editedGeneratedContent
        }
      }
      let owned = previouslyOwned.union(next.assets.keys)
      var updates: [(url: URL, data: Data?)] = try owned.sorted().map { path in
        let target = live.appendingPathComponent(path)
        try fm.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try next.assets[path].map { hash in
          let bytes = try Data(contentsOf: candidate.appendingPathComponent(path))
          guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw GeneratedPackageError.invalidRevision
          }
          return bytes
        }
        return (target, data)
      }
      updates.append(
        (
          live.appendingPathComponent(GeneratedPackageRevision.relativePath),
          try StoryworldCoding.makeEncoder().encode(next)
        ))
      manifest.revision += 1
      manifest.modifiedAt = Date()
      // Preserve title, identity, language and author-managed content. Only
      // checksums for replaced files are updated; stale removed hashes vanish.
      for path in owned { manifest.checksums[path] = next.assets[path] }
      updates.append(
        (
          live.appendingPathComponent("manifest.json"),
          try StoryworldCoding.makeEncoder().encode(manifest)
        ))
      let backup = libraryRoot.appendingPathComponent("Backups", isDirectory: true)
        .appendingPathComponent(manifest.storyworldID.uuidString.lowercased(), isDirectory: true)
        .appendingPathComponent("revision-\(manifest.revision - 1)-\(UUID().uuidString).storyworld")
      try fm.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      // A hidden incomplete backup never appears as a usable restore point.
      let stagingBackup = backup.deletingLastPathComponent().appendingPathComponent(
        ".backup-\(UUID().uuidString).storyworld")
      defer { try? fm.removeItem(at: stagingBackup) }
      try fm.copyItem(at: live, to: stagingBackup)
      _ = try validator.validate(at: stagingBackup)
      try fm.moveItem(at: stagingBackup, to: backup)
      try journal.performFileChanges(updates)
    }
  }
}
