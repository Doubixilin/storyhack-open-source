import CryptoKit
import Foundation
import LLMProviderKit

/// 直连模型版批次传输：用 App 内配置的 LLMProvider 发请求。
/// 检查点凭证是本地 request id——OpenAI-compatible API 没有服务端会话可查，
/// 因此 `recoverInflight` 一律返回 nil，命中检查点即落入
/// `uncertainPriorRequest` 保守路径（禁止自动重发，避免重复扣费）。
actor DirectLLMBatchTransport: FactoryBatchTransport {
  private let provider: any LLMProvider
  private var inFlight: [String: Task<String, Error>] = [:]
  private var cancelled = false

  init(provider: any LLMProvider) {
    self.provider = provider
  }

  func beginRequest(title _: String) async throws -> String {
    try checkCancellation()
    return UUID().uuidString
  }

  func send(checkpointToken: String, systemPrompt: String, prompt: String) async throws -> String {
    try checkCancellation()
    let budget = try FactoryAnalysisBudget(profile: provider.profile)
    try budget.validate(system: systemPrompt, prompt: prompt)
    return try await perform(checkpointToken: checkpointToken, systemPrompt: systemPrompt,
      prompt: prompt, maximumOutputTokens: budget.output)
  }

  func send(checkpointToken: String, systemPrompt: String, prompt: String,
    maximumOutputTokens: Int) async throws -> String {
    try checkCancellation()
    let window = provider.profile.capabilities.contextWindow ?? 32_768
    guard (512...65_536).contains(maximumOutputTokens),
      LLMTokenEstimate.tokens(systemPrompt + prompt) + 64
        <= window - maximumOutputTokens - max(512, window / 20) else { throw FactoryBakeError.oversizedInput }
    return try await perform(checkpointToken: checkpointToken, systemPrompt: systemPrompt,
      prompt: prompt, maximumOutputTokens: maximumOutputTokens)
  }

  private func perform(checkpointToken: String, systemPrompt: String, prompt: String,
    maximumOutputTokens: Int) async throws -> String {
    let request = LLMRequest(
      requestID: UUID(uuidString: checkpointToken) ?? UUID(),
      messages: [
        LLMMessage(role: .system, content: systemPrompt),
        LLMMessage(role: .user, content: prompt),
      ],
      // 工坊批次（含修复/补全请求）固定低思考强度，沿用已验证的批次
      // 行为；其它调用点不受影响。
      modelOptions: .init(maximumOutputTokens: maximumOutputTokens, reasoningEffort: "low")
    )
    let task = Task { [provider] in
      try Task.checkCancellation()
      var text = ""
      var bytes = 0
      var completed = false
      for try await event in provider.stream(request) {
        try Task.checkCancellation()
        switch event {
        case .textDelta(let delta):
          bytes += delta.utf8.count
          guard bytes <= 1_048_576 else { throw OpenAICompatibleError.incompleteStream }
          text += delta
        case .toolCall: throw LLMToolError.unexpectedCall
        case .completed: completed = true
        }
      }
      try Task.checkCancellation()
      guard completed else { throw OpenAICompatibleError.incompleteStream }
      return text
    }
    inFlight[checkpointToken] = task
    defer { inFlight.removeValue(forKey: checkpointToken) }
    let rawOutput: String
    do {
      rawOutput = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch let error as OpenAICompatibleError {
      // 401/403 是确定性失败：立即映射为认证错误（致命，不重试）。
      // 其余 HTTP 状态原样上抛，由编排器按状态码分类（仅 429 可自动重试，
      // 其它状态码请求已到达服务端，按结果不确定处理）。
      if case .httpStatus(let code, let body) = error {
        if code == 401 || code == 403 { throw FactoryWorkerError.authentication }
        throw FactoryWorkerError.httpStatus(code, body)
      }
      throw error
    }
    let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw FactoryWorkerError.invalidResponse("模型没有返回任何内容")
    }
    return trimmed
  }

  func recoverInflight(checkpointToken _: String) async throws -> String? {
    try checkCancellation()
    return nil
  }

  func cancel() async {
    cancelled = true
    let tasks = inFlight.values
    inFlight.removeAll()
    for task in tasks { task.cancel() }
  }

  private func checkCancellation() throws {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
  }
}

/// 世界书工坊直连模型执行器：与游玩、节拍线共用同一套 ProviderKit 配置，
/// 批次编排复用共享的 `FactoryAnalysisRunner`。跨平台（iOS 开放是后续阶段）。
public actor DirectLLMFactoryWorker: FactoryAnalysisWorker {
  private let provider: any LLMProvider
  private let providerDisplayName: String
  private let modelID: String
  private let maximumBatchUTF16Length: Int
  private let concurrency: Int
  private let fileManager: FileManager
  private var transports: [UUID: DirectLLMBatchTransport] = [:]

  public init(
    provider: any LLMProvider,
    providerDisplayName: String? = nil,
    modelID: String? = nil,
    maximumBatchUTF16Length: Int = 50_000,
    concurrency: Int = ProviderProfile.defaultFactoryConcurrency,
    fileManager: FileManager = .default
  ) {
    self.provider = provider
    self.providerDisplayName = providerDisplayName ?? provider.profile.displayName
    self.modelID = modelID ?? provider.profile.modelID
    self.maximumBatchUTF16Length = max(1, maximumBatchUTF16Length)
    self.concurrency = min(16, max(1, concurrency))
    self.fileManager = fileManager
  }

  public var executorVersion: String {
    let profile = provider.profile
    let settings = [
      profile.baseURL?.absoluteString ?? "", profile.modelID,
      String(profile.capabilities.contextWindow ?? 32_768),
      String(profile.maximumOutputTokens ?? 4_096),
      "analysis-prompt-v4", "request-budget-v1", "schema-v1", "reasoning-low", String(maximumBatchUTF16Length),
    ].joined(separator: "\n")
    let hash = SHA256.hash(data: Data(settings.utf8)).map { String(format: "%02x", $0) }.joined()
    return "direct-llm/3 (\(providerDisplayName), \(modelID))/" + hash
  }

  public func analyze(
    jobID: UUID,
    manifest: FactoryInputManifest,
    snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    let budget = try FactoryAnalysisBudget(profile: provider.profile)
    let transport = DirectLLMBatchTransport(provider: provider)
    transports[jobID] = transport
    defer { transports.removeValue(forKey: jobID) }
    let runner = FactoryAnalysisRunner(
      transport: transport,
      maximumBatchUTF16Length: maximumBatchUTF16Length,
      executorVersion: executorVersion,
      concurrency: concurrency,
      budget: budget,
      fileManager: fileManager
    )
    return try await runner.run(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshotURL,
      progress: progress
    )
  }

  public func cancel(jobID: UUID) async {
    await transports[jobID]?.cancel()
  }

  public func bake(_ input: FactoryBakeInput, allowRequests: Bool,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport {
    let budget = try FactoryBakeBudget(profile: provider.profile)
    let transport = DirectLLMBatchTransport(provider: provider)
    transports[input.jobID] = transport
    defer { transports.removeValue(forKey: input.jobID) }
    let executor = "direct-bake/1/" + (try FactoryBakeHash.value([
      provider.profile.baseURL?.absoluteString ?? "", provider.profile.modelID,
      provider.profile.kind.rawValue, String(budget.window), String(budget.output), "reasoning-low",
    ]))
    return try await FactoryBakePass(transport: transport, budget: budget, executor: executor)
      .run(jobID: input.jobID, sourceContentHash: input.sourceContentHash,
        sourceFingerprint: input.sourceFingerprint, proposals: input.proposals, decisions: input.decisions,
        workspaceURL: input.workspaceURL, allowRequests: allowRequests, playerTaste: input.playerTaste, progress: progress)
  }
}

/// 延迟从 ProviderProfileStore 解析默认 Provider 的工坊执行器。
/// 根视图 init 是同步的，无法当时读取 actor 化的配置，因此真正分析时
/// 再取列表第一个 profile（与节拍线提取同一模式）；一个都没配置时
/// 抛出引导性错误而不是崩溃。
public actor DefaultProviderFactoryWorker: FactoryAnalysisWorker {
  private let providerStore: ProviderProfileStore
  // 按 jobID 键控：两个不同任务并发时取消不会误伤对方
  private var activeWorkers: [UUID: DirectLLMFactoryWorker] = [:]
  private var cancelledJobs: Set<UUID> = []

  public init(providerStore: ProviderProfileStore) {
    self.providerStore = providerStore
  }

  public func analyze(
    jobID: UUID,
    manifest: FactoryInputManifest,
    snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    cancelledJobs.remove(jobID)
    defer { cancelledJobs.remove(jobID) }
    let profiles = (try? await providerStore.list()) ?? []
    guard let profile = profiles.first else {
      throw FactoryWorkerError.unavailable("世界书工坊需要先配置模型服务：请在「模型设置」中添加模型。")
    }
    let provider = try await providerStore.makeProvider(profileID: profile.id)
    guard !cancelledJobs.contains(jobID) else { throw CancellationError() }
    let worker = DirectLLMFactoryWorker(
      provider: provider,
      concurrency: profile.effectiveFactoryConcurrency
    )
    activeWorkers[jobID] = worker
    defer { activeWorkers.removeValue(forKey: jobID) }
    return try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshotURL,
      progress: progress
    )
  }

  public func cancel(jobID: UUID) async {
    cancelledJobs.insert(jobID)
    await activeWorkers[jobID]?.cancel(jobID: jobID)
  }

  public func bake(_ input: FactoryBakeInput, allowRequests: Bool,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport {
    cancelledJobs.remove(input.jobID)
    defer { cancelledJobs.remove(input.jobID) }
    let profiles = try await providerStore.list()
    guard let profile = profiles.first else {
      if !allowRequests {
        return .retained(sourceFingerprint: input.sourceFingerprint, proposals: input.proposals,
          decisions: input.decisions, reason: "没有可用模型配置，未发起新的定向改写。")
      }
      throw FactoryWorkerError.unavailable("请先在模型设置中配置模型，再按决策生成候选。")
    }
    let provider = try await providerStore.makeProvider(profileID: profile.id)
    guard !cancelledJobs.contains(input.jobID) else { throw CancellationError() }
    let worker = DirectLLMFactoryWorker(provider: provider, concurrency: profile.effectiveFactoryConcurrency)
    activeWorkers[input.jobID] = worker
    defer { activeWorkers.removeValue(forKey: input.jobID) }
    return try await worker.bake(input, allowRequests: allowRequests, progress: progress)
  }
}
