import Foundation
import Testing
import Darwin
@testable import DirectoryJournalCore

struct DirectoryProcessLockTests {
  @Test func firstAccessToMissingPrivateTmpRootKeepsNestedRecoveryInSameLease() throws {
    let name = "wordbook-lock-cold-" + UUID().uuidString
    let parent = URL(fileURLWithPath: "/private/tmp/" + name, isDirectory: true)
    let root = parent.appendingPathComponent("not-yet-created", isDirectory: true)
    let alias = URL(fileURLWithPath: "/tmp/" + name + "/not-yet-created", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let journal = DirectoryReplacementJournal(rootURL: root)
    try journal.withExclusiveAccess {
      try journal.recoverPendingFileUpdates()
      try DirectoryReplacementJournal(rootURL: alias).withExclusiveAccess {
        try journal.recoverPendingReplacements()
        let child = try LockProbe(root: alias, hold: false)
        defer { child.stop() }
        #expect(try child.result() == "B")
      }
    }
    let child = try LockProbe(root: root, hold: false)
    defer { child.stop() }
    #expect(try child.result() == "A")
  }

  @Test func nestedAliasesKeepTheSameKernelLockAndReleaseOnError() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let journal = DirectoryReplacementJournal(rootURL: root)
    struct DeliberateFailure: Error {}
    #expect(throws: DeliberateFailure.self) {
      try journal.withExclusiveAccess {
        try DirectoryReplacementJournal(rootURL: alias).withExclusiveAccess {
          let child = try LockProbe(root: root, hold: false)
          defer { child.stop() }
          #expect(try child.result() == "B")
        }
        // The nested scope must not close the outer lease.
        let child = try LockProbe(root: root, hold: false)
        defer { child.stop() }
        #expect(try child.result() == "B")
        throw DeliberateFailure()
      }
    }
    let child = try LockProbe(root: root, hold: false)
    defer { child.stop() }
    #expect(try child.result() == "A")
  }

  @Test func externalWriterBlocksMutationAndRecoveryUntilProcessDeath() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("value.json")
    try Data("new".utf8).write(to: target)
    let transaction = root.appendingPathComponent(".replacement-journals/update-active")
    try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: transaction.appendingPathComponent("backup-0"))
    let manifest: [String: Any] = ["entries": [["path": target.path, "backupName": "backup-0"]],
      "createdAt": Date().timeIntervalSinceReferenceDate]
    try JSONSerialization.data(withJSONObject: manifest).write(to: transaction.appendingPathComponent("manifest.json"))
    let child = try LockProbe(root: root, hold: true)
    defer { child.stop() }
    #expect(try child.result() == "A")
    let journal = DirectoryReplacementJournal(rootURL: root)
    #expect(throws: DirectoryProcessLockError.busy) { try journal.withExclusiveAccess { Issue.record("entered occupied directory") } }
    #expect(throws: DirectoryProcessLockError.busy) { try journal.recoverPendingFileUpdates() }
    #expect(throws: DirectoryProcessLockError.busy) { try journal.recoverPendingReplacements() }
    #expect(throws: DirectoryProcessLockError.busy) { try journal.performFileChanges([(target, Data("bad".utf8))]) }
    #expect(throws: DirectoryProcessLockError.busy) {
      try journal.replaceDirectory(stagingURL: root.appendingPathComponent("absent"),
        finalURL: root.appendingPathComponent("final"), backupURL: root.appendingPathComponent("backup"))
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    #expect(FileManager.default.fileExists(atPath: transaction.path))
    let lock = root.appendingPathComponent(".directory-access.lock")
    let inode = try FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber
    child.killAndWait()
    try journal.recoverPendingFileUpdates()
    #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    #expect(!FileManager.default.fileExists(atPath: transaction.path))
    #expect(try FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber == inode)
  }

  @Test func lockFilesCannotRedirectAndSeparateRootsRemainIndependent() throws {
    let root = try temporaryRoot(), other = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
    let outside = other.appendingPathComponent("do-not-touch")
    try Data("keep".utf8).write(to: outside)
    let lock = root.appendingPathComponent(".directory-access.lock")
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try DirectoryReplacementJournal(rootURL: root).withExclusiveAccess { Issue.record("followed symlink") } }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
    try FileManager.default.removeItem(at: lock)
    try FileManager.default.linkItem(at: outside, to: lock)
    #expect(throws: DirectoryProcessLockError.invalidLock) { try DirectoryReplacementJournal(rootURL: root).recoverPendingFileUpdates() }
    try FileManager.default.removeItem(at: lock)
    let child = try LockProbe(root: root, hold: true)
    defer { child.stop() }
    #expect(try child.result() == "A")
    try DirectoryReplacementJournal(rootURL: other).withExclusiveAccess {
      try Data("independent".utf8).write(to: other.appendingPathComponent("result"))
    }
  }

  @Test func executionLeaseExcludesOtherInstancesAndIsReleasedIdempotently() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lease = try DirectoryProcessLease(directoryURL: root)
    #expect(throws: DirectoryProcessLockError.busy) { try DirectoryProcessLease(directoryURL: root) }
    // Short disk reads/author CAS can continue while a model run owns its lease.
    try DirectoryReplacementJournal(rootURL: root).withExclusiveAccess { }
    lease.release(); lease.release()
    let next = try DirectoryProcessLease(directoryURL: root)
    next.release()
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wordbook-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

/// A separate OS process speaking flock, not another Swift actor or an in-memory
/// mock. Uses macOS's developer-tools Python standard library only, no packages.
private final class LockProbe {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  init(root: URL, hold: Bool) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", """
      import os, fcntl, signal, sys
      signal.alarm(10)
      fd = os.open(os.path.join(sys.argv[1], '.directory-access.lock'), os.O_CREAT | os.O_RDWR, 0o600)
      try:
          fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      except BlockingIOError:
          sys.stdout.write('B'); sys.stdout.flush(); sys.exit(0)
      sys.stdout.write('A'); sys.stdout.flush()
      if sys.argv[2] == 'hold': sys.stdin.buffer.read(1)
      os.close(fd)
      """, root.path, hold ? "hold" : "probe"]
    process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
    process.standardInput = input; process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
  }
  func result() throws -> String {
    String(decoding: try output.fileHandleForReading.read(upToCount: 1) ?? Data(), as: UTF8.self)
  }
  func stop() {
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.waitUntilExit() }
  }
  func killAndWait() {
    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
}
