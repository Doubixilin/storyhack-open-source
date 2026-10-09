import Foundation
import NovelDocumentCore

public enum AdaptationAssemblyError: Error, Equatable, LocalizedError {
  case noDrafts, unapprovedDrafts, unchangedChapters, conflictingEdits, invalidEPUB, unsafeArchive, unsupportedSource
  public var errorDescription: String? {
    switch self {
    case .noDrafts: "没有可装配的正文候选。"
    case .unapprovedDrafts: "选中的正文须先由作者批准，并重新处理过期依赖。"
    case .unchangedChapters: "仍有章节沿用原文，请核对后明确确认。"
    case .conflictingEdits: "选中的正文修改范围重叠，或缺少其依赖版本，请调整选择。"
    case .invalidEPUB: "EPUB 结构、章节路径或目录无法安全装配，原档案保留。"
    case .unsafeArchive: "EPUB 包含不安全路径、重复条目、链接或过大内容。"
    case .unsupportedSource: "该原始档案不能用于 EPUB 保真装配。"
    }
  }
}

public struct AdaptationAssemblyChapter: Codable, Equatable, Sendable {
  public let id: String
  public let sourceChapterID: String
  public let title: String
  public let content: String
  public let isNew: Bool
  public let changed: Bool
  public let sourceHref: String?
  enum CodingKeys: String, CodingKey {
    case id, title, content, changed, sourceChapterID = "source_chapter_id", isNew = "is_new", sourceHref = "source_href"
  }
}

public struct AdaptationAssembly: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let variantID: UUID
  public let sourceSnapshotHash: String
  public let draftRevision: UUID
  public let title: String
  public let author: String?
  public let selectedDraftIDs: [UUID]
  public let unchangedChapterIDs: [String]
  public let chapters: [AdaptationAssemblyChapter]
  public let comparisonMarkdown: String
  public func fingerprint() throws -> String { try AdaptationCoding.fingerprint(self) }
  public var plainText: String { chapters.map { $0.title + "\n\n" + $0.content }.joined(separator: "\n\n") + "\n" }
  enum CodingKeys: String, CodingKey {
    case title, author, chapters, jobID = "job_id", variantID = "variant_id", sourceSnapshotHash = "source_snapshot_hash"
    case draftRevision = "draft_revision", selectedDraftIDs = "selected_draft_ids", unchangedChapterIDs = "unchanged_chapter_ids"
    case comparisonMarkdown = "comparison_markdown"
  }
}

extension AdaptationJobStore {
  /// A reviewable assembly preview; unchanged source chapters are explicit.
  /// Exporters must revalidate this exact preview before writing an artifact.
  public func prepareAssembly(jobID: UUID, variantID: UUID, expectedDraftRevision: UUID?,
    selectedDraftIDs: [UUID]? = nil) throws -> AdaptationAssembly {
    try locked {
      let current = try job(jobID), source = try document(for: current)
      guard let variant = current.variants.first(where: { $0.id == variantID }) else { throw AdaptationError.staleEdit }
      let snapshot = try drafts(jobID: jobID, variantID: variantID)
      guard snapshot.revision == expectedDraftRevision else { throw AdaptationError.staleEdit }
      let selected = selectedDraftIDs.map(Set.init) ?? Set(snapshot.current.map { $0.draft.id })
      guard let revision = snapshot.revision, !selected.isEmpty else { throw AdaptationAssemblyError.noDrafts }
      guard selected.count == (selectedDraftIDs?.count ?? selected.count), selected.isSubset(of: Set(snapshot.current.map { $0.draft.id }))
      else { throw AdaptationError.staleEdit }
      let views = snapshot.current.filter { selected.contains($0.draft.id) }
      guard views.allSatisfy({ !$0.isStale && $0.decision?.action == .approve }) else { throw AdaptationAssemblyError.unapprovedDrafts }
      guard views.allSatisfy({ Set($0.draft.context.predecessors.map(\.id)).isSubset(of: selected) }) else { throw AdaptationAssemblyError.conflictingEdits }
      let grouped = Dictionary(grouping: views.map(\.draft), by: { $0.context.target.chapterID })
      var result: [AdaptationAssemblyChapter] = [], unchanged: [String] = []
      var report = "# " + markdownText(variant.title) + "：改编对照\n\n"
        + "仅包含当前、已批准的正文版本；模型章审为自报，需结合原文人工核对。\n\n"
      for chapter in source.chapters {
        let drafts = grouped[chapter.id] ?? []
        let replacements = drafts.filter { $0.context.target.anchorID == nil }
        let anchors = drafts.filter { $0.context.target.anchorID != nil && $0.context.action != .newChapter }
        guard replacements.count <= 1, replacements.isEmpty || anchors.isEmpty else { throw AdaptationAssemblyError.conflictingEdits }
        var content = replacements.first?.content.body ?? chapter.content
        let title = replacements.first?.content.title ?? chapter.title
        if replacements.isEmpty { content = try splice(anchors, into: chapter.content) }
        let changed = !replacements.isEmpty || !anchors.isEmpty
        if !changed { unchanged.append(chapter.id) }
        result.append(.init(id: chapter.id, sourceChapterID: chapter.id, title: title, content: content,
          isNew: false, changed: changed, sourceHref: chapter.sourceHref))
        for draft in drafts where draft.context.action == .newChapter && draft.context.target.anchorID != nil {
          result.append(.init(id: "addition-" + draft.id.uuidString.lowercased(), sourceChapterID: chapter.id,
            title: draft.content.title, content: draft.content.body, isNew: true, changed: true, sourceHref: nil))
        }
        report += "## " + markdownText(chapter.title) + "\n\n"
          + "原文 " + String(chapter.content.count) + " 字；装配后本章 " + String(content.count) + " 字。"
          + (changed ? "\n\n" : " **沿用原文。**\n\n")
          + "原首段：\n\n" + quoted(chapter.content) + "\n\n新首段：\n\n" + quoted(content) + "\n\n"
        for draft in drafts {
          report += "- 版本：`" + draft.id.uuidString.lowercased() + "`；动作：`"
            + (draft.context.target.anchorID == nil ? "whole_chapter" : draft.context.action.rawValue)
            + "`；正文 " + String(draft.content.body.count) + " 字。\n"
            + "- 模型自报：" + markdownText(draft.content.reviewLine) + "\n"
          for warning in draft.warnings { report += "- 已核对告警：" + markdownText(warning) + "\n" }
          if draft.context.action == .newChapter { report += "\n新增章首段：\n\n" + quoted(draft.content.body) + "\n" }
          report += "\n"
        }
      }
      return .init(jobID: jobID, variantID: variantID, sourceSnapshotHash: current.sourceSnapshotHash,
        draftRevision: revision, title: variant.title, author: source.author, selectedDraftIDs: views.map { $0.draft.id },
        unchangedChapterIDs: unchanged, chapters: result, comparisonMarkdown: report)
    }
  }

  public func validateAssembly(_ assembly: AdaptationAssembly, acknowledgeUnchangedChapters: Bool = false) throws {
    try locked {
      let current = try prepareAssembly(jobID: assembly.jobID, variantID: assembly.variantID,
        expectedDraftRevision: assembly.draftRevision, selectedDraftIDs: assembly.selectedDraftIDs)
      guard current == assembly else { throw AdaptationError.staleEdit }
      guard assembly.unchangedChapterIDs.isEmpty || acknowledgeUnchangedChapters else { throw AdaptationAssemblyError.unchangedChapters }
    }
  }

  private func splice(_ drafts: [AdaptationDraft], into source: String) throws -> String {
    struct Edit { let location: Int, length: Int; let text: String, key: String }
    var edits: [Edit] = []
    for draft in drafts {
      guard let anchor = draft.context.anchor else { throw AdaptationError.invalidAnchor }
      let range = anchor.source.range
      let length = draft.context.action == .rewrite ? range.length : 0
      guard range.location >= 0, range.location <= source.utf16.count, range.length <= source.utf16.count - range.location,
        let indices = Range(NSRange(location: range.location, length: range.length), in: source),
        source[indices].utf8.elementsEqual(anchor.quote.utf8) else { throw AdaptationError.invalidAnchor }
      edits.append(.init(location: range.location, length: length, text: draft.content.body, key: draft.context.target.key))
    }
    edits.sort { $0.location == $1.location ? $0.key < $1.key : $0.location < $1.location }
    for i in edits.indices.dropFirst() {
        let a = edits[i - 1], b = edits[i]
        // Same-position insertions have a stable ID order; a replacement at
        // that position or an insertion within replaced text is ambiguous.
        if (a.location == b.location && (a.length > 0 || b.length > 0)) || b.location < a.location + a.length {
          throw AdaptationAssemblyError.conflictingEdits
        }
    }
    var result = source
    for edit in edits.reversed() {
      guard let range = Range(NSRange(location: edit.location, length: edit.length), in: result) else { throw AdaptationError.invalidAnchor }
      let text = edit.length == 0 ? edit.text + "\n\n" : edit.text
      result.replaceSubrange(range, with: text)
    }
    return result
  }
  private func markdownText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "`", with: "\\`")
  }
  private func quoted(_ text: String) -> String {
    let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "（空）"
    return "> " + markdownText(String(first.prefix(400)))
  }
}
