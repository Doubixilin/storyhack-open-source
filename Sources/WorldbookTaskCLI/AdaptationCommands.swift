import Foundation
import LibraryCore
import NovelDocumentCore
import StoryworldCore
import WritingCore
import WritingAssistantCore

struct CLIAdaptationStatus: Encodable {
  let job: AdaptationJob
  let configuration: AdaptationRunConfiguration
  let pending: AdaptationRequestCheckpoint?
}
struct CLIDraftRow: Encodable {
  let draft: AdaptationDraft
  let decision: AdaptationDraftDecision?
  let isStale: Bool
}
struct CLIDrafts: Encodable {
  let revision: UUID?
  let current: [CLIDraftRow]
  init(_ value: AdaptationDraftSnapshot) {
    revision = value.revision
    current = value.current.map { .init(draft: $0.draft, decision: $0.decision, isStale: $0.isStale) }
  }
}
struct CLIAnchorRow: Encodable {
  let id: String
  let anchor: AdaptationAnchor
  let review: AdaptationAnchorReview?
}
struct CLIAnchors: Encodable {
  let revision: UUID?
  let anchors: [CLIAnchorRow]
  init(_ map: AdaptationAnchorMap) {
    revision = map.revision
    anchors = map.anchors.map { .init(id: $0.id, anchor: $0, review: map.reviews[$0.id]) }
  }
}
struct CLIReports: Encodable {
  let bookcase: BookcaseExtractionReport?
  let anchors: AnchorScanReport?
  let writing: AdaptationWriteReport?
}
struct CLIBookcaseEdit: Codable {
  let jobID: UUID
  let revision: UUID
  let parentID: UUID
  let content: NovelBookcase
}
struct CLIReview: Codable {
  enum Kind: String, Codable { case bookcase, anchor, draft }
  let kind: Kind
  let jobID: UUID
  let revision: UUID?
  let action: ApprovalAction
  let proposalID: UUID?
  let variantID: UUID?
  let draftID: UUID?
  let anchorID: String?
  let generationAction: AdaptationAnchorAction?
  let intensity: Int?
  let note: String?
  let acknowledge: Bool?
}

extension CLIContext {
  func executeAdaptation() async throws -> CLIResult {
    switch args.command {
    case "list": return try json(await adaptation.list())
    case "import": return try json(await adaptation.create(from: URL(fileURLWithPath: args.required("source"))))
    case "template":
      switch try args.required("kind") {
      case "contract": return try json(AdaptationDirectionContract())
      case "config": return try json(AdaptationRunConfiguration())
      case "taste": return try json(PlayerTasteOverrides())
      default: throw CLIError.invalid("--kind")
      }
    case "original":
      let title = try args.required("title")
      guard let plan = String(data: try fileBytes(option: "source", maximum: 1_048_576), encoding: .utf8) else { throw CLIError.invalid("--source") }
      let lines = plan.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      guard !lines.isEmpty, lines.count <= 1000 else { throw CLIError.invalid("--source") }
      let chapters = lines.enumerated().map { index, line in
        let parts = line.components(separatedBy: "｜")
        return NovelChapter(id: String(format: "chapter-%06d", index + 1), ordinal: index,
          title: parts[0], content: parts.dropFirst().joined(separator: "｜"))
      }
      let job = try await adaptation.createOriginal(title: title, author: args["author"], chapters: chapters)
      var contract = AdaptationDirectionContract(); contract.mode = .original
      contract.includeOriginalChapter = false; contract.originalRetentionPercent = 0
      _ = try await adaptation.createStandaloneVariant(jobID: job.id, title: title, contract: contract, expectedRevision: job.revision)
      return try json(await adaptation.load(job.id))
    default: break
    }
    let id = try args.uuid("job")
    switch args.command {
    case "status": return try json(CLIAdaptationStatus(job: await adaptation.load(id),
      configuration: await adaptation.runConfiguration(id), pending: await adaptation.pendingRequest(id)))
    case "source": return try json(await adaptation.source(id))
    case "config":
      if args["file"] != nil {
        let value = try read(AdaptationRunConfiguration.self)
        return try json(await adaptation.saveRunConfiguration(value, jobID: id, expectedRevision: value.revision))
      }
      return try json(await adaptation.runConfiguration(id))
    case "bookcases": return try json(await adaptation.bookcases(id))
    case "edit-bookcase":
      let edit = try read(CLIBookcaseEdit.self)
      guard edit.jobID == id else { throw CLIError.staleReview }
      let proposals = try await adaptation.bookcases(id)
      guard let parent = proposals.first(where: { $0.id == edit.parentID }) else { throw CLIError.staleReview }
      let changed = edit.content.characters.filter { card in parent.content.characters.first(where: { $0.id == card.id }) != card }
      let content = try edit.content.applyingManualCharacters(changed)
      return try json(await adaptation.proposeBookcase(content, jobID: id, expectedRevision: edit.revision,
        parentID: edit.parentID, authorRevision: true))
    case "anchors": return try json(CLIAnchors(await adaptation.anchorMap(id)))
    case "add-anchor": return try json(await adaptation.addManualAnchor(jobID: id, expectedRevision: args.revision(),
      candidate: read(AdaptationAnchorCandidate.self)))
    case "review": return try await review(id)
    case "contract": return try await contract(id)
    case "extract", "scan", "write": return try await generate(id)
    case "drafts":
      let variant = try args.uuid("variant")
      if args["draft"] != nil { return try json(await adaptation.draft(jobID: id, variantID: variant, draftID: args.uuid("draft"))) }
      return try json(CLIDrafts(await adaptation.drafts(jobID: id, variantID: variant)))
    case "edit-draft": return try json(await adaptation.reviseDraft(jobID: id, variantID: args.uuid("variant"),
      draftID: args.uuid("draft"), content: read(AdaptationDraftContent.self)))
    case "assemble":
      let variant = try args.uuid("variant"), snapshot = try await adaptation.drafts(jobID: id, variantID: variant)
      return try json(await adaptation.prepareAssembly(jobID: id, variantID: variant, expectedDraftRevision: snapshot.revision))
    case "export", "publish":
      let value = try read(AdaptationAssembly.self, maximum: 100 * 1_048_576)
      guard value.jobID == id else { throw CLIError.staleReview }
      if args.command == "publish" {
        let record = try await library.publishAdaptation(value, store: adaptation, acknowledgeUnchangedChapters: args["ack-unchanged"] != nil)
        return try json(["book_id": record.id.uuidString.lowercased()])
      }
      let output = try await adaptation.exportAssembly(value, acknowledgeUnchangedChapters: args["ack-unchanged"] != nil)
      return try json(["epub": output.epubURL.path, "text": output.textURL.path,
        "comparison": output.comparisonURL.path, "assembly": output.epubURL.deletingLastPathComponent().appendingPathComponent("assembly.json").path])
    case "pending": return try json(await adaptation.pendingRequest(id))
    case "acknowledge":
      guard args["allow-resend"] != nil else { throw CLIError.missing("--allow-resend") }
      let pending = try read(AdaptationRequestCheckpoint.self)
      guard pending.jobID == id else { throw CLIError.staleReview }
      try await adaptation.acknowledgeUnknownRequest(pending, note: "作者通过 CLI --allow-resend 确认此请求；已知可能重复计费。")
      return try json(["acknowledged": pending.id.uuidString.lowercased()])
    case "report":
      let writing: AdaptationWriteReport?
      if args["variant"] != nil { writing = try await adaptation.writeReport(jobID: id, variantID: args.uuid("variant")) } else { writing = nil }
      return try json(CLIReports(bookcase: await adaptation.bookcaseExtractionReport(id),
        anchors: await adaptation.anchorScanReport(id), writing: writing))
    default: throw CLIError.usage
    }
  }

  private func review(_ id: UUID) async throws -> CLIResult {
    let value = try read(CLIReview.self)
    guard value.jobID == id else { throw CLIError.staleReview }
    switch value.kind {
    case .bookcase:
      guard let proposal = value.proposalID, let revision = value.revision else { throw CLIError.invalid("审阅 proposalID/revision") }
      return try json(await adaptation.decideBookcase(jobID: id, proposalID: proposal, expectedRevision: revision,
        action: value.action, note: value.note, acknowledgeMissingChapters: value.acknowledge == true))
    case .anchor:
      guard let anchor = value.anchorID, let action = value.generationAction else { throw CLIError.invalid("审阅 anchorID/generationAction") }
      return try json(await adaptation.reviewAnchor(jobID: id, anchorID: anchor, expectedRevision: value.revision,
        action: value.action, generationAction: action, intensity: value.intensity ?? 3, note: value.note ?? ""))
    case .draft:
      guard let variant = value.variantID, let draft = value.draftID else { throw CLIError.invalid("审阅 variantID/draftID") }
      return try json(await adaptation.decideDraft(jobID: id, variantID: variant, draftID: draft, expectedRevision: value.revision,
        action: value.action, note: value.note ?? "", acknowledgeWarnings: value.acknowledge == true))
    }
  }

  private func contract(_ id: UUID) async throws -> CLIResult {
    if args["file"] == nil {
      let variantID = try args.uuid("variant"), job = try await adaptation.load(id)
      guard let variant = job.variants.first(where: { $0.id == variantID }) else { throw CLIError.staleReview }
      return try json(await adaptation.direction(jobID: id, revisionID: variant.contractRevisionID))
    }
    let content = try read(AdaptationDirectionContract.self), revision = try args.uuid("revision")
    if args["variant"] != nil {
      guard args["standalone"] == nil, args["title"] == nil else { throw CLIError.usage }
      return try json(await adaptation.updateDirection(jobID: id, variantID: args.uuid("variant"),
        expectedContractRevisionID: revision, contract: content,
        bookcaseID: args["bookcase"].map { _ in try args.uuid("bookcase") }))
    }
    guard args["bookcase"] == nil else { throw CLIError.usage }
    if args["standalone"] != nil {
      return try json(await adaptation.createStandaloneVariant(jobID: id, title: args.required("title"), contract: content, expectedRevision: revision))
    }
    return try json(await adaptation.createVariant(jobID: id, title: args.required("title"), contract: content, expectedRevision: revision))
  }

  private func generate(_ id: UUID) async throws -> CLIResult {
    var config = try await adaptation.runConfiguration(id)
    let maximum = try args.integer("max-requests", default: config.maximumNewRequests, range: 0...100)
    let provider = try await provider(defaultID: config.providerID, needsCredential: maximum > 0)
    let variant = args.command == "write" ? try args.uuid("variant") : nil
    let cliTaste = try commandLineTaste()
    let selection = BookcaseExtractionOptions(chapterIDs: config.chapterIDs, focusNames: config.focusNames,
      maximumUnitUTF16Length: config.maximumUnitUTF16Length, maximumNewRequests: maximum)
    if args.command == "extract" {
      let report = try await BookcaseExtractor(provider: provider, store: adaptation).extract(jobID: id, options: selection)
      return try json(report, code: report.stage == .completed ? 0 : 3)
    }
    if args.command == "scan" {
      let report = try await AdaptationAnchorScanner(provider: provider, store: adaptation).scan(jobID: id,
        options: .init(selection: selection, density: config.density, addChapterStarts: config.addChapterStarts))
      return try json(report, code: report.stage == .completed ? 0 : 3)
    }
    guard let variant else { throw CLIError.missing("--variant") }
    guard try await adaptation.load(id).variants.contains(where: { $0.id == variant }) else { throw CLIError.invalid("--variant") }
    let source = try await adaptation.source(id)
    let targets: [AdaptationDraftTarget]
    if config.writeScope == .anchors {
      let map = try await adaptation.anchorMap(id)
      targets = map.anchors.filter { map.reviews[$0.id]?.action == .approve && (config.chapterIDs.isEmpty || config.chapterIDs.contains($0.source.chapterID)) }
        .map { .init(chapterID: $0.source.chapterID, anchorID: $0.id) }
      guard !targets.isEmpty else { throw CLIError.invalid("没有已批准的目标锚点") }
    } else {
      targets = source.chapters.filter { config.chapterIDs.isEmpty || config.chapterIDs.contains($0.id) }.map { .init(chapterID: $0.id) }
    }
    let personalTaste = try await taste.load().profile
    if args["regenerate"] != nil {
      config = try await adaptation.beginRegeneration(jobID: id, expectedConfigurationRevision: config.revision)
    }
    let report = try await AdaptationWriter(provider: provider, store: adaptation).write(jobID: id, variantID: variant,
      options: .init(targets: targets, maximumNewRequests: maximum, focusNames: config.focusNames, personalTaste: personalTaste,
        commandLineTaste: cliTaste, taskTaste: config.taskTaste, regenerationID: config.regenerationID))
    return try json(report, code: report.stage == .completed ? 0 : 3)
  }
}
