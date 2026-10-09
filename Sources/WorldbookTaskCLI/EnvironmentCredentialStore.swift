import Foundation
import LLMProviderKit

/// This type lives in the CLI-only target. There is no Keychain fallback.
public struct EnvironmentCredentialStore: ProviderCredentialStore {
  public static let reference = "worldbook-cli-environment"
  private let secret: String?
  public init(environment: [String: String]) { secret = environment["WORLDBOOK_API_KEY"] }
  public func load(reference: String) throws -> String {
    guard reference == Self.reference, let secret, !secret.isEmpty, secret.utf8.count <= 4096,
      !secret.contains("\n"), !secret.contains("\r") else { throw CLIError.missingCredential }
    return secret
  }
  public func save(_ secret: String, reference: String) throws { throw CLIError.readOnlyCredential }
  public func delete(reference: String) throws { throw CLIError.readOnlyCredential }
}
