import Foundation
import Testing

@testable import DirectoryJournalCore

/// 目录替换/多文件更新事务日志的故障注入测试：
/// 手工摆出每种「进程在两次移动之间被杀」的现场，验证恢复语义。
struct DirectoryReplacementJournalTests {
  #if os(macOS)
  @Test
  func rootCreatedAfterJournalInitializationRetainsItsOwnedFiles() throws {
    // Foundation can standardize /private/tmp differently once the path exists.
    let root = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("journal-late-root-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = DirectoryReplacementJournal(rootURL: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("response.json")
    try journal.performFileUpdates([(target, Data("paid-response".utf8))])
    #expect(content(of: target) == "paid-response")
    try journal.performFileUpdates([(target, Data("completed-response".utf8))])
    #expect(content(of: target) == "completed-response")
    let outside = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
    #expect(throws: DirectoryReplacementJournalError.self) {
      try journal.performFileUpdates([(outside, Data("outside".utf8))])
    }
    #expect(!FileManager.default.fileExists(atPath: outside.path))
  }
  #endif

  @Test
  func unreadableTransactionManifestPreservesRecoveryData() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transaction = root.appendingPathComponent(".replacement-journals/update-broken")
    try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: transaction.appendingPathComponent("backup-0"))
    try Data("broken".utf8).write(to: transaction.appendingPathComponent("manifest.json"))
    #expect(throws: (any Error).self) {
      try DirectoryReplacementJournal(rootURL: root).recoverPendingFileUpdates()
    }
    #expect(content(of: transaction.appendingPathComponent("backup-0")) == "old")
  }

  @Test
  func removingOwnedFileRollsBackWhenLaterWriteFails() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = makeFile("optional.json", under: root, content: "old")
    let invalidDestination = root.appendingPathComponent("missing/file.json")
    #expect(throws: (any Error).self) {
      try DirectoryReplacementJournal(rootURL: root).performFileChanges([
        (old, nil), (invalidDestination, Data("new".utf8)),
      ])
    }
    #expect(content(of: old) == "old")
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func failedRollbackKeepsJournalForNextRecovery() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = makeFile("existing.json", under: root, content: "old")
    let invalidDestination = root.appendingPathComponent("missing/file.json")
    let journal = DirectoryReplacementJournal(rootURL: root,
      fileManager: RollbackFailingFileManager(protectedURL: old))
    #expect(throws: (any Error).self) {
      try journal.performFileChanges([(old, Data("new".utf8)), (invalidDestination, Data())])
    }
    #expect(content(of: old) == "new")
    #expect(!journalFiles(under: root).isEmpty)
    try DirectoryReplacementJournal(rootURL: root).recoverPendingFileUpdates()
    #expect(content(of: old) == "old")
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func committedFileTransactionDoesNotRollBackAfterCleanupFailure() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = makeFile("existing.json", under: root, content: "new")
    let transaction = root.appendingPathComponent(".replacement-journals/update-complete")
    try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: transaction.appendingPathComponent("backup-0"))
    let manifest: [String: Any] = ["entries": [["path": target.path, "backupName": "backup-0"]],
      "createdAt": Date().timeIntervalSinceReferenceDate]
    try JSONSerialization.data(withJSONObject: manifest).write(to: transaction.appendingPathComponent("manifest.json"))
    try Data().write(to: transaction.appendingPathComponent("committed"))
    try DirectoryReplacementJournal(rootURL: root).recoverPendingFileUpdates()
    #expect(content(of: target) == "new")
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func recoveryWaitsForAnotherActorsActiveReplacement() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = makeDirectory("staging", under: root, marker: "new")
    let final = makeDirectory("final", under: root, marker: "old")
    let backup = root.appendingPathComponent("backups/old")
    let journal = DirectoryReplacementJournal(rootURL: root)
    let entered = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    try journal.withExclusiveAccess {
      // A second instance models list() on a different actor. If it recovered
      // during preparation it would delete staging because final still exists.
      writeJournal(root: root, final: final, staging: staging, backup: backup)
      Thread.detachNewThread {
        entered.signal()
        do { try DirectoryReplacementJournal(rootURL: root).recoverPendingReplacements() }
        catch { Issue.record(error) }
        finished.signal()
      }
      #expect(entered.wait(timeout: .now() + 2) == .success)
      #expect(finished.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
      try journal.replaceDirectory(stagingURL: staging, finalURL: final, backupURL: backup)
    }
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(marker(at: final) == "new")
    #expect(marker(at: backup) == "old")
  }

  @Test
  func replaceDirectoryHappyPathMovesOldToBackupAndNewToFinal() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = makeDirectory("staging", under: root, marker: "new")
    let final = makeDirectory("final", under: root, marker: "old")
    let backup = root.appendingPathComponent("backups/old", isDirectory: true)

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.replaceDirectory(stagingURL: staging, finalURL: final, backupURL: backup)

    #expect(marker(at: final) == "new")
    #expect(marker(at: backup) == "old")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func recoveryRollsBackToBackupWhenFinalWasMovedAway() throws {
    // 崩溃点：final → backup 已完成，staging → final 未发生
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = makeDirectory("staging", under: root, marker: "new")
    let final = root.appendingPathComponent("final", isDirectory: true)
    let backup = makeDirectory("backups/old", under: root, marker: "old")
    writeJournal(root: root, final: final, staging: staging, backup: backup)

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.recoverPendingReplacements()

    #expect(marker(at: final) == "old")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func recoveryCompletesWithStagingWhenNoBackupExists() throws {
    // 崩溃点：日志已写，但任何移动都没发生，且旧 final 从未存在
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = makeDirectory("staging", under: root, marker: "new")
    let final = root.appendingPathComponent("final", isDirectory: true)
    writeJournal(root: root, final: final, staging: staging, backup: nil)

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.recoverPendingReplacements()

    #expect(marker(at: final) == "new")
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func recoveryCleansStagingWhenFinalAlreadyInPlace() throws {
    // 崩溃点：staging → final 已完成，日志尚未删除
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = makeDirectory("staging", under: root, marker: "new")
    let final = makeDirectory("final", under: root, marker: "new")
    writeJournal(root: root, final: final, staging: staging, backup: nil)

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.recoverPendingReplacements()

    #expect(marker(at: final) == "new")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(journalFiles(under: root).isEmpty)
  }

  @Test
  func recoveryRejectsJournalWithPathsOutsideRoot() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    makeDirectory("victim", under: outside, marker: "keep")
    let final = outside.appendingPathComponent("victim", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    writeJournal(root: root, final: final, staging: staging, backup: nil)

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.recoverPendingReplacements()

    // 越界路径不得被动；日志保留等待人工处理
    #expect(marker(at: final) == "keep")
    #expect(journalFiles(under: root).count == 1)
  }

  @Test
  func fileUpdatesAreAtomicAcrossFilesAndRecoverable() throws {
    // 崩溃现场：文件 A 已写入新内容，文件 B 还是旧内容，事务目录留存
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileA = makeFile("a.json", under: root, content: "old-a")
    let fileB = makeFile("b.json", under: root, content: "old-b")
    let journal = DirectoryReplacementJournal(rootURL: root)

    // 手动摆出事务目录：两份旧内容备份 + manifest
    let txn = root.appendingPathComponent(
      ".replacement-journals/update-test", isDirectory: true)
    try FileManager.default.createDirectory(at: txn, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: fileA, to: txn.appendingPathComponent("backup-0"))
    try FileManager.default.copyItem(
      at: fileB, to: txn.appendingPathComponent("backup-1"))
    let manifest = """
      {"entries":[\
      {"path":"\(fileA.path)","backupName":"backup-0"},\
      {"path":"\(fileB.path)","backupName":"backup-1"}],\
      "createdAt":780000000}
      """
    try Data(manifest.utf8).write(to: txn.appendingPathComponent("manifest.json"))
    // 模拟 A 已更新、B 未更新
    try Data("new-a".utf8).write(to: fileA)

    try journal.recoverPendingFileUpdates()

    #expect(content(of: fileA) == "old-a")
    #expect(content(of: fileB) == "old-b")
    #expect(!FileManager.default.fileExists(atPath: txn.path))
  }

  @Test
  func fileUpdateTransactionWithoutManifestIsJustCleanedUp() throws {
    // 崩溃发生在备份阶段：manifest 未写，目标文件尚未被触碰
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileA = makeFile("a.json", under: root, content: "old-a")
    let txn = root.appendingPathComponent(
      ".replacement-journals/update-partial", isDirectory: true)
    try FileManager.default.createDirectory(at: txn, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: fileA, to: txn.appendingPathComponent("backup-0"))

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.recoverPendingFileUpdates()

    #expect(content(of: fileA) == "old-a")
    #expect(!FileManager.default.fileExists(atPath: txn.path))
  }

  @Test
  func performFileUpdatesWritesAllFilesAndCleansUp() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileA = makeFile("a.json", under: root, content: "old-a")
    let fileB = root.appendingPathComponent("b.json")

    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.performFileUpdates([
      (fileA, Data("new-a".utf8)),
      (fileB, Data("new-b".utf8)),
    ])

    #expect(content(of: fileA) == "new-a")
    #expect(content(of: fileB) == "new-b")
    #expect(journalFiles(under: root).isEmpty)
  }

  // MARK: - 夹具

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeDirectory(_ name: String, under root: URL, marker: String) -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? Data(marker.utf8).write(to: url.appendingPathComponent("marker.txt"))
    return url
  }

  private func makeFile(_ name: String, under root: URL, content: String) -> URL {
    let url = root.appendingPathComponent(name)
    try? Data(content.utf8).write(to: url)
    return url
  }

  private func content(of file: URL) -> String? {
    try? String(contentsOf: file, encoding: .utf8)
  }

  private func marker(at directory: URL) -> String? {
    try? String(
      contentsOf: directory.appendingPathComponent("marker.txt"),
      encoding: .utf8
    )
  }

  private func writeJournal(root: URL, final: URL, staging: URL, backup: URL?) {
    let dir = root.appendingPathComponent(".replacement-journals", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var json = """
      {"finalPath":"\(final.path)","stagingPath":"\(staging.path)",\
      "createdAt":780000000
      """
    if let backup {
      json += ",\"backupPath\":\"\(backup.path)\""
    }
    json += "}"
    try? Data(json.utf8).write(to: dir.appendingPathComponent("txn.json"))
  }

  /// 顶层日志文件 + 事务子目录一并计数
  private func journalFiles(under root: URL) -> [URL] {
    let dir = root.appendingPathComponent(".replacement-journals", isDirectory: true)
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return [] }
    return children
  }
}

private final class RollbackFailingFileManager: FileManager, @unchecked Sendable {
  let protectedURL: URL
  init(protectedURL: URL) {
    self.protectedURL = protectedURL
    super.init()
  }
  override func removeItem(at URL: URL) throws {
    if URL == protectedURL { throw CocoaError(.fileWriteNoPermission) }
    try super.removeItem(at: URL)
  }
}
