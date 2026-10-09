import CryptoKit
import Foundation

enum FactoryStableIdentity {
  static func uuid(namespace: String, components: [String]) -> UUID {
    let data = try! JSONEncoder().encode([namespace] + components)
    let hex = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    let parts = [8, 4, 4, 4, 12]
    var offset = hex.startIndex
    let text = parts.map { length -> String in
      let end = hex.index(offset, offsetBy: length)
      defer { offset = end }
      return String(hex[offset..<end])
    }.joined(separator: "-")
    return UUID(uuidString: text)!
  }
}
