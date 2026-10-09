import CharacterLibraryCore
import Foundation
import LLMProviderKit

/// 从世界书 lore 条目提取结构化角色档案草稿。
/// 纯逻辑三段式（makePrompt / parse / extract），不碰 UI 与持久化。
public enum CharacterExtractionError: Error, Equatable, LocalizedError {
  case emptyEntryContent
  case invalidModelResponse
  case noProviderConfigured

  public var errorDescription: String? {
    switch self {
    case .emptyEntryContent: "条目内容为空，无法提取角色。"
    case .invalidModelResponse: "模型返回的内容不是合法的角色档案 JSON。"
    case .noProviderConfigured: "请先在“模型设置”中添加模型。"
    }
  }
}

public struct CharacterExtractionDraft: Equatable, Sendable {
  public var name: String
  public var summary: String
  public var category: String
  public var tags: [String]
  public var appearance: String
  public var personality: String
  public var speechStyle: String
  public var background: String
  public var abilities: String
  public var notes: String
  /// 给生图模型用的中文视觉描述，阶段 3 生成证件照时直接取用
  public var promptProfile: String
  /// 来源身份（不可编辑）：从世界书条目提取时携带，入库保存为
  /// `.extracted(storyworldID:entryID:)`，保证可追溯/去重
  public var sourceStoryworldID: UUID?
  public var sourceEntryID: String?

  public init(
    name: String = "",
    summary: String = "",
    category: String = "",
    tags: [String] = [],
    appearance: String = "",
    personality: String = "",
    speechStyle: String = "",
    background: String = "",
    abilities: String = "",
    notes: String = "",
    promptProfile: String = "",
    sourceStoryworldID: UUID? = nil,
    sourceEntryID: String? = nil
  ) {
    self.name = name
    self.summary = summary
    self.category = category
    self.tags = tags
    self.appearance = appearance
    self.personality = personality
    self.speechStyle = speechStyle
    self.background = background
    self.abilities = abilities
    self.notes = notes
    self.promptProfile = promptProfile
    self.sourceStoryworldID = sourceStoryworldID
    self.sourceEntryID = sourceEntryID
  }
}

public enum CharacterExtractionService {
  public static func makePrompt(
    entryTitle: String,
    entryContent: String,
    sourceTitle: String
  ) -> LLMRequest {
    let system = """
      你是角色档案整理助手。把小说设定条目整理成结构化角色档案。
      只输出一个 JSON 对象，不要 markdown 围栏，不要输出任何额外文字。
      """
    let user = """
      来源世界书：\(sourceTitle)
      条目标题：\(entryTitle)

      条目正文：
      \(entryContent)

      请输出 JSON 对象，键如下：
      - name: 角色名
      - summary: 一句话简介
      - category: 简短中文分类（如 主角、配角、反派）
      - tags: 1 到 4 个短标签组成的字符串数组
      - appearance: 外貌
      - personality: 性格
      - speech_style: 语言风格、口癖
      - background: 背景经历
      - abilities: 能力与身份
      - notes: 其他备注
      - prompt_profile: 给生图模型用的中文视觉描述（外貌、气质、服装，80 字以内，不含剧情）

      规则：忠实条目原文，条目没有的信息留空字符串；不要编造。
      """
    return LLMRequest(
      requestID: UUID(),
      messages: [
        LLMMessage(role: .system, content: system),
        LLMMessage(role: .user, content: user),
      ],
      responseContract: LLMResponseContract(mode: .jsonObject)
    )
  }

  /// 容错解析：去围栏、截取首个 { 到末个 }，缺失字段留空
  public static func parse(from text: String) throws -> CharacterExtractionDraft {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
      trimmed = trimmed.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let start = trimmed.firstIndex(of: "{"),
      let end = trimmed.lastIndex(of: "}"),
      start <= end
    else { throw CharacterExtractionError.invalidModelResponse }
    let payload = String(trimmed[start...end])
    guard let data = payload.data(using: .utf8) else {
      throw CharacterExtractionError.invalidModelResponse
    }
    do {
      return try JSONDecoder().decode(Payload.self, from: data).draft
    } catch {
      throw CharacterExtractionError.invalidModelResponse
    }
  }

  public static func extract(
    entryTitle: String,
    entryContent: String,
    sourceTitle: String,
    provider: any LLMProvider
  ) async throws -> CharacterExtractionDraft {
    guard !entryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CharacterExtractionError.emptyEntryContent
    }
    let request = makePrompt(
      entryTitle: entryTitle,
      entryContent: entryContent,
      sourceTitle: sourceTitle
    )
    var text = ""
    for try await event in provider.stream(request) {
      try Task.checkCancellation()
      if case .textDelta(let delta) = event { text += delta }
    }
    return try parse(from: text)
  }

  /// 所有字段缺失时留空，容忍模型少给键
  private struct Payload: Decodable {
    var name: String?
    var summary: String?
    var category: String?
    var tags: [String]?
    var appearance: String?
    var personality: String?
    var speechStyle: String?
    var background: String?
    var abilities: String?
    var notes: String?
    var promptProfile: String?

    enum CodingKeys: String, CodingKey {
      case name, summary, category, tags, appearance, personality, background, abilities, notes
      case speechStyle = "speech_style"
      case promptProfile = "prompt_profile"
    }

    var draft: CharacterExtractionDraft {
      CharacterExtractionDraft(
        name: name ?? "",
        summary: summary ?? "",
        category: category ?? "",
        tags: tags ?? [],
        appearance: appearance ?? "",
        personality: personality ?? "",
        speechStyle: speechStyle ?? "",
        background: background ?? "",
        abilities: abilities ?? "",
        notes: notes ?? "",
        promptProfile: promptProfile ?? ""
      )
    }
  }
}
