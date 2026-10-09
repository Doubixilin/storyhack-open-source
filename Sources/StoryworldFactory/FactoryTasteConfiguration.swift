import Foundation
import StoryworldCore

public struct FactoryTasteConfiguration: Codable, Equatable, Sendable {
  public let revision: UUID
  public let overrides: PlayerTasteOverrides
  public init(overrides: PlayerTasteOverrides) throws {
    self.revision = UUID(); self.overrides = try overrides.validated()
  }
}

/// Captures the exact task editor target and the lower-priority defaults shown
/// to the user. Inherited values are recalculated when generating, not copied
/// into overrides by merely opening the editor.
public struct FactoryTasteSettings: Sendable {
  public let jobID: UUID
  public let configuration: FactoryTasteConfiguration?
  public let inherited: PlayerTasteProfile
  public var overrides: PlayerTasteOverrides { configuration?.overrides ?? .init() }
  public var effective: PlayerTasteProfile { get throws { try overrides.applying(to: inherited) } }
}
