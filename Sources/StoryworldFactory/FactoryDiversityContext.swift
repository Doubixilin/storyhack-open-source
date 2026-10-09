import CryptoKit
import Foundation
import LLMProviderKit

public enum FactoryCharacterArchetype: String, Codable, CaseIterable, Sendable {
  case protagonist, ally, mentor, rival, antagonist, supporting, other
}

/// Editorial distribution only; never substitutes for source evidence or merges
/// character identities. Each run owns one actor, with immutable batch snapshots.
actor FactoryDiversityContext {
  private var outputs: [Int: BatchOutput] = [:]
  func ingest(_ output: BatchOutput, batchIndex: Int) { outputs[batchIndex] = output }

  func snapshot(maximumTokens: Int? = nil) -> String {
    var characters: [String: FactoryCharacterArchetype?] = [:]
    for index in outputs.keys.sorted() {
      for proposal in outputs[index]?.proposals ?? [] where proposal.kind == "character" {
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !characters.keys.contains(title) else { continue }
        characters[title] = .some(proposal.archetype)
      }
    }
    let names = characters.keys.sorted()
    let distribution = FactoryCharacterArchetype.allCases.map { role in
      "\(role.rawValue)=\(characters.values.filter { $0 == role }.count)"
    }.joined(separator: "；")
    func render(_ selected: [String]) -> String {
      let listed = selected.joined(separator: "、")
      return """
      <cross_batch_context>
      已完成批次的角色候选标题（仅供减少重复，按标题统计，不等于实体合并）：\(listed.isEmpty ? "暂无" : listed)
      角色原型标签分布：\(distribution)
      \(names.count > selected.count ? "另有 \(names.count - selected.count) 个标题未列入此窗口。" : "")
      已有角色再次出现时仍应提取本批新增事实、关系变化与新证据，避免只重复旧介绍。
      分布不是配额，不得为凑类型编造角色、改写原著或遗漏重要人物。同名不同身份应在标题中明确区分。
      必须独立覆盖本批各章的摘要；跨批信息不能充当本批原文证据。
      </cross_batch_context>
      """
    }
    var selected = names.prefix(64).map { String($0.prefix(80)) }
    if let maximumTokens {
      while LLMTokenEstimate.tokens(render(selected)) > maximumTokens {
        guard !selected.isEmpty else { return "" }
        selected.removeLast()
      }
    }
    return render(selected)
  }

  func context(for url: URL, manifest: FactoryInputManifest, chapterIDs: [String],
    executor: String, maximumTokens: Int? = nil, fileManager: FileManager) throws -> FactoryBatchContext {
    if let stored = try FactoryBatchContext.load(at: url, manifest: manifest,
      chapterIDs: chapterIDs, executor: executor, fileManager: fileManager) { return stored }
    let context = FactoryBatchContext(contentHash: manifest.contentHash, chapterIDs: chapterIDs,
      executor: executor, text: snapshot(maximumTokens: maximumTokens))
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(context).write(to: url, options: .atomic)
    return context
  }
}

struct FactoryBatchContext: Codable, Sendable {
  static let version = 1
  let schemaVersion: Int
  let contentHash: String
  let chapterIDs: [String]
  let executor: String
  let text: String
  let textHash: String
  var runFingerprint: String { executor + "/diversity-v\(Self.version)/" + textHash }

  init(contentHash: String, chapterIDs: [String], executor: String, text: String) {
    schemaVersion = Self.version
    self.contentHash = contentHash
    self.chapterIDs = chapterIDs
    self.executor = executor
    self.text = text
    textHash = Self.hash(text)
  }
  static func url(for cacheURL: URL) -> URL {
    cacheURL.deletingPathExtension().appendingPathExtension("context.json")
  }
  static func load(at url: URL, manifest: FactoryInputManifest, chapterIDs: [String],
    executor: String, fileManager: FileManager) throws -> Self? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard data.count <= 32_768, let value = try? JSONDecoder().decode(Self.self, from: data),
      value.schemaVersion == version, value.contentHash == manifest.contentHash,
      value.chapterIDs == chapterIDs, value.executor == executor,
      value.text.utf8.count <= 24_576, value.textHash == hash(value.text) else { return nil }
    return value
  }
  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
