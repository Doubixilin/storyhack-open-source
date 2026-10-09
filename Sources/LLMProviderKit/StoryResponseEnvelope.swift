import Foundation
import OSLog

public enum StoryStatePatchStatus: Sendable {
  case valid, missing, invalid
}

public struct StoryResponseEnvelope: Equatable, Sendable {
  public let narrative: String
  public let statePatchData: Data
  public let recoveryWarnings: [String]
  /// 给玩家的下一步行动选项。顺序约定：第一项贴近原著主线，第二项为创新方向。
  public let choices: [String]
  /// 导演协议判定的当前原著节拍 ID；可选，nil 表示未给出
  public let beatID: String?
  /// 导演协议判定的当前原著主线节点 ID（plotline.json）；可选，nil 表示未给出
  public let plotNodeID: String?
  public let memoryPatchData: Data?
  public let statePatchStatus: StoryStatePatchStatus

  public init(
    narrative: String,
    statePatchData: Data,
    recoveryWarnings: [String] = [],
    choices: [String] = [],
    beatID: String? = nil,
    plotNodeID: String? = nil,
    memoryPatchData: Data? = nil,
    statePatchStatus: StoryStatePatchStatus = .valid
  ) {
    self.narrative = narrative
    self.statePatchData = statePatchData
    self.recoveryWarnings = recoveryWarnings
    self.choices = choices
    self.beatID = beatID
    self.plotNodeID = plotNodeID
    self.memoryPatchData = memoryPatchData
    self.statePatchStatus = statePatchStatus
  }
}

public enum StoryResponseEnvelopeError: Error, Equatable, LocalizedError {
  case missingNarrative
  case missingStatePatch
  case invalidStatePatch
  case responseTooLarge

  public var errorDescription: String? {
    switch self {
    case .missingNarrative:
      "模型回复缺少 <STORY> 叙事段"
    case .missingStatePatch:
      "模型回复缺少 <STATE_PATCH> 状态补丁"
    case .invalidStatePatch:
      "模型回复中的状态补丁不是 JSON 对象"
    case .responseTooLarge:
      "模型回复超过 2 MB 安全限制"
    }
  }
}

public enum StoryResponseEnvelopeParser {
  public static let maximumResponseByteCount = 2 * 1_024 * 1_024
  // Some compatible providers emit textual tool serialization in content.
  // Treat its first marker as a boundary: stripping only tags would expose
  // tool names/arguments as prose. Never interpret these strings as tool calls.
  private static let toolProtocolPrefixes = ["｜｜DSML｜｜", "｜DSML｜", "||DSML||", "|DSML|"]
    .flatMap { ["<" + $0, "</" + $0] }
  private static let toolProtocolWarning = "模型正文混入工具协议；已保留协议前的叙事，后续内容未作为正文保存，请核对完整性。"
  private static let logger = Logger(
    subsystem: "org.doubixilin.storyhack.community",
    category: "StoryResponseEnvelope"
  )

  public static func parse(_ response: String) throws -> StoryResponseEnvelope {
    guard response.utf8.count <= maximumResponseByteCount else {
      throw StoryResponseEnvelopeError.responseTooLarge
    }
    guard let rawNarrative = contents(of: "STORY", in: response) else {
      throw StoryResponseEnvelopeError.missingNarrative
    }
    let narrative = narrativeBeforeToolProtocol(rawNarrative).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !narrative.isEmpty else {
      throw StoryResponseEnvelopeError.missingNarrative
    }
    guard let rawPatch = contents(of: "STATE_PATCH", in: response)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawPatch.isEmpty
    else {
      throw StoryResponseEnvelopeError.missingStatePatch
    }
    let data = Data(rawPatch.utf8)
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw StoryResponseEnvelopeError.invalidStatePatch
    }
    guard object is [String: Any] else {
      throw StoryResponseEnvelopeError.invalidStatePatch
    }
    return StoryResponseEnvelope(
      narrative: narrative,
      statePatchData: data,
      recoveryWarnings: toolProtocolRange(in: rawNarrative) == nil ? [] : [toolProtocolWarning],
      choices: parsedChoices(in: response),
      beatID: normalizedTagID(contents(of: "BEAT", in: response)),
      plotNodeID: normalizedTagID(contents(of: "PLOT", in: response)),
      memoryPatchData: contents(of: "MEMORY_PATCH", in: response).map { Data($0.utf8) }
    )
  }

  /// Recovers a readable turn when the model returns useful narrative but misses
  /// the lightweight envelope contract. Invalid or missing state patches are
  /// never applied; the narrative is committed with an empty patch and a warning.
  public static func parseRecovering(_ response: String) throws -> StoryResponseEnvelope {
    do {
      return try parse(response)
    } catch StoryResponseEnvelopeError.responseTooLarge {
      throw StoryResponseEnvelopeError.responseTooLarge
    } catch {
      guard response.utf8.count <= maximumResponseByteCount else {
        throw StoryResponseEnvelopeError.responseTooLarge
      }
    }

    let rawNarrative = recoverableNarrative(from: response)
    let narrative = narrativeBeforeToolProtocol(rawNarrative)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !narrative.isEmpty, !isJSONOnly(narrative) else {
      throw StoryResponseEnvelopeError.missingNarrative
    }

    var warnings: [String] = toolProtocolRange(in: rawNarrative) == nil ? [] : [toolProtocolWarning]
    if contents(of: "STORY", in: response) == nil {
      logger.debug("模型未按约定包装 <STORY>；已按容错路径恢复叙事。")
    }

    let patchData: Data
    let patchStatus: StoryStatePatchStatus
    if let rawPatch = contents(of: "STATE_PATCH", in: response)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let data = validObjectData(rawPatch)
    {
      patchData = data
      patchStatus = .valid
    } else {
      patchData = Data("{}".utf8)
      if response.contains("<STATE_PATCH>") {
        patchStatus = .invalid
        warnings.append("模型状态补丁无效；本轮叙事已保存，但未应用状态变化。")
      } else {
        patchStatus = .missing
        warnings.append("模型未提供状态补丁；本轮叙事已保存，状态保持不变。")
      }
    }
    return StoryResponseEnvelope(
      narrative: narrative,
      statePatchData: patchData,
      recoveryWarnings: warnings,
      choices: parsedChoices(in: response),
      beatID: normalizedTagID(contents(of: "BEAT", in: response)),
      plotNodeID: normalizedTagID(contents(of: "PLOT", in: response)),
      memoryPatchData: contents(of: "MEMORY_PATCH", in: response).map { Data($0.utf8) },
      statePatchStatus: patchStatus
    )
  }

  /// Best-effort text for the streaming UI. Persistence later uses
  /// `parseRecovering`, so readable prose stays consistent with what was shown.
  public static func visibleNarrative(from partialResponse: String) -> String {
    let narrative = narrativeBeforeToolProtocol(recoverableNarrative(from: partialResponse))
    // Once STORY is closed the suffix is literal prose, not a split tag.
    if contents(of: "STORY", in: partialResponse) != nil { return narrative }
    if let start = narrative.lastIndex(of: "<") {
      let suffix = narrative[start...]
      let prefixes = toolProtocolPrefixes + ["<STORY>", "</STORY>", "<CHOICES>", "<STATE_PATCH>", "<BEAT>", "<PLOT>", "<MEMORY_PATCH>"]
      if prefixes.contains(where: { $0.hasPrefix(suffix) }) {
        return String(narrative[..<start])
      }
    }
    return narrative
  }

  private static func toolProtocolRange(in text: String) -> Range<String.Index>? {
    toolProtocolPrefixes.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
  }

  private static func narrativeBeforeToolProtocol(_ text: String) -> String {
    guard let range = toolProtocolRange(in: text) else { return text }
    return String(text[..<range.lowerBound])
  }

  private static func contents(of tag: String, in response: String) -> String? {
    guard let start = response.range(of: "<\(tag)>") else { return nil }
    let remainder = response[start.upperBound...]
    guard let end = remainder.range(of: "</\(tag)>") else { return nil }
    return String(remainder[..<end.lowerBound])
  }

  /// CHOICES 是非阻断增强契约：格式不对时只丢弃选项，不能撤回可读叙事。
  /// 接受 2–4 个字符串；去掉空项和重复项，限制单项长度以免撑爆界面。
  public static func parsedChoices(in response: String) -> [String] {
    guard let raw = contents(of: "CHOICES", in: response),
      let data = raw.data(using: .utf8),
      let values = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    var seen = Set<String>()
    let choices = values.compactMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let bounded = String(trimmed.prefix(120))
      guard seen.insert(bounded).inserted else { return nil }
      return bounded
    }
    guard choices.count >= 2 else { return [] }
    return Array(choices.prefix(4))
  }

  /// 空值与 none 都视为「未给出」（BEAT/PLOT 共用）
  private static func normalizedTagID(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
    return trimmed
  }

  private static func recoverableNarrative(from response: String) -> String {
    if let start = response.range(of: "<STORY>") {
      let remainder = response[start.upperBound...]
      if let end = remainder.range(of: "</STORY>") {
        return String(remainder[..<end.lowerBound])
      }
      if let protocolStart = firstProtocolTagRange(in: remainder) {
        return String(remainder[..<protocolStart.lowerBound])
      }
      return String(remainder)
    }
    if let protocolStart = firstProtocolTagRange(in: response[...]) {
      return String(response[..<protocolStart.lowerBound])
    }
    return response
  }

  private static func firstProtocolTagRange(
    in text: Substring
  ) -> Range<Substring.Index>? {
    ["<CHOICES>", "<STATE_PATCH>", "<BEAT>", "<PLOT>", "<MEMORY_PATCH>"]
      .compactMap { text.range(of: $0) }
      .min { $0.lowerBound < $1.lowerBound }
  }

  private static func validObjectData(_ rawPatch: String) -> Data? {
    let data = Data(rawPatch.utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any]
    else { return nil }
    return data
  }

  private static func isJSONOnly(_ value: String) -> Bool {
    guard let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return false }
    return object is [String: Any] || object is [Any]
  }
}
