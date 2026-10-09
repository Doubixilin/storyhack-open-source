import CryptoKit
import Foundation

public enum FactoryRequestKind: String, Sendable { case analysis, bake }

/// Approval names a specific set of pending files. It cannot silently authorize
/// newer requests, another job, or another payload at the same filename.
public struct FactoryRequestRetryApproval: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let relativePath: String
    let sha256: String
  }
  public let jobID: UUID
  let entries: [Entry]
  public var requestCount: Int { entries.count }
}

public enum FactoryRequestRetryError: Error, LocalizedError {
  case confirmationRequired(Int)
  case staleApproval
  case invalidCheckpoint
  public var errorDescription: String? {
    switch self {
    case .confirmationRequired(let count):
      "有 \(count) 个请求的结果尚未确认。重新发送可能重复计费，请先确认重发。"
    case .staleApproval: "待重发请求已变化，请重新核对后确认。"
    case .invalidCheckpoint: "请求检查点损坏或超过范围，已停止自动发送。"
    }
  }
}

extension FactoryJobStore {
  public func pendingRequestRetry(_ jobID: UUID, kind: FactoryRequestKind? = nil) throws -> FactoryRequestRetryApproval {
    let jobURL = try workspaceURL(jobID: jobID)
    var entries: [FactoryRequestRetryApproval.Entry] = []
    for folder in kind.map({ [$0.rawValue + "/batches"] }) ?? ["analysis/batches", "bake/batches"] {
      let directory = jobURL.appendingPathComponent(folder)
      guard FileManager.default.fileExists(atPath: directory.path) else { continue }
      guard directory.resolvingSymlinksInPath().pathComponents.starts(
        with: jobURL.resolvingSymlinksInPath().pathComponents) else {
        throw FactoryRequestRetryError.invalidCheckpoint
      }
      for url in try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where url.lastPathComponent.hasSuffix(".inflight.json") {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw FactoryRequestRetryError.invalidCheckpoint
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536, entries.count < 10_000 else { throw FactoryRequestRetryError.invalidCheckpoint }
        entries.append(.init(relativePath: folder + "/" + url.lastPathComponent,
          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
      }
    }
    return .init(jobID: jobID, entries: entries.sorted { $0.relativePath < $1.relativePath })
  }

  /// Called only from a coordinator operation already serialized by job ID.
  func authorizeRequestRetry(_ jobID: UUID, approval: FactoryRequestRetryApproval?,
    kind: FactoryRequestKind? = nil) throws {
    let current = try pendingRequestRetry(jobID, kind: kind)
    guard current.requestCount > 0 else {
      if let approval, approval != current { throw FactoryRequestRetryError.staleApproval }
      return
    }
    guard let approval else { throw FactoryRequestRetryError.confirmationRequired(current.requestCount) }
    guard approval == current else { throw FactoryRequestRetryError.staleApproval }
    let root = try workspaceURL(jobID: jobID)
    let archive = root.appendingPathComponent("retry-approved/\(UUID().uuidString.lowercased())")
    guard archive.resolvingSymlinksInPath().pathComponents.starts(
      with: root.resolvingSymlinksInPath().pathComponents) else {
      throw FactoryRequestRetryError.invalidCheckpoint
    }
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try JSONEncoder().encode(approval).write(to: archive.appendingPathComponent("approval.json"), options: .atomic)
    for entry in current.entries {
      let from = root.appendingPathComponent(entry.relativePath)
      let to = archive.appendingPathComponent(entry.relativePath)
      try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: from, to: to)
    }
  }
}
