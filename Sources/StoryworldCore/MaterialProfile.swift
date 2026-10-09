import Foundation

/// Storyworld 包内可选的素材检索配置。缺失或损坏时调用方必须按 unknown 降级。
public struct MaterialProfile: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let primaryGenre: String
  public let secondaryGenres: [String]
  public let confidence: Double
  public let source: String
  public let evidence: [String]
  public let plotSceneMap: [String: [String]]
  public let beatSceneMap: [String: [String]]

  public init(
    schemaVersion: Int = 1,
    primaryGenre: String,
    secondaryGenres: [String] = [],
    confidence: Double,
    source: String,
    evidence: [String] = [],
    plotSceneMap: [String: [String]] = [:],
    beatSceneMap: [String: [String]] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.primaryGenre = primaryGenre
    self.secondaryGenres = secondaryGenres
    self.confidence = confidence
    self.source = source
    self.evidence = evidence
    self.plotSceneMap = plotSceneMap
    self.beatSceneMap = beatSceneMap
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case primaryGenre = "primary_genre"
    case secondaryGenres = "secondary_genres"
    case confidence, source, evidence
    case plotSceneMap = "plot_scene_map"
    case beatSceneMap = "beat_scene_map"
  }
}
