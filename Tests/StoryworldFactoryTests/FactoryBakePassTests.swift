import Foundation
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import Testing
@testable import StoryworldFactory

@Suite("Factory bounded decision editing")
struct FactoryBakePassTests {
  @Test func preferenceOnlyBlocksKeepFailedOriginalsAndResumeCompletedBlocks() async throws {
    let base = try await fixture(count: 2)
    defer { base.clean() }
    let f = base.replacing(decisions: [], fingerprint: "style-only")
    let transport = BakeTransport(failedID: "entry-000")
    let taste = PlayerTasteProfile(style: .concise, avoidElements: ["虫群"])
    let first = try await run(f, transport: transport, output: 4_096, playerTaste: taste)
    #expect(first.unresolvedDecisionIDs.isEmpty && !first.isComplete)
    #expect(first.rewrites.count == 1 && first.retainedCount == 1)
    #expect(first.applying(to: f.input.proposals)[0] == f.input.proposals[0])
    #expect(first.fallbackEntries(decisions: [], proposals: f.input.proposals).isEmpty)
    #expect(await transport.calls.count == 3)
    await transport.setFailedID(nil)
    let second = try await run(f, transport: transport, output: 4_096, playerTaste: taste)
    #expect(second.isComplete && second.rewrites.count == 2)
    #expect(await transport.calls.count == 4)
    _ = try await run(f, transport: transport, output: 4_096,
      playerTaste: .init(style: .concise, avoidElements: [" 虫群 ", "虫群"]))
    #expect(await transport.calls.count == 4)
  }

  @Test func preferenceChangeCannotBypassAnUncertainEarlierRequest() async throws {
    let f = try await fixture(count: 1)
    defer { f.clean() }
    let transport = BakeTransport(unknown: true)
    _ = try await run(f, transport: transport)
    let pending = try await f.store.pendingRequestRetry(f.input.jobID, kind: .bake)
    #expect(pending.requestCount == 1)
    await #expect(throws: FactoryRequestRetryError.self) {
      try await run(f, transport: transport, playerTaste: .init(style: .concise))
    }
    #expect(await transport.calls.count == 1)
    #expect(try await f.store.pendingRequestRetry(f.input.jobID, kind: .bake) == pending)
  }

  @Test func fullPreferencesCountAgainstInputBudgetWithoutTruncationOrExtraRequests() async throws {
    let f = try await fixture(count: 1)
    defer { f.clean() }
    let transport = BakeTransport()
    let original = try await run(f, transport: transport, output: 4_096, window: 8_192)
    #expect(original.isComplete && original.rewrites.count == 1)
    let taste = PlayerTasteProfile(avoidElements: (1...20).map { String(repeating: "避", count: 78) + String($0) },
      notes: String(repeating: "字", count: 1_000))
    let limited = try await run(f, transport: transport, output: 4_096, window: 8_192, playerTaste: taste)
    #expect(limited.rewrites.isEmpty && limited.retainedCount == 1 && !limited.isComplete)
    #expect(limited.warnings.contains { $0.contains("超过预算") })
    #expect(await transport.calls.count == 1)
    #expect(try await f.store.pendingRequestRetry(f.input.jobID).requestCount == 0)
  }

  @Test func confirmedDecisionTargetsTakePriorityOverPreferenceOnlyTargets() throws {
    let proposals = (0..<81).map { index in
      FactoryLoreProposal(id: String(format: "entry-%03d", index), kind: .character,
        title: index == 80 ? "目标主角" : "人物\(index)", content: "原候选")
    }
    let decisions = [FactoryDecision(jobID: UUID(), question: "目标主角如何行动？", recommendation: "留守",
      evidence: [], resolution: .acceptedRecommendation, answer: "留守")]
    let plan = try FactoryBakePlanner.plan(sourceContentHash: "synthetic", executor: "test",
      proposals: proposals, decisions: decisions, budget: FactoryBakeBudget(profile: profile()),
      playerTaste: .init(style: .concise))
    #expect(plan.blocks.first?.proposals.first?.id == "entry-080")
    #expect(plan.blocks.flatMap(\.proposals).count == 81 && plan.targets.count == 81)
  }
  @Test func blocksRespectSixteenEntriesAndKeepOtherBlocksWhenOneFailsTwice() async throws {
    let f = try await fixture(count: 33, globalDecision: true)
    defer { f.clean() }
    let transport = BakeTransport(failedID: "entry-016")
    let report = try await run(f, transport: transport)
    #expect(await transport.calls.count == 4)
    #expect(await transport.calls.map(\.ids.count) == [16, 16, 16, 1])
    #expect(report.rewrites.count == 17 && report.retainedCount == 16)
    #expect(report.unresolvedDecisionIDs == f.input.decisions.map(\.id))
    #expect(report.applying(to: f.input.proposals)[16].content == f.input.proposals[16].content)
    #expect(report.applying(to: f.input.proposals)[0].content == "按人工决策编辑：人物0")
    #expect(report.fallbackEntries(decisions: f.input.decisions, proposals: f.input.proposals).allSatisfy { !$0.alwaysActive })
    await transport.setFailedID(nil)
    let complete = try await run(f, transport: transport)
    #expect(await transport.calls.count == 5)
    #expect(complete.rewrites.count == 33 && complete.isComplete)
    _ = try await run(f, transport: transport)
    #expect(await transport.calls.count == 5)
  }

  @Test func onlyChangedDecisionInvalidatesItsBlockAndOtherMetadataStaysIntact() async throws {
    let f = try await fixture(count: 2)
    defer { f.clean() }
    let transport = BakeTransport()
    let first = try await run(f, transport: transport, output: 4_096)
    #expect(await transport.calls.count == 2)
    var decisions = f.input.decisions
    decisions[0].answer = "改为留守"
    let changed = f.replacing(decisions: decisions, fingerprint: "changed-input")
    let second = try await run(changed, transport: transport, output: 4_096)
    #expect(await transport.calls.count == 3)
    #expect(second.sourceFingerprint == "changed-input")
    let applied = second.applying(to: f.input.proposals)
    for (before, after) in zip(f.input.proposals, applied) {
      #expect(before.id == after.id && before.title == after.title && before.kind == after.kind)
      #expect(before.evidence == after.evidence && before.activationKeys == after.activationKeys)
      #expect(before.alwaysActive == after.alwaysActive && before.archetype == after.archetype)
    }
    #expect(try first.fingerprint() != second.fingerprint())
    _ = try await run(changed, transport: transport, output: 4_096, executor: "other-model")
    #expect(await transport.calls.count == 5)
  }

  @Test func unknownRequestWaitsForExactBakeApprovalAndDoesNotAuthorizeAnalysis() async throws {
    let f = try await fixture(count: 1)
    defer { f.clean() }
    let transport = BakeTransport(unknown: true)
    let report = try await run(f, transport: transport)
    #expect(!report.isComplete && report.rewrites.isEmpty)
    let approval = try await f.store.pendingRequestRetry(f.input.jobID, kind: .bake)
    #expect(approval.requestCount == 1)
    #expect(try await f.store.pendingRequestRetry(f.input.jobID, kind: .analysis).requestCount == 0)
    _ = try await run(f, transport: transport)
    #expect(await transport.calls.count == 1)
    try await f.store.authorizeRequestRetry(f.input.jobID, approval: approval, kind: .bake)
    await transport.setUnknown(false)
    #expect(try await run(f, transport: transport).isComplete)
    #expect(await transport.calls.count == 2)
    #expect(try await f.store.pendingRequestRetry(f.input.jobID).requestCount == 0)
  }

  @Test func cacheOnlyDoesNotSendAndCorruptOrMismatchedInflightIsNotResent() async throws {
    let f = try await fixture(count: 1)
    defer { f.clean() }
    let transport = BakeTransport()
    let empty = try await run(f, transport: transport, allowRequests: false)
    #expect(!empty.isComplete && empty.rewrites.isEmpty)
    #expect(await transport.calls.isEmpty)
    let budget = try FactoryBakeBudget(profile: profile())
    let plan = try FactoryBakePlanner.plan(sourceContentHash: f.input.sourceContentHash,
      executor: "test", proposals: f.input.proposals, decisions: f.input.decisions, budget: budget)
    let path = f.input.workspaceURL.appendingPathComponent("bake/batches/\(try plan.blocks[0].fingerprint()).inflight.json")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("malformed-checkpoint".utf8).write(to: path)
    _ = try await run(f, transport: transport)
    #expect(await transport.calls.isEmpty)
    #expect(try Data(contentsOf: path) == Data("malformed-checkpoint".utf8))
  }

  @Test func duplicateUnknownAndMissingDecisionIDsCannotClaimApplication() async throws {
    for mode in [BakeTransport.Invalid.duplicate, .unknownID, .missingDecision, .empty] {
      let f = try await fixture(count: 2, globalDecision: true)
      defer { f.clean() }
      let transport = BakeTransport(invalid: mode)
      let result = try await run(f, transport: transport)
      #expect(await transport.calls.count == 2)
      #expect(result.rewrites.isEmpty && !result.isComplete)
      #expect(result.applying(to: f.input.proposals) == f.input.proposals)
      #expect(try await f.store.pendingRequestRetry(f.input.jobID).requestCount == 0)
    }
  }

  @Test func budgetsAndTargetCapRetainOversizedOrUnselectedItemsWithoutSending() async throws {
    let f = try await fixture(count: 81, globalDecision: true)
    defer { f.clean() }
    let transport = BakeTransport()
    let result = try await run(f, transport: transport)
    #expect(result.targets.count == 81 && result.rewrites.count == 80)
    #expect(!result.isComplete && result.retainedCount == 1)
    #expect(await transport.calls.allSatisfy { $0.ids.count <= 16 && $0.output == 65_536 })
    let continued = try await run(f, transport: transport)
    #expect(continued.isComplete && continued.rewrites.count == 81)
    #expect(await transport.calls.count == 6)
    let tiny = try await run(f, transport: transport, output: 1_024, executor: "tiny")
    #expect(tiny.rewrites.isEmpty && tiny.retainedCount == 81)
    #expect(await transport.calls.count == 6)
    #expect(throws: FactoryBakeError.self) { try FactoryBakeBudget(profile: profile(window: 4_096, output: 8_192)) }
  }

  @Test func applicationReportCannotLieAboutCompletedDecisions() async throws {
    let f = try await fixture(count: 1)
    defer { f.clean() }
    let report = try await run(f, transport: BakeTransport())
    let forged = FactoryBakeReport(sourceFingerprint: report.sourceFingerprint, executor: report.executor,
      targets: report.targets, rewrites: [], unresolvedDecisionIDs: [], warnings: [])
    #expect(throws: FactoryBakeError.self) {
      try forged.validate(sourceFingerprint: f.input.sourceFingerprint,
        proposals: f.input.proposals, decisions: f.input.decisions)
    }
  }

  @Test func overviewReviewTakesPriorityWhenMoreThanEightyEntriesMatch() throws {
    let proposals = (0..<80).map {
      FactoryLoreProposal(id: String(format: "a-%03d", $0), kind: .character, title: "林舟", content: "候选")
    } + [.init(id: "z-overview", kind: .overview, title: "世界总览", content: "全景校验")]
    let decisions = [FactoryDecision(jobID: UUID(), question: "林舟如何行动？", recommendation: "留守",
      evidence: [], resolution: .acceptedRecommendation, answer: "留守")]
    let plan = try FactoryBakePlanner.plan(sourceContentHash: "synthetic", executor: "test",
      proposals: proposals, decisions: decisions, budget: FactoryBakeBudget(profile: profile()))
    #expect(plan.blocks.first?.proposals.first?.id == "z-overview")
    #expect(plan.blocks.flatMap(\.proposals).count == 81)
    #expect(plan.targets.count == 81)
  }

  @Test func bakeCachesAndReportCannotFollowLinksOutsideTheirJob() async throws {
    let f = try await fixture(count: 1)
    defer { f.clean() }
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("sentinel.json")
    try Data("keep".utf8).write(to: sentinel)
    let bake = f.input.workspaceURL.appendingPathComponent("bake")
    try FileManager.default.createDirectory(at: bake, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: bake.appendingPathComponent("batches"), withDestinationURL: outside)
    let transport = BakeTransport()
    await #expect(throws: FactoryRequestRetryError.self) { _ = try await run(f, transport: transport) }
    #expect(await transport.calls.isEmpty)
    try FileManager.default.createSymbolicLink(at: bake.appendingPathComponent("report.json"), withDestinationURL: sentinel)
    let report = FactoryBakeReport.retained(sourceFingerprint: f.input.sourceFingerprint,
      proposals: f.input.proposals, decisions: f.input.decisions, reason: "synthetic")
    await #expect(throws: FactoryBakeError.self) { try await f.store.saveBakeReport(report, jobID: f.input.jobID) }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  private func run(_ f: BakeFixture, transport: BakeTransport, output: Int = 65_536,
    executor: String = "test", allowRequests: Bool = true, window: Int = 131_072,
    playerTaste: PlayerTasteProfile = .standard) async throws -> FactoryBakeReport {
    let budget = try FactoryBakeBudget(profile: profile(window: window, output: output))
    return try await FactoryBakePass(transport: transport, budget: budget, executor: executor)
      .run(jobID: f.input.jobID, sourceContentHash: f.input.sourceContentHash,
        sourceFingerprint: f.input.sourceFingerprint, proposals: f.input.proposals,
        decisions: f.input.decisions, workspaceURL: f.input.workspaceURL,
        allowRequests: allowRequests, playerTaste: playerTaste) { _ in }
  }

  private func profile(window: Int = 131_072, output: Int = 65_536) -> ProviderProfile {
    .init(displayName: "synthetic", kind: .openAICompatible, modelID: "synthetic", credentialReference: "none",
      capabilities: .init(contextWindow: window), maximumOutputTokens: output)
  }

  private func fixture(count: Int, globalDecision: Bool = false) async throws -> BakeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bake-\(UUID())")
    let document = NovelDocument(id: UUID(), title: "合成书", sourceFormat: .text, sourceFileName: "synthetic.txt",
      contentHash: "source", chapters: [.init(id: "chapter", ordinal: 0, title: "渡口", content: "林舟来到渡口。")])
    let store = FactoryJobStore(rootURL: root)
    let job = try await store.create(document: document)
    let proposals = (0..<count).map { index in
      FactoryLoreProposal(id: String(format: "entry-%03d", index), kind: globalDecision ? .overview : .character,
        title: "人物\(index)", content: "原候选\(index)", activationKeys: ["人物\(index)"], archetype: .ally)
    }
    let decisions = (0..<(globalDecision ? 1 : count)).map { index in
      FactoryDecision(jobID: job.id, question: "人物\(index)如何行动？", recommendation: "守候\(index)",
        evidence: [], resolution: .acceptedRecommendation, answer: "守候\(index)")
    }
    return .init(root: root, store: store, input: .init(jobID: job.id, sourceContentHash: document.contentHash,
      sourceFingerprint: "input", proposals: proposals, decisions: decisions,
      workspaceURL: try await store.workspaceURL(jobID: job.id)))
  }
}

private struct BakeFixture {
  let root: URL
  let store: FactoryJobStore
  let input: FactoryBakeInput
  func clean() { try? FileManager.default.removeItem(at: root) }
  func replacing(decisions: [FactoryDecision], fingerprint: String) -> Self {
    .init(root: root, store: store, input: .init(jobID: input.jobID, sourceContentHash: input.sourceContentHash,
      sourceFingerprint: fingerprint, proposals: input.proposals, decisions: decisions, workspaceURL: input.workspaceURL))
  }
}

private actor BakeTransport: FactoryBatchTransport {
  enum Invalid { case duplicate, unknownID, missingDecision, empty }
  struct Call { let ids: [String]; let output: Int }
  var calls: [Call] = []
  var failedID: String?
  var unknown: Bool
  var invalid: Invalid?
  init(failedID: String? = nil, unknown: Bool = false, invalid: Invalid? = nil) {
    self.failedID = failedID; self.unknown = unknown; self.invalid = invalid
  }
  func setFailedID(_ id: String?) { failedID = id }
  func setUnknown(_ value: Bool) { unknown = value }
  func beginRequest(title: String) async throws -> String { UUID().uuidString }
  func cancel() async {}
  func recoverInflight(checkpointToken: String) async throws -> String? { nil }
  func send(checkpointToken: String, systemPrompt: String, prompt: String) async throws -> String {
    try await send(checkpointToken: checkpointToken, systemPrompt: systemPrompt, prompt: prompt, maximumOutputTokens: 0)
  }
  func send(checkpointToken: String, systemPrompt: String, prompt: String, maximumOutputTokens: Int) async throws -> String {
    let raw = try #require(prompt.components(separatedBy: "<bake_input>").last?.components(separatedBy: "</bake_input>").first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let input = try #require(object["entries"] as? [[String: Any]])
    calls.append(.init(ids: input.compactMap { $0["id"] as? String }, output: maximumOutputTokens))
    if unknown { throw URLError(.networkConnectionLost) }
    if let failedID, calls.last?.ids.contains(failedID) == true { return #"{"entries":[]}"# }
    var entries: [[String: Any]] = input.map {
      ["id": $0["id"]!, "content": "按人工决策编辑：\($0["title"]!)", "decision_ids": $0["decisionIDs"]!]
    }
    switch invalid {
    case .duplicate: entries = Array(repeating: entries[0], count: entries.count)
    case .unknownID: entries[0]["id"] = "external-entry"
    case .missingDecision: entries[0]["decision_ids"] = []
    case .empty: entries = []
    case nil: break
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["entries": entries]), as: UTF8.self)
  }
}
