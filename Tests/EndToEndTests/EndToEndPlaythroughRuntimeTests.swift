import Foundation
import StoryworldCore
import Testing

/// 链路 C（离线核心）：游玩运行时 —— 回合、分支、存档、读档、三模式泳道。
/// 这里用 commitTurn 注入确定性叙事，验证运行时状态机，不触发网络。
struct EndToEndPlaythroughRuntimeTests {
  private func makeStoryworldLibrary(root: URL) -> StoryworldLibrary {
    StoryworldLibrary(rootURL: root.appendingPathComponent("storyworlds", isDirectory: true))
  }

  private func lorebook() -> Lorebook {
    Lorebook(
      title: "青石镇",
      entries: [
        LoreEntry(title: "林舟", content: "主角，调查旧塔失踪案。", activationKeys: ["林舟"]),
        LoreEntry(title: "旧塔", content: "镇外废弃古塔，塔内有云纹铜牌。", activationKeys: ["旧塔"]),
      ]
    )
  }

  @Test
  func playthroughCommitsTurnsAndForksBranchesWithSaves() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = makeStoryworldLibrary(root: root)
    let record = try await library.create(lorebook: lorebook(), title: "青石镇世界书")
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)

    // 创建游玩线
    let context = try await runtime.createPlaythrough(
      title: "第一次游玩",
      initialState: ["location": .string("镇口")]
    )
    #expect(context.branch.branch.title == "正史")

    // 提交两个回合
    let turn1 = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "我走进青石镇。",
      narrative: "你踏进青石镇，青石板路在雨中泛光。",
      statePatchData: Data(#"{"location":"酒肆"}"#.utf8)
    )
    #expect(turn1.sequence == 1)

    let turn2 = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "我望向镇外的旧塔。",
      narrative: "你望向旧塔，塔尖隐没在夜雾里。",
      statePatchData: Data(#"{"location":"镇口"}"#.utf8)
    )
    #expect(turn2.sequence == 2)

    // 存档（在事件 2 处）
    let save = try await runtime.createSave(
      address: context.address,
      title: "入镇后"
    )
    #expect(save.eventSequence == 2)

    // 从事件 1 处切出新分支
    let forked = try await runtime.forkBranch(
      address: context.address,
      atEventSequence: 1,
      title: "邪神线"
    )
    #expect(forked.branch.branch.parentBranchID == context.branch.id)
    #expect(forked.branch.branch.forkedAtEventSequence == 1)

    // 新分支状态继承自分叉点（事件 1 之后，即 turn1 应用的 location=酒肆），
    // 本地事件序号从 0 重新起算；有效历史仍携带分叉前父分支回合
    let snapshot = try await runtime.load(address: forked.address)
    #expect(snapshot.state.lastEventSequence == 0)
    #expect(snapshot.state.values["location"] == .string("酒肆"))
    #expect(snapshot.turns.isEmpty)
    #expect(snapshot.effectiveTurns.map(\.userMessage) == ["我走进青石镇。"])

    // 原分支不受影响
    let original = try await runtime.load(address: context.address)
    #expect(original.turns.count == 2)
    #expect(original.saves.count == 1)

    // 读档：从存档建立新分支
    let restored = try await runtime.restoreSaveAsNewBranch(
      address: context.address,
      saveID: save.id,
      title: "从入镇后继续"
    )
    let restoredSnapshot = try await runtime.load(address: restored.address)
    #expect(restoredSnapshot.state.lastEventSequence == 0)
    #expect(restoredSnapshot.state.values["location"] == .string("镇口"))
    #expect(restoredSnapshot.turns.isEmpty)
    #expect(restoredSnapshot.effectiveTurns.count == 2)

    // 分支列表：应有 3 个分支（正史 + 邪神线 + 从存档）
    let branches = try await runtime.listBranches(playthroughID: context.playthrough.id)
    #expect(branches.count == 3)

    // 分支图
    let graph = try await runtime.loadBranchGraph(playthroughID: context.playthrough.id)
    #expect(graph.nodes.count == 3)
    #expect(graph.activeBranchID == restored.branch.id)
    // 当前路径应包含从存档分支及其祖先
    let onPath = graph.nodes.filter(\.isOnActivePath).map(\.title)
    #expect(onPath.contains("从入镇后继续"))
  }

  @Test
  func threePlayModesRemainIsolated() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = makeStoryworldLibrary(root: root)
    let record = try await library.create(lorebook: lorebook(), title: "三模式测试")
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)

    let context = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "正史第一回合。",
      narrative: "正史叙事。",
      statePatchData: Data(#"{"mode":"canon"}"#.utf8)
    )

    // 切到 God Mode（fork 自正史）
    let god = try await runtime.forkBranch(address: context.address, title: "God Mode")
    _ = try await runtime.commitTurn(
      address: god.address,
      turnID: UUID(),
      userMessage: "God 回合。",
      narrative: "God 叙事。",
      statePatchData: Data(#"{"mode":"god"}"#.utf8)
    )

    // 切到邪神线（fork 自正史）
    let evil = try await runtime.forkBranch(address: context.address, title: "邪神线")
    _ = try await runtime.commitTurn(
      address: evil.address,
      turnID: UUID(),
      userMessage: "邪神回合。",
      narrative: "邪神叙事。",
      statePatchData: Data(#"{"mode":"evil"}"#.utf8)
    )

    // 验证三条线状态互相隔离
    let canonSnap = try await runtime.load(address: context.address)
    let godSnap = try await runtime.load(address: god.address)
    let evilSnap = try await runtime.load(address: evil.address)

    #expect(canonSnap.state.values["mode"] == .string("canon"))
    #expect(godSnap.state.values["mode"] == .string("god"))
    #expect(evilSnap.state.values["mode"] == .string("evil"))
    #expect(canonSnap.turns.count == 1)
    #expect(godSnap.turns.count == 1)
    #expect(evilSnap.turns.count == 1)
    #expect(godSnap.effectiveTurns.map(\.userMessage) == ["正史第一回合。", "God 回合。"])
    #expect(evilSnap.effectiveTurns.map(\.userMessage) == ["正史第一回合。", "邪神回合。"])

    // 模式推断
    #expect(StoryPlayMode.infer(from: context.branch) == .canon)
    #expect(StoryPlayMode.infer(from: god.branch) == .godMode)
    #expect(StoryPlayMode.infer(from: evil.branch) == .evilGod)
  }

  @Test
  func committingSameTurnIDIsIdempotent() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = makeStoryworldLibrary(root: root)
    let record = try await library.create(lorebook: lorebook(), title: "幂等测试")
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)

    let context = try await runtime.createPlaythrough(title: "幂等")
    let turnID = UUID()
    let first = try await runtime.commitTurn(
      address: context.address,
      turnID: turnID,
      userMessage: "你好",
      narrative: "你好。",
      statePatchData: Data(#"{"n":1}"#.utf8)
    )
    // 幂等重放：同一 turnID 不产生第二个事件
    let second = try await runtime.commitTurn(
      address: context.address,
      turnID: turnID,
      userMessage: "你好",
      narrative: "你好。",
      statePatchData: Data(#"{"n":1}"#.utf8)
    )
    #expect(first.id == second.id)
    let snapshot = try await runtime.load(address: context.address)
    #expect(snapshot.turns.count == 1)
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("e2e-runtime-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
