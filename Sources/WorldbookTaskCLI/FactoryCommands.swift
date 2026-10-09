import Foundation
import DirectoryJournalCore
import LibraryCore
import LLMProviderKit
import StoryworldCore
import StoryworldFactory

struct CLIFactoryStatus: Encodable {
  let job: FactoryJob
  let decisions: [FactoryDecision]
  let preview: FactoryDiffPreview?
  let analysisPending: FactoryRequestRetryApproval
  let bakePending: FactoryRequestRetryApproval
}
struct CLIFactoryAnswer: Codable {
  let reviewed: FactoryDecision
  let answer: String?
  enum CodingKeys: String, CodingKey { case reviewed, answer }
  init(reviewed: FactoryDecision, answer: String?) { self.reviewed = reviewed; self.answer = answer }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.answer) else { throw CLIError.invalid("answer（接受推荐时请明确写 null）") }
    reviewed = try container.decode(FactoryDecision.self, forKey: .reviewed)
    answer = try container.decodeIfPresent(String.self, forKey: .answer)
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(reviewed, forKey: .reviewed)
    try container.encode(answer, forKey: .answer)
  }
}
struct CLIFactoryTaste: Codable {
  let expected: FactoryTasteConfiguration?
  let overrides: PlayerTasteOverrides
}

extension CLIContext {
  func executeFactory() async throws -> CLIResult {
    switch args.command {
    case "list": return try json(await factory.list())
    case "create":
      let record = try await library.importDocument(from: URL(fileURLWithPath: args.required("source")))
      return try json(await factory.create(document: record.document))
    case "recover": return try json(await factory.recoverInterruptedJobs())
    default: break
    }
    let id = try args.uuid("job")
    if args.command == "status" { return try await factoryStatus(id) }
    if args.command == "pending" {
      guard let kind = FactoryRequestKind(rawValue: try args.required("kind")) else { throw CLIError.invalid("--kind") }
      return try json(await factory.pendingRequestRetry(id, kind: kind))
    }
    let needsProvider = ["analyze", "resume", "generate"].contains(args.command)
    let worker: any FactoryAnalysisWorker
    if needsProvider {
      let provider = try await provider()
      worker = DirectLLMFactoryWorker(provider: provider, concurrency: provider.profile.effectiveFactoryConcurrency)
    } else { worker = UnavailableFactoryAnalysisWorker() }
    let coordinator = FactoryCoordinator(library: library, storyworldLibrary: worlds, store: factory,
      worker: worker, tasteStore: taste, commandLineTaste: try commandLineTaste())
    switch args.command {
    case "answer":
      let value = try read(CLIFactoryAnswer.self)
      guard value.reviewed.jobID == id else { throw CLIError.staleReview }
      try await coordinator.answerReviewedDecision(value.reviewed, answer: value.answer)
    case "taste":
      let settings = try await coordinator.tasteSettings(jobID: id)
      if args["file"] != nil {
        let value = try read(CLIFactoryTaste.self)
        guard settings.configuration == value.expected else { throw CLIError.staleReview }
        try await coordinator.updateTasteSettings(settings, overrides: value.overrides)
      }
      let current = try await coordinator.tasteSettings(jobID: id)
      return try json(CLIFactoryTaste(expected: current.configuration, overrides: current.overrides))
    case "publish":
      let record = try await coordinator.publish(jobID: id)
      return try json(["storyworld_id": record.id.uuidString.lowercased()])
    case "analyze", "resume", "generate":
      // Scoped recovery skips live leases and never changes another task.
      _ = try await factory.recoverInterruptedJobs(jobID: id)
      let job = try await factory.load(id)
      let approval = try args["approval"].map { _ in try read(FactoryRequestRetryApproval.self, option: "approval") }
      if let approval, approval.jobID != id { throw CLIError.staleReview }
      guard !job.stage.isRunning else { throw DirectoryProcessLockError.busy }
      if args.command == "generate" { try await coordinator.generateCandidate(jobID: id, requestApproval: approval) }
      else if job.stage == .failed || job.stage == .cancelled { try await coordinator.retry(jobID: id, requestApproval: approval) }
      else if job.stage == .queued {
        // A queued task cannot silently consume an approval that names old requests.
        guard approval == nil else { throw CLIError.invalid("当前阶段不接受 --approval，请先检查任务状态") }
        try await coordinator.startAnalysis(jobID: id)
      } else if args.command == "analyze" {
        try await coordinator.supplementAnalysis(jobID: id, requestApproval: approval)
      } else if approval != nil { throw CLIError.invalid("此阶段没有可由 resume 重发的请求") }
    default: throw CLIError.usage
    }
    let job = try await factory.load(id)
    return try await factoryStatus(id, code: job.stage == .waitingForUser ? 4 : 0)
  }

  private func factoryStatus(_ id: UUID, code: Int32 = 0) async throws -> CLIResult {
    try json(CLIFactoryStatus(job: await factory.load(id), decisions: await factory.decisions(id),
      preview: await factory.preview(id), analysisPending: await factory.pendingRequestRetry(id, kind: .analysis),
      bakePending: await factory.pendingRequestRetry(id, kind: .bake)), code: code)
  }
}
