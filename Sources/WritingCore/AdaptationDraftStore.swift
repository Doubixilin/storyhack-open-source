import Foundation
import NovelDocumentCore

extension AdaptationJobStore {
  public func drafts(jobID: UUID, variantID: UUID) throws -> AdaptationDraftSnapshot {
    try locked { try draftSnapshot(jobID, variantID) }
  }

  public func draft(jobID: UUID, variantID: UUID, draftID: UUID) throws -> AdaptationDraft {
    try locked { try readDraft(jobID, variantID, draftID) }
  }

  public func draftContext(jobID: UUID, variantID: UUID, target: AdaptationDraftTarget) throws -> AdaptationDraftContext {
    try locked { try currentDraftContext(jobID, variantID, target) }
  }

  /// Caller-supplied ID makes replay of a completed response idempotent.
  @discardableResult
  public func proposeDraft(context: AdaptationDraftContext, content: AdaptationDraftContent,
    generatorFingerprint: String, expectedHeadID: UUID?, draftID: UUID = UUID()) throws -> AdaptationDraft {
    try locked {
      let jobID = context.basis.jobID, variantID = context.basis.variantID
      let content = try content.validated()
      guard !generatorFingerprint.isEmpty, generatorFingerprint.count <= 200 else { throw AdaptationError.invalidDraft }
      var index = try draftIndex(jobID, variantID)
      let url = try draftPath(jobID, variantID, "versions/\(draftID.uuidString.lowercased()).json")
      // An existing version is returned only if still selected and current.
      // It must never overwrite a newer author revision during a cached rerun.
      if files.fileExists(atPath: url.path) {
        let existing = try readDraft(jobID, variantID, draftID)
        guard existing.context == context, existing.content == content, existing.generatorFingerprint == generatorFingerprint,
          index.heads[context.target.key] == draftID,
          context == (try currentDraftContext(jobID, variantID, context.target)) else { throw AdaptationError.staleDraft }
        return existing
      }
      guard index.heads[context.target.key] == expectedHeadID else { throw AdaptationError.staleEdit }
      guard context == (try currentDraftContext(jobID, variantID, context.target)) else { throw AdaptationError.staleDraft }
      let contract = try direction(jobID: jobID, revisionID: context.basis.contractRevisionID).contract
      var warnings: [String] = []
      if content.body.count < contract.minimumCharacterCount { warnings.append("正文少于合同要求的 \(contract.minimumCharacterCount) 字。") }
      if let maximum = contract.maximumCharacterCount, content.body.count > maximum {
        warnings.append("正文共 \(content.body.count) 字，超过合同上限 \(maximum) 字。")
      }
      let snapshot = try draftSnapshot(jobID, variantID)
      let priorIDs = Set(context.predecessors.map(\.id))
      let recipeKey = try content.recipe.key()
      if try snapshot.current.contains(where: {
        guard priorIDs.contains($0.draft.id) else { return false }
        return try $0.draft.content.recipe.key() == recipeKey
      }) {
        warnings.append("表达组合与前序正文重复，请核对触发、场景和写法。")
      }
      let value = AdaptationDraft(id: draftID, parentID: expectedHeadID, context: context,
        generatorFingerprint: generatorFingerprint, content: content, contentHash: try AdaptationCoding.fingerprint(content),
        warnings: warnings, createdAt: AdaptationCoding.timestamp())
      index.heads[context.target.key] = draftID; index.revision = UUID()
      try saveDraftIndex(index, jobID, variantID, extra: [(url, try AdaptationCoding.encoder().encode(value))])
      return value
    }
  }

  /// An author edit is a new pending immutable version with current dependencies.
  public func reviseDraft(jobID: UUID, variantID: UUID, draftID: UUID,
    content: AdaptationDraftContent) throws -> AdaptationDraft {
    try locked {
      let old = try readDraft(jobID, variantID, draftID)
      let context = try currentDraftContext(jobID, variantID, old.context.target)
      return try proposeDraft(context: context, content: content, generatorFingerprint: "author-revision-v1",
        expectedHeadID: draftID)
    }
  }

  @discardableResult
  public func decideDraft(jobID: UUID, variantID: UUID, draftID: UUID, expectedRevision: UUID?,
    action: ApprovalAction, note: String = "", acknowledgeWarnings: Bool = false) throws -> AdaptationDraftDecision {
    try locked {
      var index = try draftIndex(jobID, variantID)
      guard index.revision == expectedRevision else { throw AdaptationError.staleEdit }
      let value = try readDraft(jobID, variantID, draftID)
      guard index.heads[value.context.target.key] == draftID, note.count <= 4_000 else { throw AdaptationError.staleEdit }
      if let prior = index.decisions[draftID.uuidString.lowercased()] {
        _ = try checkedDecision(prior, draft: value, jobID, variantID)
        guard prior.action == action, prior.note == note, prior.acknowledgedWarnings == acknowledgeWarnings
        else { throw AdaptationError.alreadyDecided }
        return prior
      }
      if action == .approve {
        guard value.context == (try currentDraftContext(jobID, variantID, value.context.target)) else { throw AdaptationError.staleDraft }
        let predecessors = Set(value.context.predecessors.map(\.id)), recipeKey = try value.content.recipe.key()
        for other in try draftSnapshot(jobID, variantID).current where predecessors.contains(other.draft.id) {
          guard try other.draft.content.recipe.key() != recipeKey else { throw AdaptationError.invalidDraft }
        }
        guard value.warnings.isEmpty || acknowledgeWarnings else { throw AdaptationError.reviewRequired }
      }
      let decision = AdaptationDraftDecision(draftID: draftID, draftFingerprint: try value.fingerprint(), action: action,
        note: note, acknowledgedWarnings: acknowledgeWarnings, createdAt: AdaptationCoding.timestamp())
      index.decisions[draftID.uuidString.lowercased()] = decision; index.revision = UUID()
      let url = try draftPath(jobID, variantID, "decisions/\(draftID.uuidString.lowercased()).json")
      try saveDraftIndex(index, jobID, variantID, extra: [(url, try AdaptationCoding.encoder().encode(decision))])
      return decision
    }
  }

  private func currentDraftContext(_ jobID: UUID, _ variantID: UUID, _ target: AdaptationDraftTarget) throws -> AdaptationDraftContext {
    let basis = try generationBasis(jobID: jobID, variantID: variantID)
    let source = try document(for: job(jobID)), map = try anchorMap(jobID)
    let position = try draftPosition(target, source: source, map: map)
    let snapshot = try draftSnapshot(jobID, variantID)
    guard !snapshot.current.contains(where: { $0.draft.context.target.chapterID == target.chapterID
      && ($0.draft.context.target.anchorID == nil) != (target.anchorID == nil) }) else { throw AdaptationError.invalidDraft }
    var dependencies: [AdaptationDraftDependency] = []
    for view in snapshot.current where try draftPosition(view.draft.context.target, source: source, map: map) < position {
      guard !view.isStale, view.decision?.action != .reject else { throw AdaptationError.staleDraft }
      dependencies.append(.init(id: view.draft.id, contentHash: view.draft.contentHash))
    }
    let anchor = map.anchors.first { $0.id == target.anchorID }
    let review = target.anchorID.flatMap { map.reviews[$0] }
    if target.anchorID != nil {
      guard review?.action == .approve else { throw AdaptationError.reviewRequired }
      if review?.generationAction == .rewrite && anchor?.quote.isEmpty == true { throw AdaptationError.invalidAnchor }
    }
    return .init(basis: basis, target: target, anchor: anchor, anchorReview: review, predecessors: dependencies)
  }

  private func draftSnapshot(_ jobID: UUID, _ variantID: UUID) throws -> AdaptationDraftSnapshot {
    let basis = try generationBasis(jobID: jobID, variantID: variantID)
    let source = try document(for: job(jobID)), map = try anchorMap(jobID), index = try draftIndex(jobID, variantID)
    var values: [(AdaptationDraft, DraftPosition)] = []
    for (key, id) in index.heads {
      let value = try readDraft(jobID, variantID, id)
      guard key == value.context.target.key else { throw AdaptationError.invalidDraft }
      values.append((value, try draftPosition(value.context.target, source: source, map: map)))
    }
    values.sort { $0.1 < $1.1 }
    var dependencies: [AdaptationDraftDependency] = [], invalidPredecessor = false
    var views: [AdaptationDraftView] = []
    for (draft, _) in values {
      let anchor = map.anchors.first { $0.id == draft.context.target.anchorID }
      let review = draft.context.target.anchorID.flatMap { map.reviews[$0] }
      let stale = invalidPredecessor || draft.context.basis != basis || draft.context.anchor != anchor
        || draft.context.anchorReview != review || draft.context.predecessors != dependencies
        || (draft.context.target.anchorID != nil && review?.action != .approve)
      let decision = try index.decisions[draft.id.uuidString.lowercased()].map { try checkedDecision($0, draft: draft, jobID, variantID) }
      views.append(.init(draft: draft, decision: decision, isStale: stale))
      dependencies.append(.init(id: draft.id, contentHash: draft.contentHash))
      invalidPredecessor = stale || decision?.action == .reject
    }
    return .init(revision: index.revision, current: views)
  }

  private struct DraftPosition: Comparable {
    let chapter: Int, offset: Int
    let key: String
    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.chapter != rhs.chapter { return lhs.chapter < rhs.chapter }
      if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
      return lhs.key < rhs.key
    }
  }
  private func draftPosition(_ target: AdaptationDraftTarget, source: NovelDocument, map: AdaptationAnchorMap) throws -> DraftPosition {
    guard let chapter = source.chapters.first(where: { $0.id == target.chapterID }) else { throw AdaptationError.invalidDraft }
    var offset = -1
    if let id = target.anchorID {
      guard let anchor = map.anchors.first(where: { $0.id == id && $0.source.chapterID == chapter.id }) else { throw AdaptationError.invalidAnchor }
      offset = map.reviews[id]?.generationAction == .newChapter ? Int.max : anchor.source.range.location
    }
    return .init(chapter: chapter.ordinal, offset: offset, key: target.key)
  }
  private func draftIndex(_ jobID: UUID, _ variantID: UUID) throws -> AdaptationDraftIndex {
    guard try job(jobID).variants.contains(where: { $0.id == variantID }) else { throw AdaptationError.staleEdit }
    let url = try draftPath(jobID, variantID, "index.json")
    guard files.fileExists(atPath: url.path) else {
      let folder = try draftPath(jobID, variantID, "versions")
      if files.fileExists(atPath: folder.path), !(try files.contentsOfDirectory(atPath: folder.path)).isEmpty {
        throw AdaptationError.invalidDraft
      }
      return .init()
    }
    let value = try AdaptationCoding.decoder().decode(AdaptationDraftIndex.self, from: readData(url, maximum: 32_000_000))
    guard value.revision != nil, value.heads.count <= 10_000, value.decisions.count <= 50_000,
      Set(value.heads.values).count == value.heads.count else { throw AdaptationError.invalidDraft }
    return value
  }
  private func readDraft(_ jobID: UUID, _ variantID: UUID, _ id: UUID) throws -> AdaptationDraft {
    let value = try AdaptationCoding.decoder().decode(AdaptationDraft.self,
      from: readData(try draftPath(jobID, variantID, "versions/\(id.uuidString.lowercased()).json"), maximum: 4_000_000))
    guard value.id == id, value.context.basis.jobID == jobID, value.context.basis.variantID == variantID,
      value.context.basis.sourceSnapshotHash == (try job(jobID).sourceSnapshotHash),
      value.content == (try value.content.validated()), value.contentHash == (try AdaptationCoding.fingerprint(value.content)),
      value.warnings.count <= 10, value.warnings.allSatisfy({ $0.count <= 500 }),
      !value.generatorFingerprint.isEmpty, value.generatorFingerprint.count <= 200,
      value.context.predecessors.count <= 10_000, Set(value.context.predecessors.map(\.id)).count == value.context.predecessors.count
    else { throw AdaptationError.invalidDraft }
    return value
  }
  private func checkedDecision(_ value: AdaptationDraftDecision, draft: AdaptationDraft, _ jobID: UUID, _ variantID: UUID) throws -> AdaptationDraftDecision {
    let bytes = try readData(try draftPath(jobID, variantID, "decisions/\(draft.id.uuidString.lowercased()).json"), maximum: 32_768)
    guard value.draftID == draft.id, value.draftFingerprint == (try draft.fingerprint()), value.note.count <= 4_000,
      try AdaptationCoding.decoder().decode(AdaptationDraftDecision.self, from: bytes) == value else { throw AdaptationError.invalidDraft }
    return value
  }
  private func draftPath(_ jobID: UUID, _ variantID: UUID, _ suffix: String) throws -> URL {
    try path(jobID, "drafts/\(variantID.uuidString.lowercased())/" + suffix)
  }
  private func saveDraftIndex(_ index: AdaptationDraftIndex, _ jobID: UUID, _ variantID: UUID, extra: [(URL, Data)]) throws {
    let bytes = try AdaptationCoding.encoder().encode(index)
    guard bytes.count <= 32_000_000, index.heads.count <= 10_000, index.decisions.count <= 50_000 else { throw AdaptationError.invalidDraft }
    let updates = extra + [(try draftPath(jobID, variantID, "index.json"), bytes)]
    for (url, data) in updates {
      guard data.count <= 4_000_000 || url.lastPathComponent == "index.json" else { throw AdaptationError.invalidDraft }
      try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    try journal.performFileUpdates(updates.map { (url: $0.0, data: $0.1) })
  }
}
