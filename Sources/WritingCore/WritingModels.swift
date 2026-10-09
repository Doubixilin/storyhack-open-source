import Foundation

public enum WritingStage: String, Codable, CaseIterable, Sendable {
  case themeDiscussion = "theme_discussion"
  case themeApproved = "theme_approved"
  case bibleReady = "bible_ready"
  case outlineFrozen = "outline_frozen"
  case drafting
  case reviewing
  case revising
  case chapterFinalized = "chapter_finalized"
  case published

  public var displayName: String {
    switch self {
    case .themeDiscussion: "主题讨论"
    case .themeApproved: "主题已确认"
    case .bibleReady: "人物与世界基础"
    case .outlineFrozen: "大纲已冻结"
    case .drafting: "章节草稿"
    case .reviewing: "审稿"
    case .revising: "修订"
    case .chapterFinalized: "章节已定稿"
    case .published: "已发布"
    }
  }
}

public enum WritingError: Error, Equatable, LocalizedError {
  case invalidPackage
  case proposalNotFound(UUID)
  case proposalAlreadyDecided(UUID)
  case wrongProposalKind
  case invalidStage(expected: String, actual: WritingStage)
  case chapterLineageMismatch(expected: String, actual: String)
  case outlineNotFrozen
  case reviewRequired
  case noFinalChapters
  case unsafeChapterID
  case destinationExists

  public var errorDescription: String? {
    switch self {
    case .invalidPackage: "写作项目包不完整或已损坏"
    case .proposalNotFound(let id): "没有找到候选：\(id.uuidString)"
    case .proposalAlreadyDecided(let id): "候选已经处理：\(id.uuidString)"
    case .wrongProposalKind: "当前候选类型不能执行此操作"
    case .invalidStage(let expected, let actual):
      "当前阶段（\(actual.displayName)）不能执行此操作（需要：\(expected)）"
    case .chapterLineageMismatch(let expected, let actual):
      "操作的章节与当前进行中的章节不一致（需要：\(expected)，实际：\(actual)）"
    case .outlineNotFrozen: "必须先批准并冻结大纲，才能正式写章"
    case .reviewRequired: "必须先完成本章审稿，才能提交修订定稿"
    case .noFinalChapters: "至少需要一个已批准定稿章节才能发布"
    case .unsafeChapterID: "章节 ID 只能包含字母、数字、短横线和下划线"
    case .destinationExists: "目标写作项目已经存在"
    }
  }
}

public struct WritingProjectManifest: Codable, Equatable, Identifiable, Sendable {
  public let formatVersion: Int
  public let id: UUID
  public var publishedBookID: UUID
  public var title: String
  public var author: String?
  public var stage: WritingStage
  public var activeOutlineRevisionID: UUID?
  public var currentChapterID: String?
  public let createdAt: Date
  public var modifiedAt: Date

  public init(
    formatVersion: Int = 1,
    id: UUID = UUID(),
    publishedBookID: UUID = UUID(),
    title: String,
    author: String? = nil,
    stage: WritingStage = .themeDiscussion,
    activeOutlineRevisionID: UUID? = nil,
    currentChapterID: String? = nil,
    createdAt: Date = Date(),
    modifiedAt: Date = Date()
  ) {
    self.formatVersion = formatVersion
    self.id = id
    self.publishedBookID = publishedBookID
    self.title = title
    self.author = author
    self.stage = stage
    self.activeOutlineRevisionID = activeOutlineRevisionID
    self.currentChapterID = currentChapterID
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
  }

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case id
    case publishedBookID = "published_book_id"
    case title
    case author
    case stage
    case activeOutlineRevisionID = "active_outline_revision_id"
    case currentChapterID = "current_chapter_id"
    case createdAt = "created_at"
    case modifiedAt = "modified_at"
  }
}

public enum WritingProposalKind: String, Codable, Sendable {
  case theme
  case outline
  case chapterDraft = "chapter_draft"
  case review
  case revision
}

public enum WritingProposalStatus: String, Codable, Sendable {
  case pending
  case approved
  case rejected
}

public struct WritingProposal: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: WritingProposalKind
  public let chapterID: String?
  public let ordinal: Int?
  public let chapterTitle: String?
  public let content: String
  public let inputHash: String
  public let origin: String
  public var status: WritingProposalStatus
  public let createdAt: Date
  public var decidedAt: Date?

  public init(
    id: UUID = UUID(),
    kind: WritingProposalKind,
    chapterID: String? = nil,
    ordinal: Int? = nil,
    chapterTitle: String? = nil,
    content: String,
    inputHash: String,
    origin: String = "local_manual",
    status: WritingProposalStatus = .pending,
    createdAt: Date = Date(),
    decidedAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.chapterID = chapterID
    self.ordinal = ordinal
    self.chapterTitle = chapterTitle
    self.content = content
    self.inputHash = inputHash
    self.origin = origin
    self.status = status
    self.createdAt = createdAt
    self.decidedAt = decidedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case kind
    case chapterID = "chapter_id"
    case ordinal
    case chapterTitle = "chapter_title"
    case content
    case inputHash = "input_hash"
    case origin
    case status
    case createdAt = "created_at"
    case decidedAt = "decided_at"
  }
}

public enum ApprovalAction: String, Codable, Sendable {
  case approve
  case reject
}

public struct ApprovalEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let proposalID: UUID
  public let action: ApprovalAction
  public let note: String?
  public let createdAt: Date

  public init(
    id: UUID,
    proposalID: UUID,
    action: ApprovalAction,
    note: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.proposalID = proposalID
    self.action = action
    self.note = note
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case proposalID = "proposal_id"
    case action
    case note
    case createdAt = "created_at"
  }
}

public struct OutlineRevision: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let content: String
  public let frozen: Bool
  public let createdAt: Date

  public init(id: UUID = UUID(), content: String, frozen: Bool, createdAt: Date = Date()) {
    self.id = id
    self.content = content
    self.frozen = frozen
    self.createdAt = createdAt
  }
}

public enum ChapterRevisionKind: String, Codable, Sendable {
  case draft
  case revised
  case final
}

public struct ChapterRevision: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let chapterID: String
  public let ordinal: Int
  public let title: String
  public let kind: ChapterRevisionKind
  public let content: String
  public let proposalID: UUID
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    chapterID: String,
    ordinal: Int,
    title: String,
    kind: ChapterRevisionKind,
    content: String,
    proposalID: UUID,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.chapterID = chapterID
    self.ordinal = ordinal
    self.title = title
    self.kind = kind
    self.content = content
    self.proposalID = proposalID
    self.createdAt = createdAt
  }
}

public struct WritingContextManifest: Codable, Equatable, Sendable {
  public let chapterID: String
  public let outlineRevisionID: UUID
  public let selectedMaterials: [String]
  public let compilerVersion: String
  public let compiledAt: Date

  public init(
    chapterID: String,
    outlineRevisionID: UUID,
    selectedMaterials: [String],
    compilerVersion: String = "deterministic-v1",
    compiledAt: Date = Date()
  ) {
    self.chapterID = chapterID
    self.outlineRevisionID = outlineRevisionID
    self.selectedMaterials = selectedMaterials
    self.compilerVersion = compilerVersion
    self.compiledAt = compiledAt
  }

  enum CodingKeys: String, CodingKey {
    case chapterID = "chapter_id"
    case outlineRevisionID = "outline_revision_id"
    case selectedMaterials = "selected_materials"
    case compilerVersion = "compiler_version"
    case compiledAt = "compiled_at"
  }
}

public struct PublicationChapter: Codable, Equatable, Identifiable, Sendable {
  public var id: String { chapterID }
  public let chapterID: String
  public let ordinal: Int
  public let title: String
  public let content: String

  public init(chapterID: String, ordinal: Int, title: String, content: String) {
    self.chapterID = chapterID
    self.ordinal = ordinal
    self.title = title
    self.content = content
  }

  enum CodingKeys: String, CodingKey {
    case chapterID = "chapter_id"
    case ordinal
    case title
    case content
  }
}

public struct PublicationSnapshot: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { revisionID }
  public let projectID: UUID
  public let publishedBookID: UUID
  public let revisionID: UUID
  public let title: String
  public let author: String?
  public let chapters: [PublicationChapter]
  public let createdAt: Date

  public init(
    projectID: UUID,
    publishedBookID: UUID,
    revisionID: UUID = UUID(),
    title: String,
    author: String?,
    chapters: [PublicationChapter],
    createdAt: Date = Date()
  ) {
    self.projectID = projectID
    self.publishedBookID = publishedBookID
    self.revisionID = revisionID
    self.title = title
    self.author = author
    self.chapters = chapters
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case publishedBookID = "published_book_id"
    case revisionID = "revision_id"
    case title
    case author
    case chapters
    case createdAt = "created_at"
  }
}

public struct WritingProjectSnapshot: Equatable, Sendable {
  public let manifest: WritingProjectManifest
  public let theme: String
  public let authorIntent: String
  public let style: String
  public let charactersJSON: String
  public let world: String
  public let timelineJSON: String
  public let storyStateJSON: String
  public let foreshadowingJSON: String
  public let activeOutline: OutlineRevision?
  public let proposals: [WritingProposal]
  public let finalChapters: [PublicationChapter]
  public let publications: [PublicationSnapshot]

  public init(
    manifest: WritingProjectManifest,
    theme: String,
    authorIntent: String,
    style: String,
    charactersJSON: String,
    world: String,
    timelineJSON: String,
    storyStateJSON: String,
    foreshadowingJSON: String,
    activeOutline: OutlineRevision?,
    proposals: [WritingProposal],
    finalChapters: [PublicationChapter],
    publications: [PublicationSnapshot]
  ) {
    self.manifest = manifest
    self.theme = theme
    self.authorIntent = authorIntent
    self.style = style
    self.charactersJSON = charactersJSON
    self.world = world
    self.timelineJSON = timelineJSON
    self.storyStateJSON = storyStateJSON
    self.foreshadowingJSON = foreshadowingJSON
    self.activeOutline = activeOutline
    self.proposals = proposals
    self.finalChapters = finalChapters
    self.publications = publications
  }
}

public struct WritingProjectSummary: Equatable, Identifiable, Sendable {
  public var id: UUID { manifest.id }
  public let packageURL: URL
  public let manifest: WritingProjectManifest
}
