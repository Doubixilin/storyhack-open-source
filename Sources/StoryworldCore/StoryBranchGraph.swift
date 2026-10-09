import Foundation

/// 一条游玩线的分支图快照：把分支、分叉点、存档整理成可按泳道布局的只读模型。
/// 横轴是绝对事件序号——根分支从 0 开始，子分支的绝对位置 = 父链分叉点累加 +
/// 自身事件序号，因此不同泳道上的节点可以放在同一条时间轴上比较。
public struct StoryBranchGraph: Equatable, Sendable {
  public struct SaveMarker: Equatable, Sendable, Identifiable {
    public let save: StorySave
    public let absoluteSequence: Int

    public var id: UUID { save.id }

    public init(save: StorySave, absoluteSequence: Int) {
      self.save = save
      self.absoluteSequence = absoluteSequence
    }
  }

  public struct TurnMarker: Equatable, Sendable, Identifiable {
    public let turnID: UUID
    /// 分支内事件序号
    public let sequence: Int
    public let absoluteSequence: Int
    /// 玩家输入首行截断，供节点提示与操作卡展示
    public let preview: String
    /// 该回合判定到的原著节拍；nil 表示不在任何已知节拍上
    public let beatID: String?

    public var id: UUID { turnID }

    public init(
      turnID: UUID,
      sequence: Int,
      absoluteSequence: Int,
      preview: String,
      beatID: String? = nil
    ) {
      self.turnID = turnID
      self.sequence = sequence
      self.absoluteSequence = absoluteSequence
      self.preview = preview
      self.beatID = beatID
    }
  }

  public struct Node: Equatable, Sendable, Identifiable {
    /// 与 branchID 相同
    public let id: UUID
    public let sessionID: UUID
    public let title: String
    public let parentBranchID: UUID?
    /// 泳道行号，根分支为 0
    public let lane: Int
    /// 分叉点的绝对事件序号，根分支为 0
    public let startAbsoluteSequence: Int
    /// 本分支自己提交过的事件数
    public let headEventSequence: Int
    public let createdAt: Date
    public let isActive: Bool
    /// 是否位于「当前分支 + 其祖先链」上
    public let isOnActivePath: Bool
    public let saves: [SaveMarker]
    public let turns: [TurnMarker]

    /// 分支头的绝对事件序号
    public var endAbsoluteSequence: Int { startAbsoluteSequence + headEventSequence }

    public init(
      id: UUID,
      sessionID: UUID,
      title: String,
      parentBranchID: UUID?,
      lane: Int,
      startAbsoluteSequence: Int,
      headEventSequence: Int,
      createdAt: Date,
      isActive: Bool,
      isOnActivePath: Bool,
      saves: [SaveMarker],
      turns: [TurnMarker]
    ) {
      self.id = id
      self.sessionID = sessionID
      self.title = title
      self.parentBranchID = parentBranchID
      self.lane = lane
      self.startAbsoluteSequence = startAbsoluteSequence
      self.headEventSequence = headEventSequence
      self.createdAt = createdAt
      self.isActive = isActive
      self.isOnActivePath = isOnActivePath
      self.saves = saves
      self.turns = turns
    }
  }

  public let playthroughID: UUID
  public let playthroughTitle: String
  public let activeBranchID: UUID?
  /// 按泳道顺序排列的节点
  public let nodes: [Node]
  /// 原著节拍线；nil 时图退化为纯游玩历史
  public let timeline: StoryTimeline?

  public var maxAbsoluteSequence: Int {
    nodes.map(\.endAbsoluteSequence).max() ?? 0
  }

  /// 当前路径（活跃分支 + 祖先链）已经到达的节拍
  public var reachedBeatIDsOnActivePath: Set<String> {
    Set(nodes.filter(\.isOnActivePath).flatMap { $0.turns.compactMap(\.beatID) })
  }

  public init(
    playthrough: PlaythroughDescriptor,
    branches: [RuntimeBranchDescriptor],
    headSequences: [UUID: Int],
    saves: [UUID: [StorySave]],
    turns: [UUID: [CommittedStoryTurn]] = [:],
    timeline: StoryTimeline? = nil
  ) {
    playthroughID = playthrough.id
    playthroughTitle = playthrough.title
    activeBranchID = playthrough.activeBranchID
    self.timeline = timeline

    let knownIDs = Set(branches.map(\.id))
    var childrenOf: [UUID: [RuntimeBranchDescriptor]] = [:]
    var roots: [RuntimeBranchDescriptor] = []
    for branch in branches {
      if let parentID = branch.branch.parentBranchID, knownIDs.contains(parentID) {
        childrenOf[parentID, default: []].append(branch)
      } else {
        roots.append(branch)
      }
    }
    let childOrder: (RuntimeBranchDescriptor, RuntimeBranchDescriptor) -> Bool = { lhs, rhs in
      let l = lhs.branch.forkedAtEventSequence ?? 0
      let r = rhs.branch.forkedAtEventSequence ?? 0
      return l == r ? lhs.branch.createdAt < rhs.branch.createdAt : l < r
    }
    roots.sort { $0.branch.createdAt < $1.branch.createdAt }

    // 当前路径：活跃分支及其全部祖先
    let byID = Dictionary(uniqueKeysWithValues: branches.map { ($0.id, $0) })
    var activePath = Set<UUID>()
    var cursor = playthrough.activeBranchID
    while let current = byID[cursor] {
      activePath.insert(current.id)
      guard let parent = current.branch.parentBranchID else { break }
      cursor = parent
    }

    var ordered: [Node] = []
    var nextLane = 0
    func visit(_ branch: RuntimeBranchDescriptor, startAbsolute: Int) {
      let lane = nextLane
      nextLane += 1
      let head = headSequences[branch.id] ?? 0
      let markers = (saves[branch.id] ?? [])
        .map { SaveMarker(save: $0, absoluteSequence: startAbsolute + $0.eventSequence) }
        .sorted { $0.absoluteSequence < $1.absoluteSequence }
      let turnMarkers = (turns[branch.id] ?? []).map {
        TurnMarker(
          turnID: $0.turnID,
          sequence: $0.sequence,
          absoluteSequence: startAbsolute + $0.sequence,
          preview: Self.preview(of: $0.userMessage),
          beatID: $0.beatID
        )
      }
      ordered.append(
        Node(
          id: branch.id,
          sessionID: branch.sessionID,
          title: StoryPlayMode.infer(from: branch)?.displayName ?? branch.branch.title,
          parentBranchID: branch.branch.parentBranchID,
          lane: lane,
          startAbsoluteSequence: startAbsolute,
          headEventSequence: head,
          createdAt: branch.branch.createdAt,
          isActive: branch.id == playthrough.activeBranchID,
          isOnActivePath: activePath.contains(branch.id),
          saves: markers,
          turns: turnMarkers
        )
      )
      for child in childrenOf[branch.id, default: []].sorted(by: childOrder) {
        visit(child, startAbsolute: startAbsolute + (child.branch.forkedAtEventSequence ?? 0))
      }
    }
    for root in roots {
      visit(root, startAbsolute: 0)
    }
    nodes = ordered
  }

  public func node(branchID: UUID) -> Node? {
    nodes.first { $0.id == branchID }
  }

  private static func preview(of userMessage: String) -> String {
    // 系统指令回合（如自动开场白）不展示指令原文
    if userMessage.hasPrefix("（系统指令：") { return "（开场）" }
    let line = userMessage.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
  }
}
