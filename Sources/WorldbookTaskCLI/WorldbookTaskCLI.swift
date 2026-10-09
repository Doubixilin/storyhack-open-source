import Foundation
import DirectoryJournalCore
import LibraryCore
import LLMProviderKit
import StoryworldCore
import StoryworldFactory
import WritingCore
import WritingAssistantCore

public struct WorldbookTaskCLI: Sendable {
  public typealias ProviderFactory = @Sendable (ProviderProfile) async throws -> any LLMProvider
  private let providerFactory: ProviderFactory?
  public init(providerFactory: ProviderFactory? = nil) { self.providerFactory = providerFactory }

  public func run(arguments: [String], environment: [String: String]) async -> CLIResult {
    if arguments == ["--help"] || arguments == ["help"] { return .init(output: worldbookTaskHelp + "\n") }
    do {
      let context = try CLIContext(arguments: CLIArguments(arguments), environment: environment, providerFactory: providerFactory)
      try Task.checkCancellation()
      return try await context.execute()
    } catch {
      let code: Int32
      let cancelled = Task.isCancelled || error is CancellationError
      if cancelled { code = 130 }
      else { switch error {
      case is CancellationError: code = 130
      case DirectoryProcessLockError.busy: code = 75
      case AdaptationRequestError.uncertain, FactoryRequestRetryError.confirmationRequired,
        FactoryWorkerError.uncertainPriorRequest: code = 4
      case is CLIError, is DecodingError: code = 2
      default: code = 1
      } }
      var message: String
      if cancelled { message = "已取消；完整结果已保留，未决请求需核对后才能重发。" }
      else if error is CLIError || error is DirectoryProcessLockError || error is AdaptationError
        || error is AdaptationRequestError || error is AdaptationExecutionError || error is AdaptationAssemblyError
        || error is FactoryCoordinatorError || error is FactoryRequestRetryError || error is ProviderConfigurationError {
        message = error.localizedDescription
      } else if case OpenAICompatibleError.httpStatus(let status, _) = error { message = "模型服务返回 HTTP \(status)；未打印响应正文。" }
      else if error is DecodingError { message = "输入 JSON 不符合命令格式，未应用本次修改。" }
      else { message = "任务执行失败；已完成数据保留，请读取 status、report 和 pending 检查状态。" }
      if let secret = environment["WORLDBOOK_API_KEY"], !secret.isEmpty {
        message = message.replacingOccurrences(of: secret, with: "[凭据已隐藏]")
      }
      return .init(diagnostic: message + "\n", exitCode: code)
    }
  }
}

struct CLIContext: Sendable {
  let args: CLIArguments
  let environment: [String: String]
  let providerFactory: WorldbookTaskCLI.ProviderFactory?
  let root: URL
  let adaptation: AdaptationJobStore
  let factory: FactoryJobStore
  let library: NovelLibrary
  let worlds: StoryworldLibrary
  let taste: PlayerTasteStore
  init(arguments: CLIArguments, environment: [String: String], providerFactory: WorldbookTaskCLI.ProviderFactory?) throws {
    args = arguments; self.environment = environment; self.providerFactory = providerFactory
    root = arguments["root"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
      ?? AdaptationJobStore.defaultRootURL.deletingLastPathComponent()
    adaptation = AdaptationJobStore(rootURL: root.appendingPathComponent("Adaptations"))
    factory = FactoryJobStore(rootURL: root.appendingPathComponent("Factory"))
    library = NovelLibrary(rootURL: root.appendingPathComponent("Library"))
    worlds = StoryworldLibrary(rootURL: root.appendingPathComponent("Storyworlds"))
    taste = PlayerTasteStore(rootURL: root.appendingPathComponent("PlayerTaste"))
  }
  func execute() async throws -> CLIResult {
    if args.domain == "adaptation" { return try await executeAdaptation() }
    return try await executeFactory()
  }
  func read<T: Decodable>(_ type: T.Type, option: String = "file", maximum: Int = 20 * 1_048_576) throws -> T {
    try AdaptationCoding.decoder().decode(type, from: fileBytes(option: option, maximum: maximum))
  }
  func fileBytes(option: String, maximum: Int) throws -> Data {
    let url = URL(fileURLWithPath: try args.required(option))
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximum else { throw CLIError.invalid("--" + option) }
    let data = try Data(contentsOf: url)
    guard data.count <= maximum else { throw CLIError.invalid("--" + option) }
    return data
  }
  func json<T: Encodable>(_ value: T, code: Int32 = 0) throws -> CLIResult {
    .init(output: String(decoding: try AdaptationCoding.encoder().encode(value), as: UTF8.self) + "\n", exitCode: code)
  }
  func commandLineTaste() throws -> PlayerTasteOverrides {
    try args["taste"] == nil ? .init() : read(PlayerTasteOverrides.self, option: "taste").validated()
  }
  func provider(defaultID: UUID? = nil, needsCredential: Bool = true) async throws -> any LLMProvider {
    let explicitID = try args["provider"].map { _ in try args.uuid("provider") }
    var profile: ProviderProfile
    if let id = explicitID ?? defaultID {
      let store = ProviderProfileStore(rootURL: root.appendingPathComponent("Providers"),
        credentialStore: EnvironmentCredentialStore(environment: environment))
      guard let stored = try await store.list().first(where: { $0.id == id }) else { throw ProviderConfigurationError.profileNotFound(id) }
      profile = stored
    } else {
      profile = .init(displayName: "CLI", kind: .openAICompatible,
        modelID: environment["WORLDBOOK_MODEL"] ?? "", credentialReference: EnvironmentCredentialStore.reference)
      profile.baseURL = environment["WORLDBOOK_BASE_URL"].flatMap(URL.init(string:))
    }
    if let model = args["model"] { profile.modelID = model }
    if let base = args["base-url"] { profile.baseURL = URL(string: base) }
    guard profile.kind == .openAICompatible else { throw ProviderConfigurationError.unsupportedProviderKind }
    guard !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError.missing("--model 或 WORLDBOOK_MODEL") }
    guard let url = profile.baseURL, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      let host = url.host, url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { throw CLIError.invalid("--base-url") }
    profile.credentialReference = EnvironmentCredentialStore.reference
    profile.capabilities.contextWindow = try args.integer("context-window", default: profile.capabilities.contextWindow ?? 32_768, range: 2_048...2_000_000)
    profile.maximumOutputTokens = try args.integer("output-tokens", default: profile.maximumOutputTokens ?? 4096, range: 512...65_536)
    let timeout = profile.requestTimeoutInterval ?? 120
    guard timeout.isFinite, (1...3600).contains(timeout) else { throw CLIError.invalid("模型超时") }
    profile.requestTimeoutInterval = TimeInterval(try args.integer("timeout", default: Int(timeout), range: 1...3600))
    profile.factoryConcurrency = try args.integer("concurrency", default: profile.effectiveFactoryConcurrency, range: 1...16)
    _ = try AdaptationRequestBudget(profile: profile)
    let key = needsCredential ? try EnvironmentCredentialStore(environment: environment).load(reference: EnvironmentCredentialStore.reference) : ""
    if let providerFactory { return try await providerFactory(profile) }
    return try OpenAICompatibleProvider(profile: profile, apiKey: key)
  }
}
