import CryptoKit
import DirectoryJournalCore
import Foundation

public actor WritingProjectLibrary {
  public static var defaultRootURL: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("WritingProjects", isDirectory: true)
  }

  private let rootURL: URL
  private let fileManager: FileManager

  public init(
    rootURL: URL = WritingProjectLibrary.defaultRootURL,
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  public func list() throws -> [WritingProjectSummary] {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url in
      guard url.pathExtension.lowercased() == "novelproject" else { return nil }
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
      let manifest = try WritingCoding.decoder.decode(
        WritingProjectManifest.self,
        from: Data(contentsOf: url.appendingPathComponent("manifest.json"))
      )
      return WritingProjectSummary(packageURL: url, manifest: manifest)
    }.sorted { $0.manifest.modifiedAt > $1.manifest.modifiedAt }
  }

  public func create(
    title: String,
    author: String? = nil,
    theme: String = "",
    authorIntent: String = "",
    style: String = ""
  ) async throws -> WritingProjectSummary {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let manifest = WritingProjectManifest(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名小说" : title,
      author: author?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let packageURL = rootURL.appendingPathComponent(
      manifest.id.uuidString.lowercased() + ".novelproject",
      isDirectory: true
    )
    let harness = WritingHarness(packageURL: packageURL)
    try await harness.initialize(
      manifest: manifest,
      theme: theme,
      authorIntent: authorIntent,
      style: style
    )
    return WritingProjectSummary(packageURL: packageURL, manifest: manifest)
  }

  public func importPackage(from sourceURL: URL) throws -> WritingProjectSummary {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      sourceURL.pathExtension.lowercased() == "novelproject"
    else { throw WritingError.invalidPackage }
    let manifest = try WritingCoding.decoder.decode(
      WritingProjectManifest.self,
      from: Data(contentsOf: sourceURL.appendingPathComponent("manifest.json"))
    )
    let destination = rootURL.appendingPathComponent(
      manifest.id.uuidString.lowercased() + ".novelproject",
      isDirectory: true
    )
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw WritingError.destinationExists
    }
    let staging = rootURL.appendingPathComponent(
      ".staging-\(UUID().uuidString).novelproject",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: staging) }
    try validateTree(at: sourceURL)
    try fileManager.copyItem(at: sourceURL, to: staging)
    try validateTree(at: staging)
    _ = try WritingCoding.decoder.decode(
      WritingProjectManifest.self,
      from: Data(contentsOf: staging.appendingPathComponent("manifest.json"))
    )
    try fileManager.moveItem(at: staging, to: destination)
    return WritingProjectSummary(packageURL: destination, manifest: manifest)
  }

  private func validateTree(at root: URL) throws {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: []
    ) else { throw WritingError.invalidPackage }
    var count = 0
    while let url = enumerator.nextObject() as? URL {
      count += 1
      guard count <= 20_000 else { throw WritingError.invalidPackage }
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isSymbolicLink != true,
        values.isRegularFile == true || values.isDirectory == true
      else { throw WritingError.invalidPackage }
    }
  }
}

public actor WritingHarness {
  private enum Operation: Hashable, Sendable {
    case proposeTheme
    case approveTheme
    case saveBible
    case proposeOutline
    case approveAndFreezeOutline
    case proposeChapterDraft
    case approveDraftForReview
    case submitReview
    case proposeRevision
    case approveFinal
    case publish
  }

  private static let allowedStages: [Operation: [WritingStage]] = [
    .proposeTheme: [.themeDiscussion],
    .approveTheme: [.themeDiscussion],
    .saveBible: [
      .themeApproved, .bibleReady, .outlineFrozen, .drafting, .reviewing,
      .revising, .chapterFinalized, .published,
    ],
    .proposeOutline: [.bibleReady, .outlineFrozen],
    .approveAndFreezeOutline: [.bibleReady, .outlineFrozen],
    .proposeChapterDraft: [.outlineFrozen, .drafting, .chapterFinalized, .published],
    .approveDraftForReview: [.drafting],
    .submitReview: [.reviewing],
    .proposeRevision: [.revising],
    .approveFinal: [.revising],
    .publish: [.chapterFinalized, .published],
  ]

  private let packageURL: URL
  private let fileManager: FileManager
  private let replacementJournal: DirectoryReplacementJournal

  public init(packageURL: URL, fileManager: FileManager = .default) {
    self.packageURL = packageURL
    self.fileManager = fileManager
    replacementJournal = DirectoryReplacementJournal(
      rootURL: packageURL,
      fileManager: fileManager
    )
  }

  public func initialize(
    manifest: WritingProjectManifest,
    theme: String,
    authorIntent: String,
    style: String
  ) throws {
    guard !fileManager.fileExists(atPath: packageURL.path) else {
      throw WritingError.destinationExists
    }
    let staging = packageURL.deletingLastPathComponent().appendingPathComponent(
      ".staging-\(UUID().uuidString).novelproject",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: staging) }
    for path in [
      "intent", "bible", "outline/revisions", "chapters", "state", "proposals",
      "publications",
    ] {
      try fileManager.createDirectory(
        at: staging.appendingPathComponent(path, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    try write(manifest, to: staging.appendingPathComponent("manifest.json"))
    try writeText(theme, to: staging.appendingPathComponent("intent/theme.md"))
    try writeText(authorIntent, to: staging.appendingPathComponent("intent/author-intent.md"))
    try writeText(style, to: staging.appendingPathComponent("intent/style.md"))
    try writeJSON([String](), to: staging.appendingPathComponent("bible/characters.json"))
    try writeText("", to: staging.appendingPathComponent("bible/world.md"))
    try writeJSON([String](), to: staging.appendingPathComponent("bible/timeline.json"))
    try writeJSON([String: String](), to: staging.appendingPathComponent("state/story-state.json"))
    try writeJSON([String](), to: staging.appendingPathComponent("state/foreshadowing.json"))
    try Data().write(to: staging.appendingPathComponent("events.jsonl"), options: [.atomic])
    try fileManager.moveItem(at: staging, to: packageURL)
  }

  public func load() throws -> WritingProjectSnapshot {
    try replacementJournal.recoverPendingFileUpdates()
    let manifest = try loadManifest()
    let activeOutline: OutlineRevision?
    let outlineURL = packageURL.appendingPathComponent("outline/active.json")
    if fileManager.fileExists(atPath: outlineURL.path) {
      activeOutline = try read(OutlineRevision.self, from: outlineURL)
    } else {
      activeOutline = nil
    }
    let proposals = try listJSON(WritingProposal.self, in: "proposals")
      .sorted { $0.createdAt < $1.createdAt }
    let publications = try listJSON(PublicationSnapshot.self, in: "publications")
      .sorted { $0.createdAt < $1.createdAt }
    return WritingProjectSnapshot(
      manifest: manifest,
      theme: try readText("intent/theme.md"),
      authorIntent: try readText("intent/author-intent.md"),
      style: try readText("intent/style.md"),
      charactersJSON: try readText("bible/characters.json"),
      world: try readText("bible/world.md"),
      timelineJSON: try readText("bible/timeline.json"),
      storyStateJSON: try readText("state/story-state.json"),
      foreshadowingJSON: try readText("state/foreshadowing.json"),
      activeOutline: activeOutline,
      proposals: proposals,
      finalChapters: try finalChapters(),
      publications: publications
    )
  }

  @discardableResult
  public func proposeTheme(_ content: String, proposalID: UUID = UUID()) throws -> WritingProposal {
    let manifest = try loadManifest()
    try requireStage(.proposeTheme, manifest: manifest)
    return try createProposal(id: proposalID, kind: .theme, content: content)
  }

  @discardableResult
  public func approveTheme(proposalID: UUID) throws -> WritingProjectSnapshot {
    let manifest = try loadManifest()
    try requireStage(.approveTheme, manifest: manifest)
    var proposal = try pendingProposal(id: proposalID, kind: .theme)
    try writeText(proposal.content, to: packageURL.appendingPathComponent("intent/theme.md"))
    try updateManifest(stage: .themeApproved)
    try finish(&proposal, action: .approve)
    return try load()
  }

  public func saveBible(charactersJSON: String, world: String, timelineJSON: String) throws {
    let manifest = try loadManifest()
    try requireStage(.saveBible, manifest: manifest)
    _ = try JSONSerialization.jsonObject(with: Data(charactersJSON.utf8))
    _ = try JSONSerialization.jsonObject(with: Data(timelineJSON.utf8))
    try writeText(charactersJSON, to: packageURL.appendingPathComponent("bible/characters.json"))
    try writeText(world, to: packageURL.appendingPathComponent("bible/world.md"))
    try writeText(timelineJSON, to: packageURL.appendingPathComponent("bible/timeline.json"))
    if manifest.stage == .themeApproved {
      try updateManifest(stage: .bibleReady)
    }
  }

  @discardableResult
  public func proposeOutline(_ content: String, proposalID: UUID = UUID()) throws -> WritingProposal {
    let manifest = try loadManifest()
    try requireStage(.proposeOutline, manifest: manifest)
    return try createProposal(id: proposalID, kind: .outline, content: content)
  }

  @discardableResult
  public func approveAndFreezeOutline(proposalID: UUID) throws -> OutlineRevision {
    let manifest = try loadManifest()
    try requireStage(.approveAndFreezeOutline, manifest: manifest)
    var proposal = try pendingProposal(id: proposalID, kind: .outline)
    let revision = OutlineRevision(content: proposal.content, frozen: true)
    try write(revision, to: packageURL.appendingPathComponent(
      "outline/revisions/\(revision.id.uuidString.lowercased()).json"
    ))
    try write(revision, to: packageURL.appendingPathComponent("outline/active.json"))
    try updateManifest(stage: .outlineFrozen, activeOutlineRevisionID: revision.id)
    try finish(&proposal, action: .approve)
    return revision
  }

  @discardableResult
  public func proposeChapterDraft(
    chapterID: String,
    ordinal: Int,
    title: String,
    intent: String,
    content: String,
    proposalID: UUID = UUID()
  ) throws -> WritingProposal {
    try validateChapterID(chapterID)
    let manifest = try loadManifest()
    guard Self.allowedStages[.proposeChapterDraft]?.contains(manifest.stage) == true else {
      throw WritingError.outlineNotFrozen
    }
    if manifest.stage == .drafting {
      try requireLineage(chapterID, manifest: manifest)
    }
    if fileManager.fileExists(atPath: proposalURL(proposalID).path) {
      return try createProposal(
        id: proposalID,
        kind: .chapterDraft,
        chapterID: chapterID,
        ordinal: ordinal,
        chapterTitle: title,
        content: content
      )
    }
    guard let outlineID = manifest.activeOutlineRevisionID else {
      throw WritingError.outlineNotFrozen
    }
    let directory = chapterDirectory(chapterID)
    try fileManager.createDirectory(
      at: directory.appendingPathComponent("revisions", isDirectory: true),
      withIntermediateDirectories: true
    )
    try writeText(intent, to: directory.appendingPathComponent("intent.json"))
    let context = WritingContextManifest(
      chapterID: chapterID,
      outlineRevisionID: outlineID,
      selectedMaterials: [
        "intent/author-intent.md", "intent/style.md", "bible/characters.json",
        "bible/world.md", "bible/timeline.json", "outline/active.json",
      ]
    )
    try write(context, to: directory.appendingPathComponent("context-manifest.json"))
    let proposal = try createProposal(
      id: proposalID,
      kind: .chapterDraft,
      chapterID: chapterID,
      ordinal: ordinal,
      chapterTitle: title,
      content: content
    )
    try updateManifest(stage: .drafting, currentChapterID: chapterID)
    return proposal
  }

  @discardableResult
  public func approveDraftForReview(proposalID: UUID) throws -> ChapterRevision {
    let manifest = try loadManifest()
    try requireStage(.approveDraftForReview, manifest: manifest)
    var proposal = try pendingProposal(id: proposalID, kind: .chapterDraft)
    try requireLineage(proposal.chapterID ?? "", manifest: manifest)
    let revision = try makeChapterRevision(proposal: proposal, kind: .draft)
    try writeChapterRevision(revision)
    try updateManifest(stage: .reviewing, currentChapterID: revision.chapterID)
    try finish(&proposal, action: .approve)
    return revision
  }

  @discardableResult
  public func submitReview(
    chapterID: String,
    report: String,
    proposalID: UUID = UUID()
  ) throws -> WritingProposal {
    try validateChapterID(chapterID)
    let manifest = try loadManifest()
    try requireLineage(chapterID, manifest: manifest)
    try requireStage(.submitReview, manifest: manifest)
    let proposal = try createProposal(
      id: proposalID,
      kind: .review,
      chapterID: chapterID,
      content: report
    )
    var approved = proposal
    try finish(&approved, action: .approve)
    try updateManifest(stage: .revising, currentChapterID: chapterID)
    return approved
  }

  @discardableResult
  public func proposeRevision(
    chapterID: String,
    ordinal: Int,
    title: String,
    content: String,
    proposalID: UUID = UUID()
  ) throws -> WritingProposal {
    try validateChapterID(chapterID)
    let manifest = try loadManifest()
    try requireLineage(chapterID, manifest: manifest)
    try requireStage(.proposeRevision, manifest: manifest)
    return try createProposal(
      id: proposalID,
      kind: .revision,
      chapterID: chapterID,
      ordinal: ordinal,
      chapterTitle: title,
      content: content
    )
  }

  @discardableResult
  public func approveFinal(
    proposalID: UUID,
    storyStateJSON: String = "{}",
    foreshadowingJSON: String = "[]"
  ) throws -> ChapterRevision {
    let manifest = try loadManifest()
    try requireStage(.approveFinal, manifest: manifest)
    var proposal = try pendingProposal(id: proposalID, kind: .revision)
    try requireLineage(proposal.chapterID ?? "", manifest: manifest)
    let reviews = try listJSON(WritingProposal.self, in: "proposals")
    guard reviews.contains(where: {
      $0.kind == .review && $0.chapterID == proposal.chapterID && $0.status == .approved
    }) else { throw WritingError.reviewRequired }
    _ = try JSONSerialization.jsonObject(with: Data(storyStateJSON.utf8))
    _ = try JSONSerialization.jsonObject(with: Data(foreshadowingJSON.utf8))

    let revision = try makeChapterRevision(proposal: proposal, kind: .final)
    var finalizedManifest = manifest
    finalizedManifest.stage = .chapterFinalized
    finalizedManifest.currentChapterID = revision.chapterID
    finalizedManifest.modifiedAt = Date()
    proposal.status = .approved
    proposal.decidedAt = Date()
    let event = ApprovalEvent(
      id: proposal.id,
      proposalID: proposal.id,
      action: .approve
    )

    let revisionURL = chapterDirectory(revision.chapterID)
      .appendingPathComponent("revisions", isDirectory: true)
      .appendingPathComponent(revision.id.uuidString.lowercased() + ".json")
    let finalURL = chapterDirectory(revision.chapterID).appendingPathComponent("final.md")
    let storyStateURL = packageURL.appendingPathComponent("state/story-state.json")
    let foreshadowingURL = packageURL.appendingPathComponent("state/foreshadowing.json")
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let candidateURL = proposalURL(proposal.id)
    let updates: [(url: URL, data: Data)] = [
      (revisionURL, try WritingCoding.encoder.encode(revision)),
      (finalURL, Data(revision.content.utf8)),
      (storyStateURL, Data(storyStateJSON.utf8)),
      (foreshadowingURL, Data(foreshadowingJSON.utf8)),
      (manifestURL, try WritingCoding.encoder.encode(finalizedManifest)),
      (candidateURL, try WritingCoding.encoder.encode(proposal)),
    ]

    try replacementJournal.performFileUpdates(updates)
    try appendEventIfMissing(event)
    return revision
  }

  @discardableResult
  public func publish() throws -> PublicationSnapshot {
    let manifest = try loadManifest()
    try requireStage(.publish, manifest: manifest)
    let chapters = try finalChapters()
    guard !chapters.isEmpty else { throw WritingError.noFinalChapters }
    if manifest.stage == .published {
      let latest = try listJSON(PublicationSnapshot.self, in: "publications")
        .sorted { $0.createdAt > $1.createdAt }
        .first
      if let latest, latest.chapters == chapters {
        return latest
      }
    }
    let snapshot = PublicationSnapshot(
      projectID: manifest.id,
      publishedBookID: manifest.publishedBookID,
      title: manifest.title,
      author: manifest.author,
      chapters: chapters
    )
    try write(
      snapshot,
      to: packageURL.appendingPathComponent(
        "publications/\(snapshot.revisionID.uuidString.lowercased()).json"
      )
    )
    try updateManifest(stage: .published)
    return snapshot
  }

  @discardableResult
  public func reject(proposalID: UUID, note: String? = nil) throws -> WritingProposal {
    var proposal = try pendingProposal(id: proposalID, kind: nil)
    try finish(&proposal, action: .reject, note: note)
    return proposal
  }

  private func requireStage(
    _ operation: Operation,
    manifest: WritingProjectManifest
  ) throws {
    let allowed = Self.allowedStages[operation] ?? []
    guard allowed.contains(manifest.stage) else {
      throw WritingError.invalidStage(
        expected: allowed.map(\.displayName).joined(separator: "、"),
        actual: manifest.stage
      )
    }
  }

  private func requireLineage(
    _ chapterID: String,
    manifest: WritingProjectManifest
  ) throws {
    let expected = manifest.currentChapterID ?? ""
    guard chapterID == expected else {
      throw WritingError.chapterLineageMismatch(expected: expected, actual: chapterID)
    }
  }

  private func createProposal(
    id: UUID,
    kind: WritingProposalKind,
    chapterID: String? = nil,
    ordinal: Int? = nil,
    chapterTitle: String? = nil,
    content: String
  ) throws -> WritingProposal {
    let url = proposalURL(id)
    if fileManager.fileExists(atPath: url.path) {
      let existing = try read(WritingProposal.self, from: url)
      guard existing.kind == kind, existing.content == content,
        existing.chapterID == chapterID
      else { throw WritingError.proposalAlreadyDecided(id) }
      return existing
    }
    let proposal = WritingProposal(
      id: id,
      kind: kind,
      chapterID: chapterID,
      ordinal: ordinal,
      chapterTitle: chapterTitle,
      content: content,
      inputHash: sha256("\(kind.rawValue)|\(chapterID ?? "")|\(content)")
    )
    try write(proposal, to: url)
    return proposal
  }

  private func pendingProposal(
    id: UUID,
    kind: WritingProposalKind?
  ) throws -> WritingProposal {
    let url = proposalURL(id)
    guard fileManager.fileExists(atPath: url.path) else {
      throw WritingError.proposalNotFound(id)
    }
    let proposal = try read(WritingProposal.self, from: url)
    if let kind, proposal.kind != kind { throw WritingError.wrongProposalKind }
    guard proposal.status == .pending else { throw WritingError.proposalAlreadyDecided(id) }
    return proposal
  }

  private func finish(
    _ proposal: inout WritingProposal,
    action: ApprovalAction,
    note: String? = nil
  ) throws {
    let event = ApprovalEvent(
      id: proposal.id,
      proposalID: proposal.id,
      action: action,
      note: note
    )
    try appendEventIfMissing(event)
    proposal.status = action == .approve ? .approved : .rejected
    proposal.decidedAt = Date()
    try write(proposal, to: proposalURL(proposal.id))
  }

  private func appendEventIfMissing(_ event: ApprovalEvent) throws {
    let url = packageURL.appendingPathComponent("events.jsonl")
    let existing = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let hasEvent = existing.split(whereSeparator: { $0.isNewline }).contains { line in
      (try? WritingCoding.decoder.decode(ApprovalEvent.self, from: Data(line.utf8)).id)
        == event.id
    }
    guard !hasEvent else { return }
    var data = try WritingCoding.lineEncoder.encode(event)
    data.append(0x0A)
    if !fileManager.fileExists(atPath: url.path) {
      try Data().write(to: url, options: [.atomic])
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }

  private func makeChapterRevision(
    proposal: WritingProposal,
    kind: ChapterRevisionKind
  ) throws -> ChapterRevision {
    guard let chapterID = proposal.chapterID,
      let ordinal = proposal.ordinal,
      let title = proposal.chapterTitle
    else { throw WritingError.wrongProposalKind }
    return ChapterRevision(
      id: proposal.id,
      chapterID: chapterID,
      ordinal: ordinal,
      title: title,
      kind: kind,
      content: proposal.content,
      proposalID: proposal.id,
      createdAt: proposal.createdAt
    )
  }

  private func writeChapterRevision(_ revision: ChapterRevision) throws {
    let directory = chapterDirectory(revision.chapterID).appendingPathComponent(
      "revisions", isDirectory: true
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try write(
      revision,
      to: directory.appendingPathComponent(revision.id.uuidString.lowercased() + ".json")
    )
  }

  private func finalChapters() throws -> [PublicationChapter] {
    let chaptersURL = packageURL.appendingPathComponent("chapters", isDirectory: true)
    guard fileManager.fileExists(atPath: chaptersURL.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: chaptersURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).compactMap { directory in
      let finalURL = directory.appendingPathComponent("final.md")
      guard fileManager.fileExists(atPath: finalURL.path) else { return nil }
      let revisions = try listJSON(
        ChapterRevision.self,
        at: directory.appendingPathComponent("revisions", isDirectory: true)
      )
      guard let final = revisions.filter({ $0.kind == .final })
        .sorted(by: { $0.createdAt > $1.createdAt }).first
      else { return nil }
      return PublicationChapter(
        chapterID: final.chapterID,
        ordinal: final.ordinal,
        title: final.title,
        content: try String(contentsOf: finalURL, encoding: .utf8)
      )
    }.sorted { $0.ordinal < $1.ordinal }
  }

  private func updateManifest(
    stage: WritingStage,
    activeOutlineRevisionID: UUID? = nil,
    currentChapterID: String? = nil
  ) throws {
    var manifest = try loadManifest()
    manifest.stage = stage
    if let activeOutlineRevisionID { manifest.activeOutlineRevisionID = activeOutlineRevisionID }
    if let currentChapterID { manifest.currentChapterID = currentChapterID }
    manifest.modifiedAt = Date()
    try write(manifest, to: packageURL.appendingPathComponent("manifest.json"))
  }

  private func loadManifest() throws -> WritingProjectManifest {
    let url = packageURL.appendingPathComponent("manifest.json")
    guard fileManager.fileExists(atPath: url.path) else { throw WritingError.invalidPackage }
    return try read(WritingProjectManifest.self, from: url)
  }

  private func proposalURL(_ id: UUID) -> URL {
    packageURL.appendingPathComponent("proposals/\(id.uuidString.lowercased()).json")
  }

  private func chapterDirectory(_ id: String) -> URL {
    packageURL.appendingPathComponent("chapters/\(id)", isDirectory: true)
  }

  private func validateChapterID(_ value: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
    guard !value.isEmpty, value.rangeOfCharacter(from: allowed) == nil else {
      throw WritingError.unsafeChapterID
    }
  }

  private func readText(_ path: String) throws -> String {
    try String(contentsOf: packageURL.appendingPathComponent(path), encoding: .utf8)
  }

  private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try WritingCoding.decoder.decode(T.self, from: Data(contentsOf: url))
  }

  private func listJSON<T: Decodable>(_ type: T.Type, in path: String) throws -> [T] {
    try listJSON(type, at: packageURL.appendingPathComponent(path, isDirectory: true))
  }

  private func listJSON<T: Decodable>(_ type: T.Type, at directory: URL) throws -> [T] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "json" }.map {
      try read(type, from: $0)
    }
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try WritingCoding.encoder.encode(value).write(to: url, options: [.atomic])
  }

  private func writeText(_ value: String, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(value.utf8).write(to: url, options: [.atomic])
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try write(value, to: url)
  }

  private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

enum WritingCoding {
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  static var lineEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
