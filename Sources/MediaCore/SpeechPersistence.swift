import Foundation

public enum SpeechPersistenceError: Error, LocalizedError {
  case missingPlan(String)

  public var errorDescription: String? {
    switch self {
    case .missingPlan(let id):
      "没有找到朗读计划：\(id)"
    }
  }
}

public actor SpeechPlanStore {
  public static var defaultRootURL: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("MediaCache", isDirectory: true)
      .appendingPathComponent("SpeechPlans", isDirectory: true)
  }

  private let rootURL: URL
  private let fileManager: FileManager

  public init(rootURL: URL = SpeechPlanStore.defaultRootURL, fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  public func save(_ plan: SpeechPlan) throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try encoder.encode(plan).write(
      to: rootURL.appendingPathComponent(plan.id + ".json"),
      options: [.atomic]
    )
  }

  public func load(id: String) throws -> SpeechPlan {
    let url = rootURL.appendingPathComponent(id + ".json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw SpeechPersistenceError.missingPlan(id)
    }
    return try decoder.decode(SpeechPlan.self, from: Data(contentsOf: url))
  }

  public func removeAll() throws {
    guard fileManager.fileExists(atPath: rootURL.path) else { return }
    try fileManager.removeItem(at: rootURL)
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private var decoder: JSONDecoder {
    JSONDecoder()
  }
}

public actor SpeechPlaybackStore {
  private struct State: Codable {
    var locations: [String: SpeechPlaybackLocation]
  }

  private let fileURL: URL
  private let fileManager: FileManager

  public init(rootURL: URL = SpeechPlanStore.defaultRootURL, fileManager: FileManager = .default) {
    fileURL = rootURL.deletingLastPathComponent().appendingPathComponent("speech-playback.json")
    self.fileManager = fileManager
  }

  public func save(_ location: SpeechPlaybackLocation) throws {
    var state = try loadState()
    var value = location
    value.updatedAt = Date()
    state.locations[location.sourceID] = value
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(state).write(to: fileURL, options: [.atomic])
  }

  public func load(sourceID: String, contentHash: String) throws -> SpeechPlaybackLocation? {
    guard let value = try loadState().locations[sourceID],
      value.sourceContentHash == contentHash
    else { return nil }
    return value
  }

  private func loadState() throws -> State {
    guard fileManager.fileExists(atPath: fileURL.path) else { return State(locations: [:]) }
    return try decoder.decode(State.self, from: Data(contentsOf: fileURL))
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private var decoder: JSONDecoder {
    JSONDecoder()
  }
}
