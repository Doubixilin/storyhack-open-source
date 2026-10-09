import Foundation
import LLMProviderKit
import StoryworldCore

/// Bounded, resumable decision editing. Each completed block is immutable for
/// its full input fingerprint; unknown requests never cause an automatic resend.
struct FactoryBakePass: Sendable {
  let transport: any FactoryBatchTransport
  let budget: FactoryBakeBudget
  let executor: String

  func run(jobID: UUID, sourceContentHash: String, sourceFingerprint: String,
    proposals: [FactoryLoreProposal], decisions: [FactoryDecision], workspaceURL: URL,
    allowRequests: Bool, playerTaste: PlayerTasteProfile = .standard,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport {
    let playerTaste = try playerTaste.validated()
    let plan = try FactoryBakePlanner.plan(sourceContentHash: sourceContentHash, executor: executor,
      proposals: proposals, decisions: decisions, budget: budget, playerTaste: playerTaste)
    let directory = workspaceURL.appendingPathComponent("bake/batches")
    try safeDirectory(directory, root: workspaceURL)
    if allowRequests, FileManager.default.fileExists(atPath: directory.path) {
      let expected = try Set(plan.blocks.map { try $0.fingerprint() + ".inflight.json" })
      let pending = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        .filter { $0.lastPathComponent.hasSuffix(".inflight.json") }
      for file in pending {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw FactoryRequestRetryError.invalidCheckpoint
        }
      }
      guard pending.allSatisfy({ expected.contains($0.lastPathComponent) }) else {
        throw FactoryRequestRetryError.confirmationRequired(pending.count)
      }
    }
    if allowRequests { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    var rewrites: [FactoryBakeRewrite] = []
    var warnings = plan.warnings
    var stopRequests = false
    var requestedEntryCount = 0
    for (index, block) in plan.blocks.enumerated() {
      try Task.checkCancellation()
      try safeDirectory(directory, root: workspaceURL)
      let fingerprint = try block.fingerprint()
      let cacheURL = directory.appendingPathComponent(fingerprint + ".json")
      let checkpointURL = directory.appendingPathComponent(fingerprint + ".inflight.json")
      if let cache: Cache = try read(cacheURL, maximumBytes: 2_097_152), cache.fingerprint == fingerprint,
        (try? validate(cache.rewrites, block: block)) != nil {
        rewrites += cache.rewrites
      } else if allowRequests && !stopRequests && requestedEntryCount + block.proposals.count <= 80 {
        requestedEntryCount += block.proposals.count
        var completed: [FactoryBakeRewrite]?
        for attempt in 1...2 {
          try Task.checkCancellation()
          let edits: [FactoryBakeRewrite]
          var receivedResponse = false
          do {
            let raw: String
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
              guard let checkpoint: Checkpoint = try read(checkpointURL, maximumBytes: 65_536),
                checkpoint.fingerprint == fingerprint,
                let recovered = try await transport.recoverInflight(checkpointToken: checkpoint.requestID) else {
                throw FactoryWorkerError.uncertainPriorRequest(index + 1)
              }
              raw = recovered
            } else {
              let id = try await transport.beginRequest(title: "决策定向改写 \(index + 1)/\(plan.blocks.count)")
              try write(Checkpoint(fingerprint: fingerprint, requestID: id), to: checkpointURL, root: workspaceURL)
              let retry = attempt == 2 ? "\n上次未完整满足结构约定；请完整返回本块所有条目，不得遗漏、增加或重复编号。" : ""
              let prompt = try block.prompt() + retry
              guard LLMTokenEstimate.tokens(block.system + prompt) + 64 <= budget.input else {
                // No request was sent; this is a local budget rejection.
                try FileManager.default.removeItem(at: checkpointURL)
                throw FactoryBakeError.oversizedInput
              }
              raw = try await transport.send(checkpointToken: id, systemPrompt: block.system,
                prompt: prompt, maximumOutputTokens: budget.output)
            }
            receivedResponse = true
            edits = try decode(raw, block: block)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            let knownInvalid = receivedResponse || FactoryAnalysisPipeline.isSafeToRetry(error)
              || (error as? LLMToolError) == .outputTruncated
            let rejected = (error as? FactoryWorkerError) == .authentication
            if knownInvalid || rejected || error is FactoryBakeError {
              if FileManager.default.fileExists(atPath: checkpointURL.path) {
                try FileManager.default.removeItem(at: checkpointURL)
              }
            }
            if knownInvalid && attempt == 1 { continue }
            warnings.append("第 \(index + 1) 块未完成，\(block.proposals.count) 条保留原候选（\(safeReason(error))）。")
            stopRequests = !knownInvalid && !(error is FactoryBakeError)
            break
          }
          // Keep the checkpoint if persisting the paid response fails. Storage
          // failures must not be mistaken for a reason to pay for a retry.
          try write(Cache(fingerprint: fingerprint, rewrites: edits), to: cacheURL, root: workspaceURL)
          if FileManager.default.fileExists(atPath: checkpointURL.path) {
            try FileManager.default.removeItem(at: checkpointURL)
          }
          completed = edits
          break
        }
        rewrites += completed ?? []
      } else {
        warnings.append("第 \(index + 1) 块尚无可复用结果，保留原候选；每次最多新处理 80 条，可继续生成并复用已完成块。")
      }
      await progress(.init(fraction: Double(index + 1) / Double(max(1, plan.blocks.count)), executorVersion: executor))
    }
    let report = FactoryBakeReport.make(sourceFingerprint: sourceFingerprint, executor: executor,
      targets: plan.targets, rewrites: rewrites, decisions: decisions, warnings: warnings)
    try report.validate(sourceFingerprint: sourceFingerprint, proposals: proposals, decisions: decisions,
      playerTaste: playerTaste)
    return report
  }

  private struct Cache: Codable { let fingerprint: String; let rewrites: [FactoryBakeRewrite] }
  private struct Checkpoint: Codable { let fingerprint: String; let requestID: String }
  private struct Output: Decodable {
    struct Entry: Decodable { let id: String; let content: String; let decision_ids: [UUID] }
    let entries: [Entry]
  }

  private func decode(_ raw: String, block: FactoryBakeBlock) throws -> [FactoryBakeRewrite] {
    guard raw.utf8.count <= 1_048_576,
      let output = try? JSONDecoder().decode(Output.self, from: Data(raw.utf8)) else {
      throw FactoryBakeError.invalidOutput
    }
    let edits = output.entries.map {
      FactoryBakeRewrite(proposalID: $0.id, content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines),
        decisionIDs: $0.decision_ids.sorted { $0.uuidString < $1.uuidString })
    }
    try validate(edits, block: block)
    return edits.sorted { $0.proposalID < $1.proposalID }
  }

  private func validate(_ edits: [FactoryBakeRewrite], block: FactoryBakeBlock) throws {
    guard edits.count == block.targets.count,
      Set(edits.map(\.proposalID)) == Set(block.targets.map(\.proposalID)) else { throw FactoryBakeError.invalidOutput }
    for edit in edits {
      guard !edit.content.isEmpty, edit.content.count <= FactoryBakePlanner.maximumContentCharacters,
        edit.decisionIDs == block.targets.first(where: { $0.proposalID == edit.proposalID })?.decisionIDs else {
        throw FactoryBakeError.invalidOutput
      }
    }
  }

  private func safeReason(_ error: Error) -> String {
    if (error as? FactoryWorkerError) == .authentication { return "模型认证失败，已停止后续请求" }
    if error is FactoryBakeError { return error.localizedDescription }
    if FactoryAnalysisPipeline.isSafeToRetry(error) { return "已完成回复不可用或服务拒绝，有限重试已结束" }
    return "请求结果无法确认，未自动重发"
  }

  private func safeDirectory(_ url: URL, root: URL) throws {
    guard url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(
      with: root.resolvingSymlinksInPath().standardizedFileURL.pathComponents) else {
      throw FactoryRequestRetryError.invalidCheckpoint
    }
  }

  private func read<T: Decodable>(_ url: URL, maximumBytes: Int) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? Int.max) <= maximumBytes else { throw FactoryRequestRetryError.invalidCheckpoint }
    return try? StoryworldCoding.makeDecoder().decode(T.self, from: Data(contentsOf: url))
  }

  private func write<T: Encodable>(_ value: T, to url: URL, root: URL) throws {
    try safeDirectory(url, root: root)
    if FileManager.default.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw FactoryRequestRetryError.invalidCheckpoint
      }
    }
    try StoryworldCoding.makeEncoder().encode(value).write(to: url, options: .atomic)
  }
}
