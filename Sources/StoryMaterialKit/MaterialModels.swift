import Foundation

public enum MaterialGenre: String, Codable, CaseIterable, Sendable {
  case dushi, gufeng, kehuan, lishi, wuxia
  case wuxianliu, xianxia, xiaoyuan, xihuan, xuanyi
}

public enum EndingArchetype: String, Codable, CaseIterable, Sendable {
  case chengong, beiju, jiliu, heihua, zhongpan
  case pingdan, kaifang, lunhui, xianji, guajia
}

public enum EndingForm: String, Codable, CaseIterable, Sendable {
  case panci, jintishi, cipai, modern, prose
}

public enum ChoiceScene: String, Codable, CaseIterable, Sendable {
  case duizhi, tansuo, gaobai, taowang, liangnan, shenfen
  case tanpan, xinren, fuchou, xisheng, zhenxiang, lichang
}

public enum StatDimension: String, Codable, CaseIterable, Sendable {
  case choicesMade = "choices_made"
  case turns, friends, enemies, money, fame, power, romances, betrayals
  case deaths, saves, kills, places, secrets, regrets, risks, retreats
  case twists, nights, days
}

public enum StatTone: String, Codable, CaseIterable, Sendable {
  case epic, gentle, playful, cold
}

public enum ProseStage: String, Codable, CaseIterable, Sendable {
  case opening, climax
}

public enum RoleKind: String, Codable, CaseIterable, Sendable {
  case canonHero = "canon_hero"
  case canonSide = "canon_side"
  case original
}

public protocol MaterialSampleItem: Sendable {
  var id: String { get }
  var materialText: String { get }
}

public struct EndingVerdict: Codable, Equatable, Sendable, MaterialSampleItem {
  public let id: String
  public let type: String
  public let genre: MaterialGenre
  public let archetype: EndingArchetype
  public let form: EndingForm
  public let formDetail: String
  public let emotion: String
  public let text: String
  public let tension: String
  public let chars: Int

  public var materialText: String { text }

  private enum CodingKeys: String, CodingKey {
    case id, type, genre, archetype, form, emotion, text, tension, chars
    case formDetail = "form_detail"
  }
}

public struct ChoiceMaterial: Codable, Equatable, Sendable, MaterialSampleItem {
  public let id: String
  public let type: String
  public let scene: ChoiceScene
  public let genre: MaterialGenre
  public let text: String
  public let tension: String
  public let stakes: String
  public let chars: Int

  public var materialText: String { text }
}

public struct ProseSample: Codable, Equatable, Sendable, MaterialSampleItem {
  public let id: String
  public let type: String
  public let genre: MaterialGenre
  public let stage: ProseStage
  public let text: String
  public let chars: Int

  public var materialText: String { text }
}

public struct RolePitch: Codable, Equatable, Sendable, MaterialSampleItem {
  public let id: String
  public let type: String
  public let genre: MaterialGenre
  public let roleKind: RoleKind
  public let text: String
  public let chars: Int

  public var materialText: String { text }

  private enum CodingKeys: String, CodingKey {
    case id, type, genre, text, chars
    case roleKind = "role_kind"
  }
}

public struct StatTemplate: Codable, Equatable, Sendable, MaterialSampleItem {
  public let id: String
  public let dimension: StatDimension
  public let tone: StatTone
  public let template: String
  public let slot: String

  public var materialText: String { template }

  public func rendered(number: Int) -> String {
    template.replacingOccurrences(of: "{n}", with: String(number))
  }
}

public struct MaterialManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let materialVersion: String
  public let compiledAt: String
  public let compilerVersion: String
  public let packageCounts: [String: Int]
  public let sourceSHA256: [String: String]
  public let shards: [String: [String: Int]]
  public let warnings: [String]

  private enum CodingKeys: String, CodingKey {
    case warnings, shards
    case schemaVersion = "schema_version"
    case materialVersion = "material_version"
    case compiledAt = "compiled_at"
    case compilerVersion = "compiler_version"
    case packageCounts = "package_counts"
    case sourceSHA256 = "source_sha256"
  }
}
