import Foundation

/// Encode only caller-supplied definitions and validated call/result pairs.
/// Plain requests retain their original wire representation.
enum OpenAIToolWire {
  static func encode(_ request: LLMRequest, baseBody: Data) throws -> Data {
    guard request.tools.count <= 8,
      Set(request.tools.map(\.name)).count == request.tools.count,
      request.toolChoice == nil || !request.tools.isEmpty else { throw LLMToolError.invalidRequest }
    let definitions: [[String: Any]] = try request.tools.map { tool in
      guard LLMToolCall.validName(tool.name), tool.description.utf8.count <= 2_048,
        tool.parameters.count <= 16_384,
        let schema = try? JSONSerialization.jsonObject(with: tool.parameters) as? [String: Any],
        schema["type"] as? String == "object" else { throw LLMToolError.invalidRequest }
      return ["type": "function", "function": [
        "name": tool.name, "description": tool.description, "parameters": schema,
      ]]
    }
    var outstanding = Set<String>()
    var seen = Set<String>()
    let messages: [[String: Any]] = try request.messages.map { message in
      var result: [String: Any] = ["role": message.role.rawValue, "content": message.content]
      if message.role == .tool {
        guard message.toolCalls == nil, let id = message.toolCallID,
          outstanding.remove(id) != nil else { throw LLMToolError.invalidRequest }
        result["tool_call_id"] = id
      } else {
        guard message.toolCallID == nil, outstanding.isEmpty else { throw LLMToolError.invalidRequest }
        if let calls = message.toolCalls {
          guard message.role == .assistant, !calls.isEmpty, calls.count <= 8 else {
            throw LLMToolError.invalidRequest
          }
          result["tool_calls"] = try calls.map { call -> [String: Any] in
            guard call.isBounded, request.tools.contains(where: { $0.name == call.name }),
              seen.insert(call.id).inserted else { throw LLMToolError.invalidRequest }
            outstanding.insert(call.id)
            return ["id": call.id, "type": "function",
              "function": ["name": call.name, "arguments": call.arguments]]
          }
          if message.content.isEmpty { result["content"] = NSNull() }
        }
      }
      return result
    }
    guard outstanding.isEmpty else { throw LLMToolError.invalidRequest }
    guard !definitions.isEmpty else { return baseBody }
    var object = try JSONSerialization.jsonObject(with: baseBody) as! [String: Any]
    object["messages"] = messages
    object["tools"] = definitions
    object["tool_choice"] = (request.toolChoice ?? .auto).rawValue
    object["parallel_tool_calls"] = false
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
