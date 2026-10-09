import Foundation

/// Nil inherits that dimension; an explicit default or empty array/text clears
/// the inherited value. No free-form answer is guessed into a typed override.
public struct PlayerTasteOverrides: Codable, Equatable, Sendable {
  public var pace: PlayerTasteProfile.Pace?
  public var style: PlayerTasteProfile.Style?
  public var detail: PlayerTasteProfile.Detail?
  public var styleIntensity: Int?
  public var avoidElements: [String]?
  public var notes: String?

  public init(pace: PlayerTasteProfile.Pace? = nil, style: PlayerTasteProfile.Style? = nil,
    detail: PlayerTasteProfile.Detail? = nil, styleIntensity: Int? = nil,
    avoidElements: [String]? = nil, notes: String? = nil) {
    self.pace = pace; self.style = style; self.detail = detail
    self.styleIntensity = styleIntensity; self.avoidElements = avoidElements; self.notes = notes
  }
  public var isEmpty: Bool { self == Self() }

  public func validated() throws -> Self {
    let value = try PlayerTasteProfile(pace: pace ?? .balanced, style: style ?? .balanced,
      detail: detail ?? .balanced, styleIntensity: styleIntensity ?? 3,
      avoidElements: avoidElements ?? [], notes: notes ?? "").validated()
    return .init(pace: pace, style: style, detail: detail, styleIntensity: styleIntensity,
      avoidElements: avoidElements == nil ? nil : value.avoidElements, notes: notes == nil ? nil : value.notes)
  }

  public func applying(to base: PlayerTasteProfile) throws -> PlayerTasteProfile {
    let base = try base.validated()
    let change = try validated()
    return try PlayerTasteProfile(pace: change.pace ?? base.pace, style: change.style ?? base.style,
      detail: change.detail ?? base.detail, styleIntensity: change.styleIntensity ?? base.styleIntensity,
      avoidElements: change.avoidElements ?? base.avoidElements, notes: change.notes ?? base.notes).validated()
  }

  public static func resolve(defaults: PlayerTasteProfile,
    commandLine: Self = .init(), job: Self = .init(), decisions: Self = .init()) throws -> PlayerTasteProfile {
    try decisions.applying(to: job.applying(to: commandLine.applying(to: defaults)))
  }
}
