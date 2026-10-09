import Foundation
import NovelDocumentCore
import StoryworldCore

public enum FactorySourceFormat: String, Codable, CaseIterable, Sendable {
  case text = "txt"
  case markdown = "md"
  case epub
}

public enum FactoryStage: String, Codable, CaseIterable, Hashable, Sendable {
  case queued
  case parsing
  case indexing
  case analyzing
  case waitingForUser = "waiting_for_user"
  case generating
  case validating
  case readyToPublish = "ready_to_publish"
  case completed
  case failed
  case cancelled

  public var isRunning: Bool {
    [.parsing, .indexing, .analyzing, .generating, .validating].contains(self)
  }
}

public struct FactoryFailure: Codable, Equatable, Sendable {
  public enum Category: String, Codable, Sendable {
    case interrupted
    case sourceChanged = "source_changed"
    case bridgeUnavailable = "bridge_unavailable"
    case bridgeVersion = "bridge_version"
    case authentication
    case model
    case invalidOutput = "invalid_output"
    case validation
    case publishing
    case cancelled
    case unknown
  }

  public let category: Category
  public let message: String
  public let retryable: Bool

  public init(category: Category, message: String, retryable: Bool) {
    self.category = category
    self.message = message
    self.retryable = retryable
  }
}

public struct FactoryJob: Codable, Equatable, Sendable, Identifiable {
  public static let currentSchemaVersion = 1
  public static let executorProtocolVersion = 1
  public static let inputSchemaVersion = 1
  public static let outputSchemaVersion = 1

  public let schemaVersion: Int
  public let id: UUID
  public let documentID: UUID
  public let sourceName: String
  public let sourceFormat: FactorySourceFormat
  public let sourceTitle: String
  public let sourceContentHash: String
  public let sourceSnapshotRelativePath: String
  public let executorProtocolVersion: Int
  public let inputSchemaVersion: Int
  public let outputSchemaVersion: Int
  public var executorVersion: String?
  public var executorSessionID: String?
  public var stage: FactoryStage
  public var resumeStage: FactoryStage?
  public var progress: Double
  public var failure: FactoryFailure?
  public var retryCount: Int
  public var candidatePackageRelativePath: String?
  public var publishedStoryworldID: UUID?
  public var tasteConfiguration: FactoryTasteConfiguration?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    sourceName: String,
    sourceFormat: FactorySourceFormat,
    sourceTitle: String,
    sourceContentHash: String,
    sourceSnapshotRelativePath: String = "input",
    stage: FactoryStage = .queued,
    progress: Double = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.documentID = documentID
    self.sourceName = sourceName
    self.sourceFormat = sourceFormat
    self.sourceTitle = sourceTitle
    self.sourceContentHash = sourceContentHash
    self.sourceSnapshotRelativePath = sourceSnapshotRelativePath
    executorProtocolVersion = Self.executorProtocolVersion
    inputSchemaVersion = Self.inputSchemaVersion
    outputSchemaVersion = Self.outputSchemaVersion
    executorVersion = nil
    executorSessionID = nil
    self.stage = stage
    resumeStage = nil
    self.progress = min(max(progress, 0), 1)
    failure = nil
    retryCount = 0
    candidatePackageRelativePath = nil
    publishedStoryworldID = nil
    tasteConfiguration = nil
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, id, documentID, sourceName, sourceFormat, sourceTitle
    case sourceContentHash, sourceSnapshotRelativePath, executorProtocolVersion
    case inputSchemaVersion, outputSchemaVersion, executorVersion, executorSessionID
    case stage, resumeStage, progress, failure, retryCount, candidatePackageRelativePath
    case publishedStoryworldID, tasteConfiguration, createdAt, updatedAt
  }

  /// 波次 3 之前的存量任务包使用旧桥接层命名的字段，解码时兜底读取。
  private enum LegacyCodingKeys: String, CodingKey {
    case bridgeProtocolVersion, openCodeVersion, openCodeSessionID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    id = try container.decode(UUID.self, forKey: .id)
    documentID = try container.decode(UUID.self, forKey: .documentID)
    sourceName = try container.decode(String.self, forKey: .sourceName)
    sourceFormat = try container.decode(FactorySourceFormat.self, forKey: .sourceFormat)
    sourceTitle = try container.decode(String.self, forKey: .sourceTitle)
    sourceContentHash = try container.decode(String.self, forKey: .sourceContentHash)
    sourceSnapshotRelativePath = try container.decode(
      String.self, forKey: .sourceSnapshotRelativePath)
    executorProtocolVersion =
      try container.decodeIfPresent(Int.self, forKey: .executorProtocolVersion)
      ?? legacy.decodeIfPresent(Int.self, forKey: .bridgeProtocolVersion)
      ?? Self.executorProtocolVersion
    inputSchemaVersion = try container.decode(Int.self, forKey: .inputSchemaVersion)
    outputSchemaVersion = try container.decode(Int.self, forKey: .outputSchemaVersion)
    executorVersion =
      try container.decodeIfPresent(String.self, forKey: .executorVersion)
      ?? legacy.decodeIfPresent(String.self, forKey: .openCodeVersion)
    executorSessionID =
      try container.decodeIfPresent(String.self, forKey: .executorSessionID)
      ?? legacy.decodeIfPresent(String.self, forKey: .openCodeSessionID)
    stage = try container.decode(FactoryStage.self, forKey: .stage)
    resumeStage = try container.decodeIfPresent(FactoryStage.self, forKey: .resumeStage)
    progress = try container.decode(Double.self, forKey: .progress)
    failure = try container.decodeIfPresent(FactoryFailure.self, forKey: .failure)
    retryCount = try container.decode(Int.self, forKey: .retryCount)
    candidatePackageRelativePath = try container.decodeIfPresent(
      String.self, forKey: .candidatePackageRelativePath)
    publishedStoryworldID = try container.decodeIfPresent(UUID.self, forKey: .publishedStoryworldID)
    tasteConfiguration = try container.decodeIfPresent(FactoryTasteConfiguration.self, forKey: .tasteConfiguration)
    if let configuration = tasteConfiguration { _ = try configuration.overrides.validated() }
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(id, forKey: .id)
    try container.encode(documentID, forKey: .documentID)
    try container.encode(sourceName, forKey: .sourceName)
    try container.encode(sourceFormat, forKey: .sourceFormat)
    try container.encode(sourceTitle, forKey: .sourceTitle)
    try container.encode(sourceContentHash, forKey: .sourceContentHash)
    try container.encode(sourceSnapshotRelativePath, forKey: .sourceSnapshotRelativePath)
    try container.encode(executorProtocolVersion, forKey: .executorProtocolVersion)
    try container.encode(inputSchemaVersion, forKey: .inputSchemaVersion)
    try container.encode(outputSchemaVersion, forKey: .outputSchemaVersion)
    try container.encodeIfPresent(executorVersion, forKey: .executorVersion)
    try container.encodeIfPresent(executorSessionID, forKey: .executorSessionID)
    try container.encode(stage, forKey: .stage)
    try container.encodeIfPresent(resumeStage, forKey: .resumeStage)
    try container.encode(progress, forKey: .progress)
    try container.encodeIfPresent(failure, forKey: .failure)
    try container.encode(retryCount, forKey: .retryCount)
    try container.encodeIfPresent(candidatePackageRelativePath, forKey: .candidatePackageRelativePath)
    try container.encodeIfPresent(publishedStoryworldID, forKey: .publishedStoryworldID)
    try container.encodeIfPresent(tasteConfiguration, forKey: .tasteConfiguration)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }
}

public struct FactoryChapterSnapshot: Codable, Equatable, Sendable {
  public let id: String
  public let ordinal: Int
  public let title: String
  public let relativePath: String
  public let utf16Length: Int
  /// Recorded from the source, never inferred from model output. Older jobs
  /// without this field can still recognize zero-length chapters.
  public let isEmpty: Bool?
  public var hasContent: Bool { !(isEmpty ?? (utf16Length == 0)) }

  public init(id: String, ordinal: Int, title: String, relativePath: String, utf16Length: Int,
    isEmpty: Bool? = nil) {
    self.id = id
    self.ordinal = ordinal
    self.title = title
    self.relativePath = relativePath
    self.utf16Length = utf16Length
    self.isEmpty = isEmpty
  }
}

public struct FactoryInputManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let documentID: UUID
  public let title: String
  public let author: String?
  public let sourceFileName: String
  public let sourceFormat: FactorySourceFormat
  public let contentHash: String
  public let totalCharacterCount: Int
  public let chapters: [FactoryChapterSnapshot]

  public init(document: NovelDocument) {
    schemaVersion = FactoryJob.inputSchemaVersion
    documentID = document.id
    title = document.title
    author = document.author
    sourceFileName = document.sourceFileName
    sourceFormat = FactorySourceFormat(rawValue: document.sourceFormat.rawValue) ?? .text
    contentHash = document.contentHash
    totalCharacterCount = document.totalCharacterCount
    chapters = document.chapters.map {
      FactoryChapterSnapshot(
        id: $0.id,
        ordinal: $0.ordinal,
        title: $0.title,
        relativePath: String(format: "chapters/%06d.txt", $0.ordinal + 1),
        utf16Length: $0.content.utf16.count,
        isEmpty: $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    }
  }
}

public struct FactoryEvidence: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let chapterTitle: String
  public let anchor: TextAnchor
  public let excerpt: String

  public init(
    id: UUID = UUID(),
    chapterTitle: String,
    anchor: TextAnchor,
    excerpt: String
  ) {
    self.id = id
    self.chapterTitle = chapterTitle
    self.anchor = anchor
    self.excerpt = excerpt
  }
}

public struct FactoryLoreProposal: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case character
    case location
    case rule
    case timeline
    case relationship
    case foreshadowing
    case scene
    case overview
  }

  public let id: String
  public let kind: Kind
  public var title: String
  public var content: String
  public var activationKeys: [String]
  public var alwaysActive: Bool
  public var evidence: [FactoryEvidence]
  /// Editorial source-reading label, not a narrative fact or an identity key.
  public var archetype: FactoryCharacterArchetype?

  public init(
    id: String,
    kind: Kind,
    title: String,
    content: String,
    activationKeys: [String] = [],
    alwaysActive: Bool = false,
    evidence: [FactoryEvidence] = [],
    archetype: FactoryCharacterArchetype? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.content = content
    self.activationKeys = activationKeys
    self.alwaysActive = alwaysActive
    self.evidence = evidence
    self.archetype = archetype
  }
}

public struct FactoryDecision: Codable, Equatable, Sendable, Identifiable {
  public enum Resolution: String, Codable, Sendable {
    case unanswered
    case acceptedRecommendation = "accepted_recommendation"
    case customAnswer = "custom_answer"
  }

  public let id: UUID
  public let jobID: UUID
  public let question: String
  public let recommendation: String
  public let rationale: String
  public let impact: String
  public let evidence: [FactoryEvidence]
  public var resolution: Resolution
  public var answer: String?
  public var resolvedAt: Date?

  public init(
    id: UUID = UUID(),
    jobID: UUID,
    question: String,
    recommendation: String,
    rationale: String = "",
    impact: String = "",
    evidence: [FactoryEvidence] = [],
    resolution: Resolution = .unanswered,
    answer: String? = nil,
    resolvedAt: Date? = nil
  ) {
    self.id = id
    self.jobID = jobID
    self.question = question
    self.recommendation = recommendation
    self.rationale = rationale
    self.impact = impact
    self.evidence = evidence
    self.resolution = resolution
    self.answer = answer
    self.resolvedAt = resolvedAt
  }
}

public struct FactoryAnalysis: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sourceContentHash: String
  public let coveredChapterIDs: [String]
  public let proposals: [FactoryLoreProposal]
  public let decisions: [FactoryDecision]
  public let warnings: [String]
  /// 逐章一句话主线摘要（按分析单元记录，含分段信息），供 FactoryPlotlineBuilder 拼接
  public let chapterSummaries: [FactoryChapterSummary]

  public init(
    sourceContentHash: String,
    coveredChapterIDs: [String],
    proposals: [FactoryLoreProposal],
    decisions: [FactoryDecision],
    warnings: [String] = [],
    chapterSummaries: [FactoryChapterSummary] = []
  ) {
    schemaVersion = FactoryJob.outputSchemaVersion
    self.sourceContentHash = sourceContentHash
    self.coveredChapterIDs = coveredChapterIDs
    self.proposals = proposals
    self.decisions = decisions
    self.warnings = warnings
    self.chapterSummaries = chapterSummaries
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, sourceContentHash, coveredChapterIDs, proposals, decisions, warnings
    case chapterSummaries
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    sourceContentHash = try container.decode(String.self, forKey: .sourceContentHash)
    coveredChapterIDs = try container.decode([String].self, forKey: .coveredChapterIDs)
    proposals = try container.decode([FactoryLoreProposal].self, forKey: .proposals)
    decisions = try container.decode([FactoryDecision].self, forKey: .decisions)
    warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    chapterSummaries =
      try container.decodeIfPresent([FactoryChapterSummary].self, forKey: .chapterSummaries) ?? []
  }
}

/// 一个分析单元（章或超长章的分段）的主线一句话摘要。
public struct FactoryChapterSummary: Codable, Equatable, Sendable {
  /// 章节标识（FactoryChapterSnapshot.id）
  public let chapterID: String
  public let chapterOrdinal: Int
  public let chapterTitle: String
  public let segmentIndex: Int
  public let segmentCount: Int
  public let summary: String

  public init(
    chapterID: String,
    chapterOrdinal: Int,
    chapterTitle: String,
    segmentIndex: Int,
    segmentCount: Int,
    summary: String
  ) {
    self.chapterID = chapterID
    self.chapterOrdinal = chapterOrdinal
    self.chapterTitle = chapterTitle
    self.segmentIndex = segmentIndex
    self.segmentCount = segmentCount
    self.summary = summary
  }
}

public struct FactoryCoverageSummary: Equatable, Sendable {
  public let totalChapterCount: Int
  public let coveredChapterCount: Int
  public let missingChapters: [FactoryChapterSnapshot]
  public let warnings: [String]
  public let plotlineCoverage: StoryPlotlineCoverage
  public var needsSupplement: Bool { !missingChapters.isEmpty || !plotlineCoverage.gaps.isEmpty }

  public var fraction: Double {
    guard totalChapterCount > 0 else { return 0 }
    return Double(coveredChapterCount) / Double(totalChapterCount)
  }

  public var percentage: Int { Int((fraction * 100).rounded()) }

  public init(manifest: FactoryInputManifest, analysis: FactoryAnalysis) {
    let covered = Set(analysis.coveredChapterIDs)
    totalChapterCount = manifest.chapters.count
    coveredChapterCount = manifest.chapters.filter { covered.contains($0.id) }.count
    missingChapters = manifest.chapters.filter { !covered.contains($0.id) }
    plotlineCoverage = FactoryPlotlineBuilder.assess(analysis: analysis, manifest: manifest).coverage
    warnings = analysis.warnings
  }
}

public struct FactoryValidationReport: Codable, Equatable, Sendable {
  public let validatedAt: Date
  public let sourceContentHash: String
  public let lorebookEntryCount: Int
  public let resolvedDecisionCount: Int
  public let warnings: [String]
  public let bakeReport: FactoryBakeReport?
  public let playerTaste: PlayerTasteProfile?

  public init(
    validatedAt: Date = Date(),
    sourceContentHash: String,
    lorebookEntryCount: Int,
    resolvedDecisionCount: Int,
    warnings: [String] = [],
    bakeReport: FactoryBakeReport? = nil,
    playerTaste: PlayerTasteProfile? = nil
  ) {
    self.validatedAt = validatedAt
    self.sourceContentHash = sourceContentHash
    self.lorebookEntryCount = lorebookEntryCount
    self.resolvedDecisionCount = resolvedDecisionCount
    self.warnings = warnings
    self.bakeReport = bakeReport
    self.playerTaste = playerTaste
  }
}

public struct FactoryDiffPreview: Codable, Equatable, Sendable {
  public let title: String
  public let newEntryTitles: [String]
  public let existingStoryworldCount: Int
  public let existingEntryCount: Int
  public let resolvedDecisionCount: Int
  public let candidateFingerprint: String?
  public let updatesExistingWorld: Bool?
  public let legacyUpdate: Bool?

  public init(
    title: String,
    newEntryTitles: [String],
    existingStoryworldCount: Int,
    existingEntryCount: Int,
    resolvedDecisionCount: Int,
    candidateFingerprint: String? = nil,
    updatesExistingWorld: Bool? = nil,
    legacyUpdate: Bool? = nil
  ) {
    self.title = title
    self.newEntryTitles = newEntryTitles
    self.existingStoryworldCount = existingStoryworldCount
    self.existingEntryCount = existingEntryCount
    self.resolvedDecisionCount = resolvedDecisionCount
    self.candidateFingerprint = candidateFingerprint
    self.updatesExistingWorld = updatesExistingWorld
    self.legacyUpdate = legacyUpdate
  }
}

public struct FactoryCandidateProvenance: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let sourceContentHash: String
  public let proposals: [FactoryLoreProposal]
  public let decisions: [FactoryDecision]
  public let coveredChapterIDs: [String]?
  public let warnings: [String]?
  public let bakeReport: FactoryBakeReport?
  public let playerTaste: PlayerTasteProfile?

  public init(
    jobID: UUID,
    sourceContentHash: String,
    proposals: [FactoryLoreProposal],
    decisions: [FactoryDecision],
    coveredChapterIDs: [String]? = nil,
    warnings: [String]? = nil,
    bakeReport: FactoryBakeReport? = nil,
    playerTaste: PlayerTasteProfile? = nil
  ) {
    self.jobID = jobID
    self.sourceContentHash = sourceContentHash
    self.proposals = proposals
    self.decisions = decisions
    self.coveredChapterIDs = coveredChapterIDs
    self.warnings = warnings
    self.bakeReport = bakeReport
    self.playerTaste = playerTaste
  }
}

public enum FactorySourceClassifier {
  public static func format(for url: URL) -> FactorySourceFormat? {
    switch url.pathExtension.lowercased() {
    case "txt": .text
    case "md", "markdown": .markdown
    case "epub": .epub
    default: nil
    }
  }
}
