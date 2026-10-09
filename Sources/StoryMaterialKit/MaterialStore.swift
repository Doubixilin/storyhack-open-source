import Foundation
import OSLog

public actor MaterialStore {
  public static let shared = MaterialStore()

  private enum ManifestState {
    case unloaded
    case loaded(MaterialManifest)
    case failed
  }

  private static let logger = Logger(
    subsystem: "org.doubixilin.storyhack.community",
    category: "StoryMaterialKit"
  )

  private let resourceRoot: URL
  private let decoder = JSONDecoder()
  private var manifestState = ManifestState.unloaded
  private var choiceCache: [String: [String: [ChoiceMaterial]]] = [:]
  private var endingCache: [String: [EndingVerdict]] = [:]
  private var proseCache: [String: [ProseSample]] = [:]
  private var roleCache: [String: [RolePitch]] = [:]
  private var statCache: [StatTemplate]?
  private var recentMaterialIDsByContext: [RecentContext: [String]] = [:]
  private var selectionHistoryByContext: [RecentContext: [MaterialSelection]] = [:]

  /// 优先使用 App 内资源；SwiftPM 开发与测试回退到模块资源。
  public nonisolated static var defaultResourceRoot: URL {
    if let resources = Bundle.main.resourceURL,
      let bundle = Bundle(url: resources.appendingPathComponent("WorldbookApp_StoryMaterialKit.bundle")),
      let root = bundle.resourceURL
    {
      return root.appendingPathComponent("materials-v1", isDirectory: true)
    }
    return Bundle.module.resourceURL!.appendingPathComponent("materials-v1", isDirectory: true)
  }

  public init(resourceRoot: URL? = nil) {
    self.resourceRoot = resourceRoot
      ?? Self.defaultResourceRoot
  }

  public func manifest() -> MaterialManifest? {
    loadManifest()
  }

  public func choices(genre: MaterialGenre, scene: ChoiceScene) -> [ChoiceMaterial] {
    choices(genre: genre.rawValue, scene: scene.rawValue)
  }

  public func choices(genre: String, scene: String) -> [ChoiceMaterial] {
    guard MaterialGenre(rawValue: genre) != nil, ChoiceScene(rawValue: scene) != nil else {
      Self.log("Unknown choices lookup key genre=\(genre) scene=\(scene)")
      return []
    }
    if let cached = choiceCache[genre] {
      return cached[scene] ?? []
    }
    guard let items: [ChoiceMaterial] = loadShard(kind: "choices", genre: genre) else {
      choiceCache[genre] = [:]
      return []
    }
    let byScene = Dictionary(grouping: items, by: { $0.scene.rawValue })
    choiceCache[genre] = byScene
    return byScene[scene] ?? []
  }

  public func statTemplates(dimension: StatDimension, tone: StatTone) -> [StatTemplate] {
    statTemplates(dimension: dimension.rawValue, tone: tone.rawValue)
  }

  public func statTemplates(dimension: String, tone: String) -> [StatTemplate] {
    guard let dimension = StatDimension(rawValue: dimension),
      let tone = StatTone(rawValue: tone)
    else {
      Self.log("Unknown stats lookup key dimension=\(dimension) tone=\(tone)")
      return []
    }
    if statCache == nil {
      statCache = loadArray(
        at: resourceRoot.appendingPathComponent("stats.json"),
        expectedCount: loadManifest()?.packageCounts["stat_templates"],
        label: "stats"
      ) ?? []
    }
    return statCache?.filter { $0.dimension == dimension && $0.tone == tone } ?? []
  }

  public func endingVerdicts(
    genre: MaterialGenre,
    archetype: EndingArchetype,
    forms: Set<EndingForm> = []
  ) -> [EndingVerdict] {
    endingVerdicts(
      genre: genre.rawValue,
      archetype: archetype.rawValue,
      forms: Set(forms.map(\.rawValue))
    )
  }

  public func endingVerdicts(
    genre: String,
    archetype: String,
    forms: Set<String> = []
  ) -> [EndingVerdict] {
    guard MaterialGenre(rawValue: genre) != nil,
      let archetype = EndingArchetype(rawValue: archetype),
      forms.allSatisfy({ EndingForm(rawValue: $0) != nil })
    else {
      Self.log("Unknown ending lookup key genre=\(genre) archetype=\(archetype)")
      return []
    }
    if endingCache[genre] == nil {
      endingCache[genre] = loadShard(kind: "ending", genre: genre) ?? []
    }
    return endingCache[genre, default: []].filter {
      $0.archetype == archetype && (forms.isEmpty || forms.contains($0.form.rawValue))
    }
  }

  public func proseSamples(genre: MaterialGenre, stage: ProseStage) -> [ProseSample] {
    proseSamples(genre: genre.rawValue, stage: stage.rawValue)
  }

  public func proseSamples(genre: String, stage: String) -> [ProseSample] {
    guard MaterialGenre(rawValue: genre) != nil, let stage = ProseStage(rawValue: stage) else {
      Self.log("Unknown prose lookup key genre=\(genre) stage=\(stage)")
      return []
    }
    if proseCache[genre] == nil {
      proseCache[genre] = loadShard(kind: "prose", genre: genre) ?? []
    }
    return proseCache[genre, default: []].filter { $0.stage == stage }
  }

  public func proseSample(genre: MaterialGenre, stage: ProseStage) -> ProseSample? {
    proseSamples(genre: genre, stage: stage).first
  }

  public func proseSample(genre: String, stage: String) -> ProseSample? {
    proseSamples(genre: genre, stage: stage).first
  }

  public func rolePitches(genre: MaterialGenre, kind: RoleKind) -> [RolePitch] {
    rolePitches(genre: genre.rawValue, kind: kind.rawValue)
  }

  public func rolePitches(genre: String, kind: String) -> [RolePitch] {
    guard MaterialGenre(rawValue: genre) != nil, let kind = RoleKind(rawValue: kind) else {
      Self.log("Unknown roles lookup key genre=\(genre) kind=\(kind)")
      return []
    }
    if roleCache[genre] == nil {
      roleCache[genre] = loadShard(kind: "roles", genre: genre) ?? []
    }
    return roleCache[genre, default: []].filter { $0.roleKind == kind }
  }

  public func sampled<Item: MaterialSampleItem>(
    _ items: [Item],
    purpose: String,
    seed: String,
    excluding: Set<String> = [],
    maxChars: Int
  ) -> [Item] {
    guard maxChars > 0 else { return [] }
    var candidates = items.filter { !excluding.contains($0.id) }
    var generator = StableRandomNumberGenerator(seed: purpose + "\u{0}" + seed)
    candidates.shuffle(using: &generator)

    var selected: [Item] = []
    var usedCharacters = 0
    for item in candidates {
      let separator = selected.isEmpty ? 0 : 1
      let nextCount = usedCharacters + separator + item.materialText.count
      guard nextCount <= maxChars else { continue }
      selected.append(item)
      usedCharacters = nextCount
    }
    return selected
  }

  public func recentMaterialIDs(
    storyworldID: UUID,
    branchID: UUID,
    purpose: String
  ) -> Set<String> {
    Set(recentMaterialIDsByContext[
      RecentContext(storyworldID: storyworldID, branchID: branchID, purpose: purpose),
      default: []
    ])
  }

  public func recordUsedMaterialIDs(
    _ ids: [String],
    storyworldID: UUID,
    branchID: UUID,
    purpose: String,
    seed: String? = nil
  ) {
    guard !ids.isEmpty else { return }
    let key = RecentContext(
      storyworldID: storyworldID,
      branchID: branchID,
      purpose: purpose
    )
    var recent = recentMaterialIDsByContext[key, default: []]
    for id in ids {
      recent.removeAll { $0 == id }
      recent.append(id)
    }
    if recent.count > 20 {
      recent.removeFirst(recent.count - 20)
    }
    recentMaterialIDsByContext[key] = recent
    if let seed {
      var history = selectionHistoryByContext[key, default: []]
      history.removeAll { $0.seed == seed }
      history.append(MaterialSelection(seed: seed, ids: ids))
      if history.count > 20 {
        history.removeFirst(history.count - 20)
      }
      selectionHistoryByContext[key] = history
    }
  }

  public func cachedMaterialIDs(
    seed: String,
    storyworldID: UUID,
    branchID: UUID,
    purpose: String
  ) -> [String]? {
    let key = RecentContext(
      storyworldID: storyworldID,
      branchID: branchID,
      purpose: purpose
    )
    return selectionHistoryByContext[key]?.last(where: { $0.seed == seed })?.ids
  }

  private func loadManifest() -> MaterialManifest? {
    switch manifestState {
    case .loaded(let manifest):
      return manifest
    case .failed:
      return nil
    case .unloaded:
      let url = resourceRoot.appendingPathComponent("manifest.json")
      guard let manifest: MaterialManifest = decode(at: url, label: "manifest"),
        manifest.schemaVersion == 1,
        manifest.materialVersion == "v1"
      else {
        manifestState = .failed
        Self.log("Material manifest missing, damaged, or unsupported")
        return nil
      }
      manifestState = .loaded(manifest)
      return manifest
    }
  }

  private func loadShard<Item: Decodable>(kind: String, genre: String) -> [Item]? {
    guard let manifest = loadManifest(),
      let expectedCount = manifest.shards[kind]?[genre]
    else {
      Self.log("Manifest summary missing for \(kind)/\(genre)")
      return nil
    }
    let url = resourceRoot
      .appendingPathComponent(kind, isDirectory: true)
      .appendingPathComponent(genre + ".json")
    return loadArray(at: url, expectedCount: expectedCount, label: "\(kind)/\(genre)")
  }

  private func loadArray<Item: Decodable>(
    at url: URL,
    expectedCount: Int?,
    label: String
  ) -> [Item]? {
    guard let expectedCount, let items: [Item] = decode(at: url, label: label) else {
      return nil
    }
    guard items.count == expectedCount else {
      Self.log("Material summary mismatch for \(label): expected \(expectedCount), decoded \(items.count)")
      return nil
    }
    return items
  }

  private func decode<Value: Decodable>(at url: URL, label: String) -> Value? {
    do {
      return try decoder.decode(Value.self, from: Data(contentsOf: url))
    } catch {
      Self.log("Failed to load \(label): \(error.localizedDescription)")
      return nil
    }
  }

  private nonisolated static func log(_ message: String) {
    logger.error("\(message, privacy: .public)")
  }
}

private struct RecentContext: Hashable, Sendable {
  let storyworldID: UUID
  let branchID: UUID
  let purpose: String
}

private struct MaterialSelection: Sendable {
  let seed: String
  let ids: [String]
}

private struct StableRandomNumberGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: String) {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in seed.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    state = hash == 0 ? 0x9E37_79B9_7F4A_7C15 : hash
  }

  mutating func next() -> UInt64 {
    state ^= state >> 12
    state ^= state << 25
    state ^= state >> 27
    return state &* 2_685_821_657_736_338_717
  }
}
