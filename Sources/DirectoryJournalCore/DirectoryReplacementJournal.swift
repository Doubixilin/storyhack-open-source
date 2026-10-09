import Foundation

/// 目录替换与多文件更新的事务日志。
///
/// 背景：「把旧目录移走、再把新目录移进来」两步之间如果进程被杀或掉电，
/// catch 分支不会执行，公开目录消失、书从书架上不见。本类型在两个动作
/// 之前先把三个路径写进同卷日志文件；下次列库时按日志恢复未完成事务：
/// 优先回滚到已验证的旧目录，其次完成已就位的新目录。
///
/// 日志目录约定为 `<root>/.replacement-journals`（隐藏目录，各资料库的
/// `list()` 均跳过隐藏项）。日志只由本 App 写入，恢复时仍校验所有路径
/// 必须位于 root 内，拒绝越界路径。
/// `FileManager` 官方文档保证其实例方法线程安全，故标记 @unchecked Sendable。
public struct DirectoryReplacementJournal: @unchecked Sendable {
  // Recovery must never roll back another actor's transaction while it is
  // still running. Recursive because a caller may prepare a directory under
  // this same lock and then invoke replaceDirectory.
  public func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
    try DirectoryProcessLock.withExclusiveAccess(rootURL: rootURL, operation)
  }
  /// 一次目录替换事务的三个落点（绝对路径，恢复时校验必须位于 root 内）。
  private struct ReplacementRecord: Codable, Sendable {
    var finalPath: String
    var stagingPath: String
    var backupPath: String?
    var createdAt: Date
  }

  /// 一次多文件更新事务的备份清单：备份完成后才写 manifest 作为生效标记。
  private struct FileUpdateManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
      var path: String
      /// nil 表示更新前该文件不存在，回滚时应删除而非还原
      var backupName: String?
    }

    var entries: [Entry]
    var createdAt: Date
  }

  public let rootURL: URL
  private let journalDirectory: URL
  private let fileManager: FileManager

  public init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    journalDirectory = self.rootURL.appendingPathComponent(
      ".replacement-journals",
      isDirectory: true
    )
    self.fileManager = fileManager
  }

  // MARK: - 目录替换

  /// 带日志的目录替换：`staging → final`，旧 `final` 移入 `backupURL`（保留）。
  /// 正常路径行为与裸 moveItem 序列一致；崩溃路径由
  /// `recoverPendingReplacements()` 兜底。
  public func replaceDirectory(
    stagingURL: URL,
    finalURL: URL,
    backupURL: URL
  ) throws {
    try withExclusiveAccess {
      try replaceDirectoryLocked(stagingURL: stagingURL, finalURL: finalURL, backupURL: backupURL)
    }
  }

  private func replaceDirectoryLocked(stagingURL: URL, finalURL: URL, backupURL: URL) throws {
    try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    let journalURL = journalDirectory.appendingPathComponent(
      "\(UUID().uuidString.lowercased()).json"
    )
    let record = ReplacementRecord(
      finalPath: finalURL.path,
      stagingPath: stagingURL.path,
      backupPath: backupURL.path,
      createdAt: Date()
    )
    try JSONEncoder().encode(record).write(to: journalURL, options: .atomic)
    do {
      try fileManager.createDirectory(
        at: backupURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: finalURL.path) {
        try fileManager.moveItem(at: finalURL, to: backupURL)
      }
      do {
        try fileManager.moveItem(at: stagingURL, to: finalURL)
      } catch {
        // 常规异常（非进程死亡）：立即回滚旧目录
        if fileManager.fileExists(atPath: backupURL.path) {
          try? fileManager.moveItem(at: backupURL, to: finalURL)
        }
        throw error
      }
      try? fileManager.removeItem(at: journalURL)
    } catch {
      try? fileManager.removeItem(at: journalURL)
      throw error
    }
  }

  /// 恢复所有未完成的目录替换事务。规则：
  /// - final 缺失、backup 在 → 回滚 backup（回到事务前的一致状态）；
  /// - final 缺失、backup 不在、staging 在 → 完成替换（staging 落位前已校验）；
  /// - final 在 → 事务已完成过半，仅清理残留 staging 与日志。
  /// backup 一律按各资料库既有策略保留，不在恢复时删除。
  public func recoverPendingReplacements() throws {
    try withExclusiveAccess { try recoverPendingReplacementsLocked() }
  }

  private func recoverPendingReplacementsLocked() throws {
    guard fileManager.fileExists(atPath: journalDirectory.path) else { return }
    let journals = try fileManager.contentsOfDirectory(
      at: journalDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for journalURL in journals where journalURL.pathExtension == "json" {
      guard let data = try? Data(contentsOf: journalURL),
        let record = try? JSONDecoder().decode(ReplacementRecord.self, from: data),
        isWithinRoot(record.finalPath),
        isWithinRoot(record.stagingPath),
        record.backupPath.map(isWithinRoot) ?? true
      else {
        // 无法解码或路径越界的日志：跳过且保留，不擅自删除
        continue
      }
      let finalURL = URL(fileURLWithPath: record.finalPath)
      let stagingURL = URL(fileURLWithPath: record.stagingPath)
      let backupURL = record.backupPath.map { URL(fileURLWithPath: $0) }
      let finalExists = fileManager.fileExists(atPath: finalURL.path)
      var resolved = false
      if !finalExists,
        let backupURL,
        fileManager.fileExists(atPath: backupURL.path)
      {
        if (try? fileManager.moveItem(at: backupURL, to: finalURL)) != nil {
          try? fileManager.removeItem(at: stagingURL)
          resolved = true
        }
      } else if !finalExists, fileManager.fileExists(atPath: stagingURL.path) {
        resolved = (try? fileManager.moveItem(at: stagingURL, to: finalURL)) != nil
      } else {
        // final 在：事务已完成过半，仅清理残留 staging；
        // 三者都不在：无可恢复内容，直接收尾
        try? fileManager.removeItem(at: stagingURL)
        resolved = true
      }
      // 恢复动作失败的日志保留到下次列库再试
      if resolved { try? fileManager.removeItem(at: journalURL) }
    }
  }

  // MARK: - 多文件更新

  /// 带日志的多文件原子更新：先把每个目标文件的当前内容复制进事务目录，
  /// 写 manifest 标记后备份齐备，再逐个原子写入新内容，最后删除事务目录。
  /// 崩溃后由 `recoverPendingFileUpdates()` 按备份回滚到更新前状态。
  public func performFileUpdates(_ updates: [(url: URL, data: Data)]) throws {
    try performFileChanges(updates.map { (url: $0.url, data: Optional($0.data)) })
  }

  /// nil removes an owned file. The same transaction backs up additions,
  /// replacements, and removals before applying any of them.
  public func performFileChanges(_ updates: [(url: URL, data: Data?)]) throws {
    try withExclusiveAccess { try performFileChangesLocked(updates) }
  }

  private func performFileChangesLocked(_ updates: [(url: URL, data: Data?)]) throws {
    try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    let transactionURL = journalDirectory.appendingPathComponent(
      "update-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: true)
    do {
      var entries: [FileUpdateManifest.Entry] = []
      for (index, update) in updates.enumerated() {
        guard isWithinRoot(update.url.path) else {
          throw DirectoryReplacementJournalError.pathOutsideRoot(update.url.path)
        }
        if fileManager.fileExists(atPath: update.url.path) {
          let backupName = "backup-\(index)"
          try fileManager.copyItem(
            at: update.url,
            to: transactionURL.appendingPathComponent(backupName)
          )
          entries.append(.init(path: update.url.path, backupName: backupName))
        } else {
          entries.append(.init(path: update.url.path, backupName: nil))
        }
      }
      // 备份齐备后才写 manifest；没有 manifest 的事务目录恢复时直接清理
      let manifest = FileUpdateManifest(entries: entries, createdAt: Date())
      try JSONEncoder().encode(manifest).write(
        to: transactionURL.appendingPathComponent("manifest.json"),
        options: .atomic
      )
      for update in updates {
        if let data = update.data {
          try data.write(to: update.url, options: .atomic)
        } else if fileManager.fileExists(atPath: update.url.path) {
          try fileManager.removeItem(at: update.url)
        }
      }
      // Cleanup failure after commit must not cause a later list() to roll
      // back a successfully returned publication.
      try Data().write(to: transactionURL.appendingPathComponent("committed"), options: .atomic)
      try? fileManager.removeItem(at: transactionURL)
    } catch {
      // 常规异常：尽力回滚后上抛；进程死亡路径由恢复兜底
      do {
        try rollbackFileUpdates(at: transactionURL)
        try fileManager.removeItem(at: transactionURL)
      } catch {
        // Keep remaining backups and the manifest if rollback fails. Recovery
        // can retry after the filesystem becomes available again.
      }
      throw error
    }
  }

  /// 回滚所有未完成的多文件更新事务。
  public func recoverPendingFileUpdates() throws {
    try withExclusiveAccess { try recoverPendingFileUpdatesLocked() }
  }

  private func recoverPendingFileUpdatesLocked() throws {
    guard fileManager.fileExists(atPath: journalDirectory.path) else { return }
    let children = try fileManager.contentsOfDirectory(
      at: journalDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    for child in children {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else { continue }
      try rollbackFileUpdates(at: child)
      try? fileManager.removeItem(at: child)
    }
  }

  private func rollbackFileUpdates(at transactionURL: URL) throws {
    guard !fileManager.fileExists(atPath: transactionURL.appendingPathComponent("committed").path) else { return }
    let manifestURL = transactionURL.appendingPathComponent("manifest.json")
    // 无 manifest：崩溃发生在备份阶段，目标文件尚未被触碰，无需回滚
    guard fileManager.fileExists(atPath: manifestURL.path) else { return }
    let manifest = try JSONDecoder().decode(FileUpdateManifest.self, from: Data(contentsOf: manifestURL))
    for entry in manifest.entries {
      guard isWithinRoot(entry.path) else { throw DirectoryReplacementJournalError.pathOutsideRoot(entry.path) }
      let target = URL(fileURLWithPath: entry.path)
      if let backupName = entry.backupName {
        guard backupName.hasPrefix("backup-"), !backupName.contains("/"), !backupName.contains("\\") else {
          throw DirectoryReplacementJournalError.invalidBackup(backupName)
        }
        let backup = transactionURL.appendingPathComponent(backupName)
        if !fileManager.fileExists(atPath: backup.path) {
          // Legacy recovery moved backups one by one; a present target may
          // already have been restored before that process was interrupted.
          guard fileManager.fileExists(atPath: target.path) else {
            throw DirectoryReplacementJournalError.invalidBackup(backupName)
          }
          continue
        }
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: backup, to: target)
      } else {
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
      }
    }
  }

  private func isWithinRoot(_ path: String) -> Bool {
    // On macOS, standardization of /private/tmp changes when a file starts
    // existing. Resolve the nearest existing ancestor for both paths so a new
    // response and an existing checkpoint use the same directory identity.
    func canonicalPath(_ url: URL) -> String {
      var ancestor = url.standardizedFileURL
      var missing: [String] = []
      while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        missing.append(ancestor.lastPathComponent)
        ancestor.deleteLastPathComponent()
      }
      return missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
        $0.appendingPathComponent($1)
      }.path
    }
    let root = canonicalPath(rootURL)
    return canonicalPath(URL(fileURLWithPath: path)).hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }
}

public enum DirectoryReplacementJournalError: Error, Equatable {
  case pathOutsideRoot(String)
  case invalidBackup(String)
}
