import Foundation

public struct CLIResult: Sendable {
  public let output: String
  public let diagnostic: String
  public let exitCode: Int32
  init(output: String = "", diagnostic: String = "", exitCode: Int32 = 0) {
    self.output = output; self.diagnostic = diagnostic; self.exitCode = exitCode
  }
}

enum CLIError: Error, LocalizedError {
  case usage, missing(String), invalid(String), readOnlyCredential, missingCredential, staleReview
  var errorDescription: String? {
    switch self {
    case .usage: "命令或参数不正确。请运行 WorldbookTaskTool --help。"
    case .missing(let name): "缺少参数：" + name
    case .invalid(let name): "参数或输入文件无效：" + name
    case .readOnlyCredential: "CLI 环境凭据只读，不写入 App 或钥匙串。"
    case .missingCredential: "请在当前 CLI 环境设置 WORLDBOOK_API_KEY。"
    case .staleReview: "审阅对象或版本已变化，请重新读取后再操作。"
    }
  }
}

struct CLIArguments: Sendable {
  let domain: String
  let command: String
  let options: [String: String]
  static let providerOptions: Set<String> = ["provider", "model", "base-url", "context-window", "output-tokens", "timeout", "concurrency"]
  static let flags: Set<String> = ["regenerate", "allow-resend", "ack-unchanged", "standalone"]
  init(_ arguments: [String]) throws {
    guard arguments.count >= 2 else { throw CLIError.usage }
    domain = arguments[0]; command = arguments[1]
    var values: [String: String] = [:], index = 2
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--"), argument.count > 2 else { throw CLIError.usage }
      let key = String(argument.dropFirst(2))
      guard values[key] == nil else { throw CLIError.usage }
      if Self.flags.contains(key) { values[key] = "true"; index += 1 }
      else {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw CLIError.usage }
        values[key] = arguments[index + 1]; index += 2
      }
    }
    let common: Set<String> = ["root"]
    let specs: [String: Set<String>]
    if domain == "adaptation" {
      specs = [
        "list": [], "import": ["source"], "original": ["source", "title", "author"],
        "status": ["job"], "source": ["job"], "config": ["job", "file"], "template": ["kind"],
        "bookcases": ["job"], "edit-bookcase": ["job", "file"], "anchors": ["job"], "add-anchor": ["job", "file", "revision"],
        "review": ["job", "file"], "contract": ["job", "variant", "file", "revision", "title", "standalone", "bookcase"],
        "extract": Self.providerOptions.union(["job", "max-requests"]),
        "scan": Self.providerOptions.union(["job", "max-requests"]),
        "write": Self.providerOptions.union(["job", "variant", "max-requests", "regenerate", "taste"]),
        "drafts": ["job", "variant", "draft"], "edit-draft": ["job", "variant", "draft", "file"],
        "assemble": ["job", "variant"], "export": ["job", "file", "ack-unchanged"],
        "publish": ["job", "file", "ack-unchanged"], "report": ["job", "variant"],
        "pending": ["job"], "acknowledge": ["job", "file", "allow-resend"]
      ]
    } else if domain == "factory" {
      specs = ["list": [], "create": ["source"], "status": ["job"], "recover": [], "pending": ["job", "kind"],
        "analyze": Self.providerOptions.union(["job", "approval", "allow-resend", "taste"]),
        "resume": Self.providerOptions.union(["job", "approval", "allow-resend", "taste"]),
        "generate": Self.providerOptions.union(["job", "approval", "allow-resend", "taste", "regenerate"]),
        "publish": ["job", "taste"], "answer": ["job", "file"],
        "taste": ["job", "file"]]
    } else { throw CLIError.usage }
    guard let allowed = specs[command], Set(values.keys).isSubset(of: common.union(allowed)) else { throw CLIError.usage }
    if values["approval"] != nil && values["allow-resend"] == nil { throw CLIError.missing("--allow-resend") }
    if values["allow-resend"] != nil && command != "acknowledge" && values["approval"] == nil { throw CLIError.missing("--approval") }
    options = values
  }
  subscript(_ name: String) -> String? { options[name] }
  func required(_ name: String) throws -> String {
    guard let value = self[name], !value.isEmpty else { throw CLIError.missing("--" + name) }
    return value
  }
  func uuid(_ name: String) throws -> UUID {
    guard let value = UUID(uuidString: try required(name)) else { throw CLIError.invalid("--" + name) }
    return value
  }
  func revision() throws -> UUID? {
    if try required("revision") == "none" { return nil }
    return try uuid("revision")
  }
  func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard let raw = self[name] else { return fallback }
    guard let value = Int(raw), range.contains(value) else { throw CLIError.invalid("--" + name) }
    return value
  }
}

public let worldbookTaskHelp = """
WorldbookTaskTool <adaptation|factory> <命令> [参数]
通用：--root <App 数据根目录>（省略时与本机 App 共用）
模型：--provider <App 模型 UUID>，或 --model <模型> --base-url <地址>
      --context-window <tokens> --output-tokens <tokens> --timeout <秒> --concurrency <1..16>
凭据：仅读取 WORLDBOOK_API_KEY；WORLDBOOK_MODEL / WORLDBOOK_BASE_URL 可提供模型默认值。
      不接受 --api-key，不写钥匙串；模型环境配置必须在续跑时保持一致。

adaptation:
  list | import --source <TXT/EPUB>
  original --source <UTF-8 章节计划> --title <书名> [--author <作者>]
  status | source | bookcases | anchors | pending --job <UUID>
  template --kind <contract|config|taste>
  config --job <UUID> [--file <含原 revision 的配置 JSON>]
  extract | scan --job <UUID> [模型参数] [--max-requests <0..100>]
  contract --job <UUID> --variant <UUID>（读取）
  contract --job <UUID> --file <合同 JSON> --revision <所见版本 UUID>
           [--variant <修改已有方向> | --title <新方向名> [--standalone]] [--bookcase <UUID>]
  edit-bookcase --job <UUID> --file <{jobID,revision,parentID,content}>
  add-anchor --job <UUID> --file <锚点候选 JSON> --revision <UUID|none>
  review --job <UUID> --file <审阅 JSON：kind/jobID/revision/action 等>
  write --job <UUID> --variant <UUID> [模型参数] [--max-requests <0..100>]
        [--taste <CLI 偏好覆盖 JSON>] [--regenerate]
  drafts --job <UUID> --variant <UUID> [--draft <历史版本 UUID>]
  edit-draft --job <UUID> --variant <UUID> --draft <原版本 UUID> --file <新正文内容 JSON>
  assemble --job <UUID> --variant <UUID>（输出待核对装配 JSON）
  export | publish --job <UUID> --file <装配 JSON> [--ack-unchanged]
  report --job <UUID> [--variant <UUID>]
  acknowledge --job <UUID> --file <pending 输出 JSON> --allow-resend

factory:
  list | create --source <TXT/EPUB> | recover
  status --job <UUID> | pending --job <UUID> --kind <analysis|bake>
  analyze | resume | generate --job <UUID> [模型参数] [--taste <CLI 偏好 JSON>]
           [--approval <pending 输出 JSON> --allow-resend]
  generate --job <UUID> --regenerate（显式重建候选；仍复用有效模型缓存）
  answer --job <UUID> --file <{reviewed: 所见决策, answer: 新答案或 null 接受推荐}>
  taste --job <UUID> [--file <{expected: 原配置或 null, overrides: 任务偏好}>]
  publish --job <UUID> [--taste <CLI 偏好 JSON>]

stdout 为 JSON，可重定向保存以审阅和编辑。审阅不会自动批准其它对象，生成不会自动发布。
退出码：0 完成；1 失败；2 参数错误；3 部分完成；4 待核对；75 忙碌；130 取消。
详细示例：docs/CLI任务使用说明.md
"""
