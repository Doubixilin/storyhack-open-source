import Foundation

enum StoryFallbackChoices {
  /// No invented entity, possession, achievement or forced success. Cues select
  /// attempted actions only; negated/remembered scenes fall back to observation.
  static func choices(narrative: String, revealedBeat: String? = nil) -> [String] {
    let clauses = narrative.components(separatedBy: CharacterSet(charactersIn: "。！？\n；"))
    let current = clauses.suffix(8).filter { clause in
      !["没有", "并未", "不再", "未曾", "假如", "如果", "想起", "回忆", "曾经", "梦中"].contains { clause.contains($0) }
    }.joined(separator: "\n")
    func contains(_ cues: [String]) -> Bool { cues.contains { current.contains($0) } }
    let result: [String]
    if contains(["袭来", "逼近", "追赶", "坍塌", "起火", "危险"]) {
      result = ["先停下观察危险的变化，寻找可以避开的方向", "暂缓冒险，评估眼前是否还有别的办法"]
    } else if contains(["问道", "说道", "回答", "交谈", "商量", "争执"]) {
      result = ["先理清刚才的说法，再决定如何回应", "换一个问题，尝试澄清尚不确定的部分"]
    } else if contains(["线索", "字迹", "痕迹", "疑点", "信件"]) {
      result = ["重新梳理已经看到的细节，找出需要核对的地方", "暂不下结论，尝试寻找另一种解释"]
    } else if contains(["赶路", "抵达", "旅途", "渡口", "宫门", "路口", "山路"]) {
      result = ["先观察所处位置，确认下一步前进的方向", "放慢脚步，留意沿途是否有值得停下的变化"]
    } else if contains(["休息", "夜深", "睡意", "疲惫", "等待"]) {
      result = ["稍作停留，整理接下来最想完成的事情", "留意周围的变化，决定是否继续等待"]
    } else {
      result = ["先理清刚才发生的事，再决定下一步", "留意此刻能观察到的变化，暂缓作出结论"]
    }
    guard let revealedBeat, !revealedBeat.isEmpty else { return result }
    return result.map { "围绕「\(String(revealedBeat.prefix(40)))」，" + $0 }
  }
}

/// One explicit request produces one bounded passage. This does not start a background loop.
public struct StoryAdvancePlan: Sendable {
  public let targetCharacters: Int
  public init(targetCharacters: Int) { self.targetCharacters = min(2_400, max(600, targetCharacters)) }
  public var prompt: String {
    """
    请从当前进度自动推进一段，目标约 \(targetCharacters) 字，在本次回复完成；实际篇幅服从模型输出上限，不开启连续请求。
    节奏依次为：铺垫约 1/6，交代当下行动与目标；推进约 1/3，写出有因果的进展；转折约 1/3，呈现选择、发现或变化；收束约 1/6，落在可继续游玩的现场。
    四部分应各有作用，不用输出阶段标签，也不要把同一种描写重复四遍。短场景允许自然压缩，不强行制造敌人、冲突或秘密。
    只推进当前已经允许的行动；遇到需要玩家决定的重要分歧就停下并给出选项，不替玩家作不可逆决定。遵循当前在场、持有物、承诺、知情范围和角色契约。
    保持既有回复协议，末尾完整输出状态和连续性变化；不要为凑字数增加无依据的事实。
    """
  }
}
