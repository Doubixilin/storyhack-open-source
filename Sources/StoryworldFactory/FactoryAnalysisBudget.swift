import Foundation
import LLMProviderKit

enum FactoryAnalysisBudgetError: Error, LocalizedError {
  case invalidConfiguration
  case inputTooLarge
  case outputTooSmall
  case repairTooLarge

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "工坊模型窗口或输出上限无效，请在模型设置中调整。"
    case .inputTooLarge: "工坊请求的固定要求或单个字符已超过模型输入预算，请增大模型窗口或降低输出上限。"
    case .outputTooSmall: "章节标识与摘要已超过工坊输出预算，请提高模型输出上限。"
    case .repairTooLarge: "已完成的回复超过格式修复输入预算，已停止自动发送；请调整模型窗口或输出上限后继续。"
    }
  }
}

/// The same conservative estimate used by gameplay. Window/output/protocol
/// overhead are all reserved before any source text or optional context is packed.
struct FactoryAnalysisBudget: Sendable {
  let window: Int
  let output: Int
  var inputLimit: Int { window - output - max(512, window / 20) }
  var diversityLimit: Int { min(1_024, inputLimit / 12) }

  init(profile: ProviderProfile) throws {
    window = profile.capabilities.contextWindow ?? 32_768
    output = profile.maximumOutputTokens ?? 4_096
    guard (2_048...2_000_000).contains(window), (512...65_536).contains(output),
      output < window - max(512, window / 20) else {
      throw FactoryAnalysisBudgetError.invalidConfiguration
    }
  }

  func inputTokens(system: String, prompt: String) -> Int {
    LLMTokenEstimate.tokens(system) + LLMTokenEstimate.tokens(prompt) + 64
  }

  func fits(system: String, prompt: String, reserve: Int = 0) -> Bool {
    inputTokens(system: system, prompt: prompt) <= inputLimit - reserve
  }

  func validate(system: String, prompt: String) throws {
    guard fits(system: system, prompt: prompt) else { throw FactoryAnalysisBudgetError.inputTooLarge }
  }

  // Stable pessimistic counters avoid planning depending on later batch counts.
  // Individual chapters can have at most 10,000 segments (plotline contract).
  func planningPrompt(_ batch: [FactoryChapterText]) -> String {
    FactoryAnalysisPrompts.makeBatchPrompt(batch: batch, batchIndex: 99_999_998,
      batchCount: 99_999_999, maximumOutputTokens: output)
  }

  func plan(_ chapters: [FactoryChapterText], maximumUTF16Length: Int) throws -> FactoryAnalysisPlan {
    var units: [FactoryChapterText] = []
    var empty: Set<String> = []
    var splitChapters = 0
    var splitUnits = 0
    for chapter in chapters {
      guard !chapter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        empty.insert(chapter.descriptor.id)
        continue
      }
      if chapter.text.utf16.count <= maximumUTF16Length,
        fits(system: FactoryAnalysisPrompts.analysisSystem, prompt: planningPrompt([chapter]), reserve: diversityLimit) {
        units.append(chapter)
        continue
      }
      let header = FactoryChapterText(descriptor: chapter.descriptor,
        analysisID: chapter.descriptor.id + "#segment-10000", text: "", fullText: chapter.fullText,
        utf16Offset: 0, segmentIndex: 10_000, segmentCount: 10_000)
      let textLimit = inputLimit - diversityLimit
        - inputTokens(system: FactoryAnalysisPrompts.analysisSystem, prompt: planningPrompt([header]))
      guard textLimit > 0 else { throw FactoryAnalysisBudgetError.inputTooLarge }
      let parts = try split(chapter.text, tokens: textLimit, utf16: maximumUTF16Length)
      guard parts.count <= 10_000 else { throw FactoryAnalysisBudgetError.inputTooLarge }
      splitChapters += parts.count > 1 ? 1 : 0
      splitUnits += parts.count > 1 ? parts.count : 0
      for (index, part) in parts.enumerated() {
        units.append(.init(descriptor: chapter.descriptor,
          analysisID: parts.count == 1 ? chapter.descriptor.id
            : chapter.descriptor.id + "#segment-" + String(format: "%04d", index + 1),
          text: part.text, fullText: chapter.fullText, utf16Offset: part.offset,
          segmentIndex: index + 1, segmentCount: parts.count))
      }
    }
    var warnings: [String] = []
    if !empty.isEmpty { warnings.append("检测到 \(empty.count) 个空章节，已按无正文内容跳过。") }
    if splitChapters > 0 {
      warnings.append("按完整请求预算将 \(splitChapters) 个长章节拆为 \(splitUnits) 个分析段；原文锚点保持不变。")
    }
    return .init(units: units, automaticallyCoveredChapterIDs: empty, warnings: warnings)
  }

  func batches(_ units: [FactoryChapterText], maximumUTF16Length: Int) throws -> [[FactoryChapterText]] {
    var result: [[FactoryChapterText]] = []
    var current: [FactoryChapterText] = []
    var length = 0
    for unit in units {
      guard 128 + 160 + 2 * LLMTokenEstimate.tokens(unit.analysisID) <= output - 128 else {
        throw FactoryAnalysisBudgetError.outputTooSmall
      }
      let next = current + [unit]
      // Reserve output space for every chapter id and a 60-character summary.
      // Remaining output goes to a smaller number of evidence-backed candidates.
      let summaryTokens = 128 + next.reduce(0) { $0 + 160 + 2 * LLMTokenEstimate.tokens($1.analysisID) }
      if !current.isEmpty && (length + unit.text.utf16.count > maximumUTF16Length
        || summaryTokens > output - 128
        || !fits(system: FactoryAnalysisPrompts.analysisSystem, prompt: planningPrompt(next), reserve: diversityLimit)) {
        result.append(current)
        current = []
        length = 0
      }
      guard fits(system: FactoryAnalysisPrompts.analysisSystem,
        prompt: planningPrompt([unit]), reserve: diversityLimit) else { throw FactoryAnalysisBudgetError.inputTooLarge }
      current.append(unit)
      length += unit.text.utf16.count
    }
    if !current.isEmpty { result.append(current) }
    guard result.count < 99_999_999 else { throw FactoryAnalysisBudgetError.inputTooLarge }
    return result
  }

  private func split(_ text: String, tokens: Int, utf16: Int) throws -> [(offset: Int, text: String)] {
    var result: [(Int, String)] = []
    var start = text.startIndex
    var offset = 0
    while start < text.endIndex {
      var end = start
      var length = 0
      var estimate = LLMTokenEstimate.Accumulator()
      var newline: (String.Index, Int)?
      while end < text.endIndex {
        let next = text.index(after: end)
        let character = text[end..<next]
        var nextEstimate = estimate
        nextEstimate.append(character)
        let n = character.utf16.count
        guard length + n <= utf16, nextEstimate.tokens <= tokens else { break }
        length += n
        estimate = nextEstimate
        end = next
        if character.contains("\n") { newline = (end, length) }
      }
      guard end > start else { throw FactoryAnalysisBudgetError.inputTooLarge }
      if end < text.endIndex, let newline, newline.1 >= length / 2 {
        end = newline.0; length = newline.1
      }
      result.append((offset, String(text[start..<end])))
      start = end
      offset += length
    }
    return result
  }
}
