import Foundation

/// 面向最终用户的统一模型错误翻译。技术响应体仍由调用层用于诊断，
/// 但不得直接进入弹窗、Toast 或 SSE error 事件。
public enum ProviderErrorMessage {
  public static func message(for error: any Error) -> String {
    if let error = error as? ModelResponseParseFailure {
      return "模型这次没有给出可用回复，可重试；摘要：\(error.responseSummary)"
    }
    if let error = error as? OpenAICompatibleError {
      switch error {
      case .invalidBaseURL:
        return "模型地址无效，请到模型设置检查服务地址。"
      case .invalidHTTPResponse, .invalidServerEvent:
        return "模型服务返回了无法识别的数据，请稍后重试或检查模型配置。"
      case .httpStatus(let status, let body):
        return message(statusCode: status, responseBody: body)
      case .serverMessage(let value):
        return sanitizedServerMessage(value)
      case .stallTimeout:
        return "模型服务长时间没有响应，请检查网络后重试。"
      case .incompleteStream:
        return "模型回复在传输中断开，本轮没有提交，请重试。"
      }
    }
    if let error = error as? URLError {
      switch error.code {
      case .timedOut:
        return "连接模型服务超时，请检查网络后重试。"
      case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed:
        return "无法连接模型服务，请检查网络和服务地址后重试。"
      case .cancelled:
        return "操作已取消。"
      default:
        return "模型服务连接失败，请检查网络后重试。"
      }
    }
    return sanitizedServerMessage(error.localizedDescription)
  }

  public static func message(statusCode: Int, responseBody: String = "") -> String {
    let normalized = responseBody.lowercased()
    if statusCode == 402
      || normalized.contains("insufficient balance")
      || normalized.contains("insufficient_balance")
      || normalized.contains("余额不足")
    {
      return "模型账户余额不足，请充值后重试。"
    }
    switch statusCode {
    case 401, 403:
      return "API Key 无效或没有权限，请到模型设置检查。"
    case 404:
      return "没有找到所选模型或接口，请检查模型名称和服务地址。"
    case 408:
      return "模型服务响应超时，请稍后重试。"
    case 409:
      return "模型服务当前无法处理这次请求，请稍后重试。"
    case 429:
      return "请求太频繁，模型服务正在限流，请稍等片刻再试。"
    case 500...599:
      return "模型服务暂时故障，请稍后重试。"
    default:
      return "模型服务暂时无法完成请求，请检查配置后重试。"
    }
  }

  private static func sanitizedServerMessage(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return "模型服务暂时不可用，请稍后重试。"
    }
    let lowered = trimmed.lowercased()
    if lowered.contains("insufficient balance") || lowered.contains("insufficient_balance") {
      return message(statusCode: 402)
    }
    if lowered.contains("timed out") || lowered.contains("timeout") {
      return "连接模型服务超时，请检查网络后重试。"
    }
    // 服务端自然语言短句可以保留；疑似 JSON、HTML、状态码或超长内容统一收敛。
    if trimmed.count <= 160,
      !trimmed.contains("{"), !trimmed.contains("}"),
      !trimmed.contains("<html"),
      trimmed.range(of: #"HTTP\s*\d{3}"#, options: .regularExpression) == nil
    {
      return trimmed
    }
    return "模型服务暂时无法完成请求，请稍后重试。"
  }
}
