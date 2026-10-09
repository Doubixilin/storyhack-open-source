import Foundation
import LLMProviderKit

final class UISettingsCredentialStore: ProviderCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  func save(_ secret: String, reference: String) throws {
    lock.withLock { values[reference] = secret }
  }
  func load(reference: String) throws -> String {
    try lock.withLock {
      guard let value = values[reference] else { throw ProviderConfigurationError.missingCredential(reference) }
      return value
    }
  }
  func delete(reference: String) throws {
    _ = lock.withLock { values.removeValue(forKey: reference) }
  }
}
