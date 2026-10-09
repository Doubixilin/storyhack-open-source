import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DirectoryProcessLockError: Error, Equatable, LocalizedError {
  case busy
  case invalidLock
  case unavailable(Int32)

  public var errorDescription: String? {
    switch self {
    case .busy: "另一个操作正在使用此任务或资料库，请稍后重试。"
    case .invalidLock: "目录锁文件无效，未读取或修改任务数据。"
    case .unavailable: "无法取得目录锁，未读取或修改任务数据。"
    }
  }
}

/// An advisory OS lease. Never delete the lock file: unlinking a locked inode
/// would allow a second process to acquire a different lock at the same path.
/// The descriptor is close-on-exec; process exit releases it, including SIGKILL.
public final class DirectoryProcessLease: @unchecked Sendable {
  private let mutex = NSLock()
  private var descriptor: Int32

  public init(directoryURL: URL, name: String = ".operation.lock") throws {
    guard name.hasPrefix("."), name.count < 100, !name.contains("/"), !name.contains("\\"),
      name != ".", name != ".." else { throw DirectoryProcessLockError.invalidLock }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let url = directoryURL.resolvingSymlinksInPath().appendingPathComponent(name)
    let fd = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard fd >= 0 else { throw DirectoryProcessLockError.unavailable(errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
      close(fd)
      throw DirectoryProcessLockError.invalidLock
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(fd)
      if code == EWOULDBLOCK || code == EAGAIN { throw DirectoryProcessLockError.busy }
      throw DirectoryProcessLockError.unavailable(code)
    }
    descriptor = fd
  }

  public func release() {
    mutex.lock()
    defer { mutex.unlock() }
    guard descriptor >= 0 else { return }
    // Closing the sole descriptor drops flock without a separate unlock window.
    close(descriptor)
    descriptor = -1
  }

  deinit { release() }
}

/// Short synchronous disk operations only. A recursive in-process lock keeps
/// existing cross-actor serialization; the root lease adds process exclusion.
/// Nested journal instances and /tmp aliases share the same acquired lease.
enum DirectoryProcessLock {
  private final class State: @unchecked Sendable {
    let mutex = NSRecursiveLock()
    var heldRoots = Set<String>()
  }
  private static let state = State()

  static func withExclusiveAccess<T>(rootURL: URL, _ operation: () throws -> T) throws -> T {
    state.mutex.lock()
    defer { state.mutex.unlock() }
    // Foundation may normalize /private/tmp to /tmp only once the complete
    // directory exists. Create it before deriving the recursion key, otherwise
    // nested recovery can try to flock the same inode with a second descriptor.
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    if state.heldRoots.contains(root.path) { return try operation() }
    let lease = try DirectoryProcessLease(directoryURL: root, name: ".directory-access.lock")
    state.heldRoots.insert(root.path)
    defer { state.heldRoots.remove(root.path); lease.release() }
    return try operation()
  }
}
