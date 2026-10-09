import Foundation

public actor PlayerTasteStore {
  public static let shared = PlayerTasteStore()
  public static var defaultRootURL: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("StoryhackCommunity/PlayerTaste", isDirectory: true)
  }
  private let rootURL: URL
  private var url: URL { rootURL.appendingPathComponent("profile.json") }
  public init(rootURL: URL = PlayerTasteStore.defaultRootURL) { self.rootURL = rootURL }

  public func load() throws -> PlayerTasteSnapshot {
    guard !linked(rootURL), !linked(url) else { throw PlayerTasteError.corruptStore }
    guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20_480,
      let snapshot = try? JSONDecoder().decode(PlayerTasteSnapshot.self, from: Data(contentsOf: url)),
      let profile = try? snapshot.profile.validated(), profile == snapshot.profile,
      snapshot.revision != nil else { throw PlayerTasteError.corruptStore }
    return snapshot
  }

  @discardableResult
  public func save(_ profile: PlayerTasteProfile, replacing expected: PlayerTasteSnapshot) throws -> PlayerTasteSnapshot {
    let profile = try profile.validated()
    let current = try load()
    if current.profile == profile { return current }
    guard current == expected else { throw PlayerTasteError.staleEdit }
    let next = PlayerTasteSnapshot(revision: UUID(), profile: profile)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try encoder.encode(next).write(to: url, options: .atomic)
    return next
  }

  private func linked(_ value: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: value.path)) != nil
  }
}
