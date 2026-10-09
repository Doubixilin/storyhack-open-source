import Foundation
import LLMProviderKit

public struct FactoryWorkerResult: Sendable {
  public let analysis: FactoryAnalysis
  public let executorVersion: String
  public let sessionID: String?

  public init(analysis: FactoryAnalysis, executorVersion: String, sessionID: String? = nil) {
    self.analysis = analysis
    self.executorVersion = executorVersion
    self.sessionID = sessionID
  }
}

public struct FactoryWorkerProgress: Equatable, Sendable {
  public let fraction: Double
  public let executorVersion: String?
  public let sessionID: String?

  public init(fraction: Double, executorVersion: String? = nil, sessionID: String? = nil) {
    self.fraction = min(max(fraction, 0), 1)
    self.executorVersion = executorVersion
    self.sessionID = sessionID
  }
}

public protocol FactoryAnalysisWorker: Sendable {
  func analyze(
    jobID: UUID,
    manifest: FactoryInputManifest,
    snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult

  func cancel(jobID: UUID) async
  func bake(_ input: FactoryBakeInput, allowRequests: Bool,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport
}

extension FactoryAnalysisWorker {
  public func bake(_ input: FactoryBakeInput, allowRequests: Bool,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport {
    .retained(sourceFingerprint: input.sourceFingerprint, proposals: input.proposals,
      decisions: input.decisions, reason: "当前执行器不提供定向改写，人工决策与表达偏好保留为待核对项。",
      playerTaste: input.playerTaste)
  }
}

public struct UnavailableFactoryAnalysisWorker: FactoryAnalysisWorker {
  public init() {}

  public func analyze(
    jobID _: UUID,
    manifest _: FactoryInputManifest,
    snapshotURL _: URL,
    progress _: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    throw FactoryWorkerError.unavailable("当前平台暂不提供世界书生成。")
  }

  public func cancel(jobID _: UUID) async {}
}

public enum FactoryWorkerError: Error, Equatable, LocalizedError {
  case unavailable(String)
  case startFailed(String)
  case healthCheckFailed
  case authentication
  case httpStatus(Int, String)
  case invalidResponse(String)
  case incompleteCoverage(expected: Int, actual: Int)
  case missingEvidence(String)
  case sessionFailed(String)
  case uncertainPriorRequest(Int)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): message
    case .startFailed: "世界书分析暂时无法启动，请稍后重试。"
    case .healthCheckFailed: "暂时无法连接模型服务，请检查模型设置和网络。"
    case .authentication: ProviderErrorMessage.message(statusCode: 401)
    case .httpStatus(let code, let body):
      ProviderErrorMessage.message(statusCode: code, responseBody: body)
    case .invalidResponse: "模型回复格式不符合世界书工坊要求，请重试或更换模型。"
    case .incompleteCoverage(let expected, let actual):
      "工坊执行器没有覆盖完整章节批次（应为 \(expected)，实际为 \(actual)）"
    case .missingEvidence(let title): "候选“\(title)”没有可定位的原文证据"
    case .sessionFailed: "世界书分析中断，请重试；已完成的安全进度会保留。"
    case .uncertainPriorRequest(let batch):
      "第 \(batch) 批上次请求是否计费无法确认，已停止自动重试以避免重复扣费"
    }
  }
}
