import Foundation

public actor DirectiveProfileStore {
  public static let shared = DirectiveProfileStore()
  public static var defaultRootURL: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("StoryhackCommunity/DirectiveProfiles", isDirectory: true)
  }
  private let rootURL: URL
  private var url: URL { rootURL.appendingPathComponent("profiles.json") }
  public init(rootURL: URL = DirectiveProfileStore.defaultRootURL) { self.rootURL = rootURL }

  public func list() throws -> [DirectiveProfile] { DirectiveProfile.builtins + (try customProfiles()) }
  public func resolve(_ id: String?) throws -> DirectiveProfile {
    guard let id else { return .green }
    return try list().first { $0.id == id } ?? .green
  }
  public func save(_ profile: DirectiveProfile, replacing expected: DirectiveProfile?) throws {
    let profile = try profile.validated()
    guard !profile.isBuiltin else { throw DirectiveProfileError.readOnly }
    var profiles = try customProfiles()
    let current = profiles.first { $0.id == profile.id }
    if current == profile { return }
    guard current == expected, expected == nil || expected?.id == profile.id else { throw DirectiveProfileError.staleEdit }
    profiles.removeAll { $0.id == profile.id }
    profiles.append(profile)
    guard profiles.count <= 32 else { throw DirectiveProfileError.invalidProfile }
    try write(profiles)
  }
  public func delete(_ expected: DirectiveProfile) throws {
    guard !expected.isBuiltin else { throw DirectiveProfileError.readOnly }
    var profiles = try customProfiles()
    guard let current = profiles.first(where: { $0.id == expected.id }) else { return }
    guard current == expected else { throw DirectiveProfileError.staleEdit }
    profiles.removeAll { $0.id == expected.id }
    try write(profiles)
  }

  private func customProfiles() throws -> [DirectiveProfile] {
    // A missing catalog is the default, but a dangling link is not a missing file.
    let exists = FileManager.default.fileExists(atPath: url.path)
    let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    guard exists || linked else { return [] }
    guard !linked else { throw DirectiveProfileError.corruptStore }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 786_432,
      let profiles = try? JSONDecoder().decode([DirectiveProfile].self, from: Data(contentsOf: url)),
      profiles.count <= 32, Set(profiles.map(\.id)).count == profiles.count,
      profiles.allSatisfy({ !$0.isBuiltin && (try? $0.validated()) != nil }) else {
      throw DirectiveProfileError.corruptStore
    }
    return profiles
  }
  private func write(_ profiles: [DirectiveProfile]) throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(profiles).write(to: url, options: .atomic)
  }
}
