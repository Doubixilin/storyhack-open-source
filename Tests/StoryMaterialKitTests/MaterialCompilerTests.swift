#if os(macOS)
import Foundation
import XCTest

final class MaterialCompilerTests: XCTestCase {
  func testNormalCompilationCountsSlotsAndKeepsP6OutOfResources() throws {
    let workspace = try makeSourceWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    let result = try runCompiler(in: workspace)
    XCTAssertEqual(result.status, 0, result.error)

    let manifest = try loadObject(workspace.output.appendingPathComponent("manifest.json"))
    let counts = manifest["package_counts"] as! [String: Int]
    XCTAssertEqual(counts["ending_verdicts"], 2_000)
    XCTAssertEqual(counts["choices"], 3_600)
    XCTAssertEqual(counts["stat_lines"], 600)
    XCTAssertEqual(counts["stat_templates"], 363)
    XCTAssertEqual(counts["stat_quarantine"], 237)
    XCTAssertEqual(counts["test_inputs"], 1_000)
    XCTAssertEqual(counts["stat_templates"]! + counts["stat_quarantine"]!, 600)

    let statTemplates = try loadArray(workspace.output.appendingPathComponent("stats.json"))
    XCTAssertTrue(statTemplates.allSatisfy {
      ($0["slot"] as? String) == "number"
        && (($0["template"] as? String)?.filter { $0 == "{" }.count == 1)
    })
    let resourceFiles = try FileManager.default.subpathsOfDirectory(atPath: workspace.output.path)
    XCTAssertFalse(resourceFiles.contains(where: { $0.contains("test_inputs") }))
    XCTAssertEqual(try lineCount(workspace.fixture), 1_000)
  }

  func testCompilerRejectsInvalidEnum() throws {
    let workspace = try makeSourceWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    try mutateFirstRow(in: workspace.source.appendingPathComponent("choices.jsonl")) {
      $0["scene"] = "not-a-scene"
    }
    let result = try runCompiler(in: workspace)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.error.contains("invalid scene"), result.error)
  }

  func testCompilerRejectsForbiddenPhrase() throws {
    let workspace = try makeSourceWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    try mutateFirstRow(in: workspace.source.appendingPathComponent("ending_verdicts.jsonl")) {
      $0["text"] = "命运的齿轮开始转动"
    }
    let result = try runCompiler(in: workspace)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.error.contains("forbidden phrase"), result.error)
  }

  func testCompilerRejectsUnderfilledGrid() throws {
    let workspace = try makeSourceWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    let path = workspace.source.appendingPathComponent("prose_samples.jsonl")
    var lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    lines.removeFirst()
    try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    let result = try runCompiler(in: workspace)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.error.contains("prose grid"), result.error)
  }

  private struct Workspace {
    let root: URL
    let source: URL
    let output: URL
    let fixture: URL
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var auditedSource: URL {
    repositoryRoot.appendingPathComponent(
      "Materials/source"
    )
  }

  private let sourceNames = [
    "ending_verdicts.jsonl", "choices.jsonl", "stat_lines.jsonl",
    "prose_samples.jsonl", "role_pitches.jsonl", "test_inputs.jsonl",
  ]

  private func makeSourceWorkspace() throws -> Workspace {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("storyhack_materials", isDirectory: true)
    let output = root.appendingPathComponent("materials-v1", isDirectory: true)
    let fixture = root.appendingPathComponent("Fixtures/test_inputs.jsonl")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for name in sourceNames {
      try FileManager.default.copyItem(
        at: auditedSource.appendingPathComponent(name),
        to: source.appendingPathComponent(name)
      )
    }
    return Workspace(root: root, source: source, output: output, fixture: fixture)
  }

  private func runCompiler(in workspace: Workspace) throws -> (status: Int32, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      repositoryRoot.appendingPathComponent("scripts/material_compiler.py").path,
      "--source-dir", workspace.source.path,
      "--output-dir", workspace.output.path,
      "--fixtures-path", workspace.fixture.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["SOURCE_DATE_EPOCH"] = "1787875200"
    process.environment = environment
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let error = String(
      data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    return (process.terminationStatus, error)
  }

  private func mutateFirstRow(
    in path: URL,
    mutation: (inout [String: Any]) -> Void
  ) throws {
    var lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    var first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
    mutation(&first)
    lines[0] = Substring(String(data: try JSONSerialization.data(withJSONObject: first), encoding: .utf8)!)
    try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
  }

  private func loadObject(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  }

  private func loadArray(_ url: URL) throws -> [[String: Any]] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
  }

  private func lineCount(_ url: URL) throws -> Int {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
  }
}
#endif
