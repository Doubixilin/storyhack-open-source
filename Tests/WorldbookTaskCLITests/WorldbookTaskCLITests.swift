import Foundation
import Testing
import LLMProviderKit
import WritingCore
import StoryworldCore
import StoryworldFactory
@testable import WorldbookTaskCLI

struct WorldbookTaskCLITests {
  @Test func storedProviderIsReadOnlyAndTaskTasteOverridesCommandLine() async throws {
    let f = try CLIFixture(); defer { f.clean() }
    let plan = try f.write("第一章｜林舟来到渡口。", name: "plan.txt")
    let job = try f.decode(AdaptationJob.self, await f.run(["adaptation", "original", "--source", plan.path, "--title", "偏好测试"]))
    let variant = try #require(job.variants.first)
    let store = AdaptationJobStore(rootURL: f.root.appendingPathComponent("Adaptations"))
    var contract = try await store.direction(jobID: job.id, revisionID: variant.contractRevisionID).contract
    contract.minimumCharacterCount = 1; contract.targetCharacterCount = 100
    _ = try await store.updateDirection(jobID: job.id, variantID: variant.id, expectedContractRevisionID: variant.contractRevisionID, contract: contract)
    let profile = ProviderProfile(displayName: "配置模型", kind: .openAICompatible, baseURL: URL(string: "https://example.invalid/v1"),
      modelID: "configured-synthetic", credentialReference: "app-keychain-reference")
    struct Profiles: Encodable { let profiles: [ProviderProfile] }
    try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Providers"), withIntermediateDirectories: true)
    let profileFile = try f.write(Profiles(profiles: [profile]), name: "Providers/profiles.json")
    let originalBytes = try Data(contentsOf: profileFile)
    var config = AdaptationRunConfiguration(); config.providerID = profile.id; config.taskTaste.notes = "任务表达要求"
    _ = try await store.saveRunConfiguration(config, jobID: job.id, expectedRevision: nil)
    let cliTaste = try f.write(PlayerTasteOverrides(notes: "CLI 表达要求"), name: "taste.json")
    let command = ["adaptation", "write", "--job", job.id.uuidString, "--variant", variant.id.uuidString, "--taste", cliTaste.path]
    #expect(await f.run(command, credentials: false).exitCode == 2)
    #expect(await f.run(command).exitCode == 0)
    let prompt = try #require(await f.recorder.prompts.last)
    #expect(prompt.contains("任务表达要求") && !prompt.contains("CLI 表达要求"))
    #expect(await f.recorder.profiles.last?.modelID == "configured-synthetic")
    #expect(await f.recorder.profiles.last?.credentialReference == EnvironmentCredentialStore.reference)
    #expect(try Data(contentsOf: profileFile) == originalBytes)
    #expect(await f.run(command + ["--max-requests", "0"], credentials: false).exitCode == 0)
    #expect(await f.recorder.count == 1)
  }

  @Test func credentialsAreReadOnlyAndInvalidArgumentsDoNotCreateData() async throws {
    let credential = EnvironmentCredentialStore(environment: ["WORLDBOOK_API_KEY": "synthetic-secret"])
    #expect(try credential.load(reference: EnvironmentCredentialStore.reference) == "synthetic-secret")
    #expect(throws: (any Error).self) { try credential.load(reference: "keychain-reference") }
    #expect(throws: (any Error).self) { try credential.save("other", reference: EnvironmentCredentialStore.reference) }
    #expect(throws: (any Error).self) { try credential.delete(reference: EnvironmentCredentialStore.reference) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cli = WorldbookTaskCLI()
    for arguments in [["adaptation", "list", "--api-key", "synthetic-secret"],
      ["adaptation", "list", "--job", "bad"], ["factory", "resume", "--allow-resend"],
      ["adaptation", "list", "--root", root.path]] {
      let result = await cli.run(arguments: arguments + ["--root", root.path], environment: [:])
      #expect(result.exitCode == 2)
      #expect(!result.diagnostic.contains("synthetic-secret"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func commandOriginalWriteResumeReviewAndExportUseSharedStore() async throws {
    let f = try CLIFixture(); defer { f.clean() }
    let plan = try f.write("开篇｜林舟来到渡口。\n返程｜林舟带信返回。", name: "plan.txt")
    let made = await f.run(["adaptation", "original", "--source", plan.path, "--title", "合成试写"])
    #expect(made.exitCode == 0)
    let job = try f.decode(AdaptationJob.self, made), variant = try #require(job.variants.first)
    let store = AdaptationJobStore(rootURL: f.root.appendingPathComponent("Adaptations"))
    var contract = try await store.direction(jobID: job.id, revisionID: variant.contractRevisionID).contract
    contract.minimumCharacterCount = 1; contract.targetCharacterCount = 100
    let contractFile = try f.write(contract, name: "contract.json")
    #expect(await f.run(["adaptation", "contract", "--job", job.id.uuidString, "--variant", variant.id.uuidString,
      "--file", contractFile.path, "--revision", variant.contractRevisionID.uuidString]).exitCode == 0)
    let arguments = ["adaptation", "write", "--job", job.id.uuidString, "--variant", variant.id.uuidString, "--max-requests", "1"]
    let first = await f.run(arguments)
    #expect(first.exitCode == 3)
    #expect(try f.decode(AdaptationWriteReport.self, first).newRequestCount == 1)
    #expect(await f.run(arguments).exitCode == 0)
    #expect(await f.recorder.count == 2)
    #expect(await f.run(arguments).exitCode == 0)
    #expect(await f.recorder.count == 2)
    let snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    for row in snapshot.current {
      let current = try await store.drafts(jobID: job.id, variantID: variant.id)
      let review = CLIReview(kind: .draft, jobID: job.id, revision: current.revision, action: .approve,
        proposalID: nil, variantID: variant.id, draftID: row.draft.id, anchorID: nil, generationAction: nil,
        intensity: nil, note: "合成作者核对", acknowledge: true)
      let path = try f.write(review, name: "review.json")
      #expect(await f.run(["adaptation", "review", "--job", job.id.uuidString, "--file", path.path]).exitCode == 0)
    }
    let assembly = await f.run(["adaptation", "assemble", "--job", job.id.uuidString, "--variant", variant.id.uuidString])
    #expect(assembly.exitCode == 0)
    let file = try f.write(assembly.output, name: "assembly.json")
    #expect(await f.run(["adaptation", "export", "--job", job.id.uuidString, "--file", file.path]).exitCode == 0)
    #expect(await f.run(["adaptation", "publish", "--job", job.id.uuidString, "--file", file.path]).exitCode == 0)
    #expect(await f.recorder.count == 2)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Providers").path))
  }

  @Test func staleConfigurationAndWrongTaskApprovalAreRejected() async throws {
    let f = try CLIFixture(); defer { f.clean() }
    let plan = try f.write("章一｜寻找渡口", name: "plan.txt")
    let first = await f.run(["adaptation", "original", "--source", plan.path, "--title", "第一任务"])
    let job = try f.decode(AdaptationJob.self, first)
    var config = AdaptationRunConfiguration(); config.density = 4
    let path = try f.write(config, name: "config.json")
    let command = ["adaptation", "config", "--job", job.id.uuidString, "--file", path.path]
    #expect(await f.run(command).exitCode == 0)
    config.density = 5
    _ = try f.write(config, name: "config.json")
    #expect(await f.run(command).exitCode == 1)
    let store = AdaptationJobStore(rootURL: f.root.appendingPathComponent("Adaptations"))
    var fresh = try await store.runConfiguration(job.id)
    fresh.regenerationID = UUID()
    _ = try f.write(fresh, name: "config.json")
    #expect(await f.run(command).exitCode == 1)
    #expect(try await store.runConfiguration(job.id).regenerationID == nil)
    let bad = CLIReview(kind: .bookcase, jobID: UUID(), revision: job.revision, action: .approve,
      proposalID: UUID(), variantID: nil, draftID: nil, anchorID: nil, generationAction: nil,
      intensity: nil, note: nil, acknowledge: nil)
    let review = try f.write(bad, name: "review.json")
    #expect(await f.run(["adaptation", "review", "--job", job.id.uuidString, "--file", review.path]).exitCode == 2)
    #expect(await f.recorder.count == 0)
  }
}

actor CLIRecorder {
  var count = 0
  var prompts: [String] = []
  var profiles: [ProviderProfile] = []
  func recordProfile(_ profile: ProviderProfile) { profiles.append(profile) }
  func reply(_ request: LLMRequest) throws -> String {
    count += 1
    let prompt = request.messages.last!.content
    prompts.append(prompt)
    let body = prompt.dropFirst("写作输入（结构化资料）：\n".count).components(separatedBy: "\n")[0]
    let input = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    let context = try #require(input["context"] as? [String: Any])
    let target = try #require(context["target"] as? [String: Any])
    let chapter = try #require(target["chapter_id"] as? String)
    let value = AdaptationDraftContent(title: "新章" + chapter, body: "林舟在渡口收好信件，沿着山路返回。", recap: "带信返程",
      reviewLine: "合成章审", recipe: .init(trigger: chapter, setting: "渡口", technique: "动作"))
    return String(decoding: try AdaptationCoding.encoder().encode(value), as: UTF8.self)
  }
}
struct CLIProvider: LLMProvider {
  let profile: ProviderProfile
  let recorder: CLIRecorder
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    .init { continuation in
      let task = Task {
        do { continuation.yield(.textDelta(try await recorder.reply(request))); continuation.yield(.completed); continuation.finish() }
        catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
struct CLIFixture {
  let root: URL
  let recorder = CLIRecorder()
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("worldbook-cli-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func write(_ text: String, name: String) throws -> URL {
    let url = root.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
  }
  func write<T: Encodable>(_ value: T, name: String) throws -> URL { try write(String(decoding: AdaptationCoding.encoder().encode(value), as: UTF8.self), name: name) }
  func decode<T: Decodable>(_ type: T.Type, _ result: CLIResult) throws -> T { try AdaptationCoding.decoder().decode(type, from: Data(result.output.utf8)) }
  func run(_ arguments: [String], credentials: Bool = true) async -> CLIResult {
    var environment = ["WORLDBOOK_MODEL": "fixture", "WORLDBOOK_BASE_URL": "http://127.0.0.1:9/v1"]
    if credentials { environment["WORLDBOOK_API_KEY"] = "synthetic-secret" }
    return await WorldbookTaskCLI(providerFactory: { [recorder] profile in
      await recorder.recordProfile(profile)
      return CLIProvider(profile: profile, recorder: recorder)
    }).run(arguments: arguments + ["--root", root.path], environment: environment)
  }
}
