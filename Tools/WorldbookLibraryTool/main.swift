import Darwin
import Foundation
import LibraryCore
import NovelDocumentCore

enum LibraryToolError: Error, LocalizedError {
  case usage
  case unsafeLibraryRoot(String)
  case sourceNotFound(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      "用法：WorldbookLibraryTool import --library-root <路径> <小说文件或目录>..."
    case .unsafeLibraryRoot(let path):
      "拒绝写入未授权的书架路径：\(path)"
    case .sourceNotFound(let path):
      "找不到导入源：\(path)"
    }
  }
}

@main
struct WorldbookLibraryTool {
  static func main() async {
    do {
      let request = try parseArguments()
      let sources = try collectSources(from: request.sources)
      let library = NovelLibrary(
        rootURL: request.libraryRoot,
        parser: NovelDocumentParser(),
        fileManager: .default
      )
      var knownIDs = Set(try await library.list().map(\.id))
      var imported = 0
      var existing = 0
      var failed: [(URL, Error)] = []

      for (index, source) in sources.enumerated() {
        print("[\(index + 1)/\(sources.count)] \(source.lastPathComponent)")
        do {
          let record = try await library.importDocument(from: source)
          if knownIDs.insert(record.id).inserted {
            imported += 1
            print(
              "  已导入：\(record.document.chapters.count) 章，\(record.document.totalCharacterCount) 字")
          } else {
            existing += 1
            print("  已存在：内容指纹相同，未重复导入")
          }
        } catch {
          failed.append((source, error))
          print("  失败：\(error.localizedDescription)")
        }
      }

      print("汇总：新增 \(imported)，已存在 \(existing)，失败 \(failed.count)，总计 \(sources.count)")
      if !failed.isEmpty {
        Darwin.exit(1)
      }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      Darwin.exit(2)
    }
  }

  private static func parseArguments() throws -> (libraryRoot: URL, sources: [URL]) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 4, arguments[0] == "import", arguments[1] == "--library-root"
    else {
      throw LibraryToolError.usage
    }
    let root = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
    try validateLibraryRoot(root)
    let sources = arguments.dropFirst(3).map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
    return (root, sources)
  }

  private static func validateLibraryRoot(_ root: URL) throws {
    let path = root.path
    let defaultPath = NovelLibrary.defaultRootURL.standardizedFileURL.path
    let projectLocalPrefix =
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("LocalLibrary", isDirectory: true)
      .standardizedFileURL.path + "/"
    guard path == defaultPath || path.hasPrefix("/tmp/") || path.hasPrefix(projectLocalPrefix)
    else {
      throw LibraryToolError.unsafeLibraryRoot(path)
    }
  }

  private static func collectSources(from roots: [URL]) throws -> [URL] {
    let supportedExtensions = Set(["txt", "md", "markdown", "epub"])
    var sources: [URL] = []
    for root in roots {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
        throw LibraryToolError.sourceNotFound(root.path)
      }
      if isDirectory.boolValue {
        let children = try FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
        for child in children {
          let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          if values.isRegularFile == true,
            values.isSymbolicLink != true,
            supportedExtensions.contains(child.pathExtension.lowercased())
          {
            sources.append(child)
          }
        }
      } else if supportedExtensions.contains(root.pathExtension.lowercased()) {
        sources.append(root)
      }
    }
    return Array(Set(sources.map(\.path))).sorted().map(URL.init(fileURLWithPath:))
  }
}
