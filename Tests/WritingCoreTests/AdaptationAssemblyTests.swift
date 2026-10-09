import DirectoryJournalCore
import Foundation
import LibraryCore
import NovelDocumentCore
import Testing
@testable import WritingCore
import ZIPFoundation

private struct AssemblyFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("assembly-" + UUID().uuidString)
  var store: AdaptationJobStore { .init(rootURL: root.appendingPathComponent("jobs")) }
  var sourceURL: URL { root.appendingPathComponent("合成书.epub") }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func setup(epub: Bool = true) async throws -> (AdaptationJob, AdaptationVariant) {
    let store = store
    let job: AdaptationJob
    if epub {
      let values = [
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>",
        "OPS/book.opf": "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"old-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>原书</dc:title><dc:identifier id=\"old-id\">original</dc:identifier></metadata><manifest><item id=\"second-file\" href=\"Text/二.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"first-file\" href=\"Text/one.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"untouched\" href=\"Text/three.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"navigation/nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"ncx\" href=\"navigation/toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/></manifest><spine toc=\"ncx\"><itemref idref=\"first-file\"/><itemref idref=\"second-file\"/><itemref idref=\"untouched\"/></spine></package>",
        "OPS/Text/one.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>渡河</title><link rel=\"stylesheet\" href=\"../style.css\"/></head><body class=\"novel\"><h1 id=\"heading\">渡河</h1><p id=\"start\">林舟收起地图。</p><p>她走向岸边😀。</p></body></html>",
        "OPS/Text/二.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>入山</title></head><body><h1>入山</h1><p>老周进入山中。</p><a href=\"one.xhtml#start\">返回渡河</a></body></html>",
        "OPS/Text/three.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>来信</title></head><body><h1>来信</h1><p>林舟读完来信。</p></body></html>",
        "OPS/navigation/nav.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>原导航</title></head><body><nav epub:type=\"toc\"><h1>目录</h1><ol><li>旧目录</li></ol></nav><nav epub:type=\"landmarks\" id=\"landmarks\"><ol><li><a href=\"../Text/one.xhtml#start\">开篇</a></li></ol></nav></body></html>",
        "OPS/navigation/toc.ncx": "<ncx><head><meta name=\"custom\" content=\"keep\"/></head><navMap/><pageList id=\"pages\"><navLabel><text>原页码</text></navLabel></pageList></ncx>",
        "OPS/style.css": "body.novel { color: #123; font-size: 1.2em; }",
        "OPS/assets/data.bin": "untouched-binary-fixture",
      ]
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let archive = try Archive(url: sourceURL, accessMode: .create)
      for key in ["mimetype"] + values.keys.filter({ $0 != "mimetype" }).sorted() {
        let bytes = Data(try #require(values[key]).utf8)
        try archive.addEntry(with: key, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .none) { position, size in
          bytes.subdata(in: Int(position)..<Int(position) + size)
        }
      }
      job = try await store.create(from: sourceURL)
    } else {
      let chapters = [NovelChapter(id: "a", ordinal: 0, title: "渡河", content: "林舟收起地图。她走向岸边😀。"),
        NovelChapter(id: "b", ordinal: 1, title: "入山", content: "老周进入山中。")]
      job = try await store.create(document: .init(id: UUID(), title: "合成", sourceFormat: .text, sourceFileName: "合成.txt",
        contentHash: AdaptationCoding.hash(Data("synthetic".utf8)), chapters: chapters))
    }
    var contract = AdaptationDirectionContract(); contract.minimumCharacterCount = 1; contract.targetCharacterCount = 100
    let variant = try await store.createStandaloneVariant(jobID: job.id, title: "新方向 & <试验>", contract: contract, expectedRevision: job.revision)
    return (job, variant)
  }
  func propose(_ job: AdaptationJob, _ variant: AdaptationVariant, target: AdaptationDraftTarget, body: String,
    title: String = "新正文", approve: Bool = true) async throws -> AdaptationDraft {
    let store = store
    let context = try await store.draftContext(jobID: job.id, variantID: variant.id, target: target)
    let snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    let old = snapshot.current.first { $0.draft.context.target == target }?.draft.id
    let draft = try await store.proposeDraft(context: context, content: .init(title: title, body: body, recap: "合成摘要",
      reviewLine: "保留因果 <script>不可执行</script>", recipe: .init(trigger: target.key, setting: "合成地点", technique: "白描")),
      generatorFingerprint: "fixture", expectedHeadID: old)
    if approve {
      let state = try await store.drafts(jobID: job.id, variantID: variant.id)
      _ = try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: draft.id, expectedRevision: state.revision, action: .approve)
    }
    return draft
  }
  func anchor(_ job: AdaptationJob, chapterID: String, quote: String, action: AdaptationAnchorAction) async throws -> AdaptationDraftTarget {
    let store = store, map = try await store.anchorMap(job.id)
    let added = try await store.addManualAnchor(jobID: job.id, expectedRevision: map.revision,
      candidate: .init(chapterID: chapterID, quote: quote, note: "合成锚点"))
    let anchor = try #require(added.anchors.last)
    _ = try await store.reviewAnchor(jobID: job.id, anchorID: anchor.id, expectedRevision: added.revision, action: .approve, generationAction: action)
    return .init(chapterID: chapterID, anchorID: anchor.id)
  }
  func prepare(_ job: AdaptationJob, _ variant: AdaptationVariant) async throws -> AdaptationAssembly {
    let store = store, snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    return try await store.prepareAssembly(jobID: job.id, variantID: variant.id, expectedDraftRevision: snapshot.revision)
  }
}
private func entry(_ path: String, in url: URL) throws -> Data {
  let archive = try Archive(url: url, accessMode: .read), item = try #require(archive[path])
  var bytes = Data(); _ = try archive.extract(item) { bytes.append($0) }; return bytes
}

@Suite struct AdaptationAssemblyTests {
  @Test func publicationFailureAndBusyDestinationReleaseSourceLockAndPreserveOldBook() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(epub: false), store = f.store
    let libraryRoot = f.root.appendingPathComponent("library")
    let library = NovelLibrary(rootURL: libraryRoot)
    _ = try await f.propose(job, variant, target: .init(chapterID: "a"), body: "已经出版的旧稿。")
    let first = try await f.prepare(job, variant)
    _ = try await library.publishAdaptation(first, store: store, acknowledgeUnchangedChapters: true)
    _ = try await f.propose(job, variant, target: .init(chapterID: "a"), body: "新批准的正文。")
    let second = try await f.prepare(job, variant)

    let occupied = try DirectoryProcessLease(directoryURL: libraryRoot, name: ".directory-access.lock")
    defer { occupied.release() }
    await #expect(throws: DirectoryProcessLockError.busy) {
      try await library.publishAdaptation(second, store: store, acknowledgeUnchangedChapters: true)
    }
    occupied.release()
    try await store.validateAssembly(second, acknowledgeUnchangedChapters: true)

    let failure = PublicationInterceptionFileManager(
      destination: libraryRoot.appendingPathComponent(variant.id.uuidString.lowercased())
    ) { throw PublicationInstallFailure.injected }
    let brokenLibrary = NovelLibrary(rootURL: libraryRoot, fileManager: failure)
    await #expect(throws: PublicationInstallFailure.injected) {
      try await brokenLibrary.publishAdaptation(second, store: store, acknowledgeUnchangedChapters: true)
    }
    #expect(try await library.load(documentID: variant.id).document.chapters[0].content == "已经出版的旧稿。")
    #expect(try await library.publicationBackupCount(for: variant.id) == 0)
    try await store.validateAssembly(second, acknowledgeUnchangedChapters: true)
    let retry = try await library.publishAdaptation(second, store: store, acknowledgeUnchangedChapters: true)
    #expect(retry.document.chapters[0].content == "新批准的正文。")
    #expect(try await library.publicationBackupCount(for: variant.id) == 1)
    #expect(try await store.load(job.id).sourceSnapshotHash == job.sourceSnapshotHash)
  }

  @Test func publicationKeepsApprovalStableUntilTheLibraryInstallCompletes() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(epub: false), store = f.store
    let original = try await f.propose(job, variant, target: .init(chapterID: "a"), body: "已批准的一稿。")
    let assembly = try await f.prepare(job, variant)
    let jobRoot = await store.rootURL
    let index = jobRoot.appendingPathComponent("\(job.id.uuidString.lowercased()).adaptationjob/drafts/\(variant.id.uuidString.lowercased())/index.json")
    let approvedIndex = try Data(contentsOf: index)
    var edit = original.content; edit.body = "作者随后修改，尚未批准。"
    let revision = try await store.reviseDraft(jobID: job.id, variantID: variant.id, draftID: original.id, content: edit)
    let replacement = f.root.appendingPathComponent("pending-index.json")
    try Data(contentsOf: index).write(to: replacement)
    // Prepare a legitimate next index, then rewind only this synthetic fixture.
    // The child writer will try to select it at the exact library move boundary.
    try approvedIndex.write(to: index, options: .atomic)
    let libraryRoot = f.root.appendingPathComponent("library")
    let observed = PublicationProbeResult()
    let fileManager = PublicationInterceptionFileManager(
      destination: libraryRoot.appendingPathComponent(variant.id.uuidString.lowercased())
    ) {
      observed.set(try publicationIndexWriter(root: jobRoot, index: index, replacement: replacement))
    }
    let library = NovelLibrary(rootURL: libraryRoot, fileManager: fileManager)
    let published = try await library.publishAdaptation(assembly, store: store, acknowledgeUnchangedChapters: true)
    #expect(observed.value == "busy")
    #expect(published.document.chapters[0].content == original.content.body)
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.first?.draft.id == original.id)

    // After the commit the same cooperating child can edit. The old preview
    // must then fail, preserving the already installed book and its backups.
    #expect(try publicationIndexWriter(root: jobRoot, index: index, replacement: replacement) == "changed")
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.first?.draft.id == revision.id)
    await #expect(throws: AdaptationError.staleEdit) {
      try await library.publishAdaptation(assembly, store: store, acknowledgeUnchangedChapters: true)
    }
    #expect(try await library.load(documentID: variant.id).document.chapters[0].content == original.content.body)
    #expect(try await library.publicationBackupCount(for: variant.id) == 0)
  }

  @Test func approvedChapterAndNewChapterPreservePathsSpineAssetsAndBothNavigationFormats() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(), store = f.store, source = try await store.source(job.id)
    _ = try await f.propose(job, variant, target: .init(chapterID: source.chapters[0].id), body: "林舟停下脚步。\n\n她看着河水😀。", title: "新渡河")
    let target = try await f.anchor(job, chapterID: source.chapters[1].id, quote: "", action: .newChapter)
    _ = try await f.propose(job, variant, target: target, body: "山风吹过，老周继续前行。", title: "山路补章")
    let assembly = try await f.prepare(job, variant)
    #expect(assembly.unchangedChapterIDs == Array(source.chapters.dropFirst()).map(\.id))
    await #expect(throws: AdaptationAssemblyError.unchangedChapters) { try await store.exportAssembly(assembly) }
    let exported = try await store.exportAssembly(assembly, acknowledgeUnchangedChapters: true)
    #expect(exported.epubURL.lastPathComponent == "合成书.epub")
    let parsed = try EPUBNovelParser().parse(at: exported.epubURL)
    #expect(parsed.chapters.map(\.title) == ["新渡河", "入山", "山路补章", "来信"])
    #expect(parsed.chapters[0].sourceHref == "OPS/Text/one.xhtml")
    #expect(parsed.chapters[1].sourceHref == "OPS/Text/二.xhtml")
    for name in ["OPS/Text/二.xhtml", "OPS/Text/three.xhtml", "OPS/style.css", "OPS/assets/data.bin"] {
      #expect(try entry(name, in: exported.epubURL) == entry(name, in: f.sourceURL))
    }
    let first = String(decoding: try entry("OPS/Text/one.xhtml", in: exported.epubURL), as: UTF8.self)
    #expect(first.contains("id=\"start\"") && first.contains("../style.css") && first.contains("class=\"novel\""))
    let opf = try AdaptationXML.parse(entry("OPS/book.opf", in: exported.epubURL))
    let refs = opf.descendants("itemref").compactMap { $0.attributes["idref"] }
    #expect(refs.filter { ["first-file", "second-file", "untouched"].contains($0) } == ["first-file", "second-file", "untouched"])
    #expect(opf.descendants("identifier").first?.string == "urn:uuid:" + variant.id.uuidString.lowercased())
    let nav = try AdaptationXML.parse(entry("OPS/navigation/nav.xhtml", in: exported.epubURL))
    let ncx = try AdaptationXML.parse(entry("OPS/navigation/toc.ncx", in: exported.epubURL))
    let toc = try #require(nav.descendants("nav").first), navMap = try #require(ncx.descendants("navmap").first)
    #expect(toc.descendants("a").map(\.string) == parsed.chapters.map(\.title))
    #expect(navMap.descendants("navlabel").map(\.string) == parsed.chapters.map(\.title))
    #expect(toc.descendants("a")[0].attributes["href"] == "../Text/one.xhtml")
    #expect(nav.descendants("nav").last?.descendants("a").first?.attributes["href"] == "../Text/one.xhtml#start")
    #expect(ncx.descendants("pagelist").first?.attributes["id"] == "pages")
    #expect(ncx.descendants("meta").contains { $0.attributes["name"] == "custom" && $0.attributes["content"] == "keep" })
    #expect(String(decoding: try Data(contentsOf: exported.comparisonURL), as: UTF8.self).contains("&lt;script&gt;"))
    #expect(try await store.exportAssembly(assembly, acknowledgeUnchangedChapters: true).epubURL == exported.epubURL)
    let archived = try #require(try await store.originalFileURL(job.id))
    #expect(try Data(contentsOf: archived) == Data(contentsOf: f.sourceURL))
  }

  @Test func insertionAndRewriteUseOriginalUTF16PositionsWithoutOverwritingSource() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(epub: false), store = f.store
    let before = try await f.anchor(job, chapterID: "a", quote: "", action: .insertion)
    _ = try await f.propose(job, variant, target: before, body: "清晨。", title: "过渡")
    let rewrite = try await f.anchor(job, chapterID: "a", quote: "她走向岸边😀。", action: .rewrite)
    _ = try await f.propose(job, variant, target: rewrite, body: "她留在原地。")
    let assembly = try await f.prepare(job, variant)
    #expect(assembly.chapters[0].content == "清晨。\n\n林舟收起地图。她留在原地。")
    #expect(try await store.source(job.id).chapters[0].content == "林舟收起地图。她走向岸边😀。")
    let output = try await store.exportAssembly(assembly, acknowledgeUnchangedChapters: true)
    #expect(try EPUBNovelParser().parse(at: output.epubURL).chapters[0].content == assembly.chapters[0].content)
    #expect(String(decoding: try Data(contentsOf: output.textURL), as: UTF8.self) == assembly.plainText)
  }

  @Test func unapprovedStaleAndUnselectedDependenciesCannotBecomeAnAssembly() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(epub: false), store = f.store
    let first = try await f.propose(job, variant, target: .init(chapterID: "a"), body: "第一章新文。", approve: false)
    await #expect(throws: AdaptationAssemblyError.unapprovedDrafts) { try await f.prepare(job, variant) }
    var snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    _ = try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: first.id, expectedRevision: snapshot.revision, action: .approve)
    let second = try await f.propose(job, variant, target: .init(chapterID: "b"), body: "第二章新文。")
    let preview = try await f.prepare(job, variant)
    snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    await #expect(throws: AdaptationAssemblyError.conflictingEdits) {
      try await store.prepareAssembly(jobID: job.id, variantID: variant.id, expectedDraftRevision: snapshot.revision, selectedDraftIDs: [second.id])
    }
    var edit = first.content; edit.recap = "改变前情"
    _ = try await store.reviseDraft(jobID: job.id, variantID: variant.id, draftID: first.id, content: edit)
    await #expect(throws: AdaptationError.staleEdit) { try await store.exportAssembly(preview) }
    await #expect(throws: AdaptationAssemblyError.unapprovedDrafts) { try await f.prepare(job, variant) }
  }

  @Test func overlappingQuoteReplacementsFailInsteadOfPickingOne() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(epub: false)
    let first = try await f.anchor(job, chapterID: "a", quote: "林舟收起", action: .rewrite)
    _ = try await f.propose(job, variant, target: first, body: "林舟展开")
    let second = try await f.anchor(job, chapterID: "a", quote: "收起地图", action: .rewrite)
    _ = try await f.propose(job, variant, target: second, body: "拿着地图")
    await #expect(throws: AdaptationAssemblyError.conflictingEdits) { try await f.prepare(job, variant) }
  }

  @Test func exportCacheTamperingIsNotSilentlyOverwritten() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(epub: false), store = f.store
    _ = try await f.propose(job, variant, target: .init(chapterID: "a"), body: "正文。")
    let preview = try await f.prepare(job, variant), output = try await store.exportAssembly(preview, acknowledgeUnchangedChapters: true)
    try Data("tampered".utf8).write(to: output.textURL)
    await #expect(throws: AdaptationError.corruptPackage) { try await store.exportAssembly(preview, acknowledgeUnchangedChapters: true) }
    #expect(try String(contentsOf: output.textURL, encoding: .utf8) == "tampered")
  }

  @Test func newChapterFilenameCollisionUsesAnotherNameAndRetainsExistingResource() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(), source = try await f.store.source(job.id)
    let target = try await f.anchor(job, chapterID: source.chapters[0].id, quote: "", action: .newChapter)
    _ = try await f.propose(job, variant, target: target, body: "独立新章。", title: "补章")
    let preview = try await f.prepare(job, variant)
    let collision = "OPS/adaptation-\(variant.id.uuidString.lowercased())-00002.xhtml", bytes = Data("reserved".utf8)
    do {
      let archive = try Archive(url: f.sourceURL, accessMode: .update)
      try archive.addEntry(with: collision, type: .file, uncompressedSize: Int64(bytes.count)) { position, size in bytes.subdata(in: Int(position)..<Int(position) + size) }
    }
    let output = f.root.appendingPathComponent("collision-result.epub")
    try AdaptationEPUBAssembler().write(preview, originalURL: f.sourceURL, to: output)
    #expect(try entry(collision, in: output) == bytes)
    #expect(try EPUBNovelParser().parse(at: output).chapters[1].sourceHref == collision.replacingOccurrences(of: ".xhtml", with: "-1.xhtml"))
  }

  @Test func maliciousArchivePathsAndEntityExpansionAreRejected() throws {
    let f = AssemblyFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
    let archive = try Archive(url: f.sourceURL, accessMode: .create), bytes = Data("x".utf8)
    try archive.addEntry(with: "../escape", type: .file, uncompressedSize: Int64(1)) { _, _ in bytes }
    let preview = AdaptationAssembly(jobID: UUID(), variantID: UUID(), sourceSnapshotHash: "", draftRevision: UUID(), title: "test", author: nil,
      selectedDraftIDs: [], unchangedChapterIDs: [], chapters: [], comparisonMarkdown: "")
    #expect(throws: AdaptationAssemblyError.unsafeArchive) {
      try AdaptationEPUBAssembler().write(preview, originalURL: f.sourceURL, to: f.root.appendingPathComponent("bad.epub"))
    }
    #expect(throws: AdaptationAssemblyError.invalidEPUB) {
      try AdaptationXML.parse(Data("<!DOCTYPE x [<!ENTITY z 'expanded'>]><x>&z;</x>".utf8))
    }
  }

  @Test func readerPublicationKeepsOriginalAndOtherDirectionAndUpdatesSameBookWithBackup() async throws {
    let f = AssemblyFixture(); defer { f.clean() }
    let (job, variant) = try await f.setup(), store = f.store
    let library = NovelLibrary(rootURL: f.root.appendingPathComponent("library"))
    let original = try await library.importDocument(from: f.sourceURL), source = try await store.source(job.id)
    let draft = try await f.propose(job, variant, target: .init(chapterID: source.chapters[0].id), body: "改编第一稿。")
    let first = try await f.prepare(job, variant)
    let publication = try await library.publishAdaptation(first, store: store, acknowledgeUnchangedChapters: true)
    #expect(publication.id == variant.id && publication.id != original.id)
    #expect(publication.document.sourceFormat == .epub && publication.document.chapters[0].sourceHref == "OPS/Text/one.xhtml")
    _ = try await library.publishAdaptation(first, store: store, acknowledgeUnchangedChapters: true)
    #expect(try await library.publicationBackupCount(for: variant.id) == 0)
    var edit = draft.content; edit.body = "改编第二稿。"
    let revised = try await store.reviseDraft(jobID: job.id, variantID: variant.id, draftID: draft.id, content: edit)
    let snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    _ = try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: revised.id, expectedRevision: snapshot.revision, action: .approve)
    let second = try await f.prepare(job, variant)
    let updated = try await library.publishAdaptation(second, store: store, acknowledgeUnchangedChapters: true)
    #expect(updated.id == publication.id && updated.document.chapters[0].content == "改编第二稿。")
    #expect(try await library.publicationBackupCount(for: variant.id) == 1)
    #expect(try await library.load(documentID: original.id).document.chapters[0].content == original.document.chapters[0].content)
    var contract = AdaptationDirectionContract(); contract.minimumCharacterCount = 1
    let other = try await store.createStandaloneVariant(jobID: job.id, title: "另一版", contract: contract, expectedRevision: store.load(job.id).revision)
    _ = try await f.propose(job, other, target: .init(chapterID: source.chapters[0].id), body: "另一个方向。")
    let third = try await f.prepare(job, other)
    _ = try await library.publishAdaptation(third, store: store, acknowledgeUnchangedChapters: true)
    #expect(try await library.list().count == 3)
    #expect(try await library.load(documentID: variant.id).document.chapters[0].content == "改编第二稿。")
  }
}

private enum PublicationInstallFailure: Error { case injected }

private final class PublicationProbeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?
  var value: String? { lock.withLock { stored } }
  func set(_ value: String) { lock.withLock { stored = value } }
}

private final class PublicationInterceptionFileManager: FileManager, @unchecked Sendable {
  let destination: URL
  let intercept: @Sendable () throws -> Void
  private let lock = NSLock()
  private var intercepted = false
  init(destination: URL, intercept: @escaping @Sendable () throws -> Void) {
    self.destination = destination; self.intercept = intercept
    super.init()
  }
  override func moveItem(at source: URL, to destination: URL) throws {
    if destination.standardizedFileURL.path == self.destination.standardizedFileURL.path {
      let first = lock.withLock { let first = !intercepted; intercepted = true; return first }
      if first { try intercept() }
    }
    try super.moveItem(at: source, to: destination)
  }
}

/// A cooperating writer in a separate process, attempting an atomic file
/// replacement under the same kernel lock used by the task store and CLI.
private func publicationIndexWriter(root: URL, index: URL, replacement: URL) throws -> String {
  let process = Process(), output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  process.arguments = ["-u", "-c", """
    import fcntl, os, signal, sys
    signal.alarm(10)
    fd = os.open(os.path.join(sys.argv[1], '.directory-access.lock'), os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('busy'); sys.exit(0)
    with open(sys.argv[3], 'rb') as source:
        data = source.read()
    temp = sys.argv[2] + '.probe-tmp'
    with open(temp, 'wb') as target:
        target.write(data)
    os.replace(temp, sys.argv[2])
    print('changed')
    """, root.path, index.path, replacement.path]
  process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
  process.standardOutput = output; process.standardError = FileHandle.nullDevice
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
