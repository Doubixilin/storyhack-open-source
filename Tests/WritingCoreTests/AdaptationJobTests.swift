import Foundation
import NovelDocumentCore
import Testing
@testable import WritingCore
import ZIPFoundation

private struct AdaptationFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("adaptation-" + UUID().uuidString)
  var store: AdaptationJobStore { AdaptationJobStore(rootURL: root.appendingPathComponent("jobs")) }
  var document: NovelDocument {
    let chapters = [
      NovelChapter(id: "river", ordinal: 0, title: "渡河", content: "林舟收起地图。她说：船留在岸边。\n老周修好了木桥。"),
      NovelChapter(id: "mountain", ordinal: 1, title: "入山", content: "第二天，林舟与老周进山。山中禁止点火。"),
    ]
    return NovelDocument(id: UUID(), title: "合成试验", sourceFormat: .text, sourceFileName: "合成.txt",
      contentHash: AdaptationCoding.hash(Data(chapters.map(\.content).joined().utf8)), chapters: chapters)
  }
  func bookcase(for job: AdaptationJob, complete: Bool = true) -> NovelBookcase {
    let river = BookcaseEvidence(chapterID: "river", quote: "林舟收起地图。")
    let mountain = BookcaseEvidence(chapterID: "mountain", quote: "山中禁止点火。")
    var character = BookcaseCharacter(id: "lin", name: "林舟", evidence: [river])
    character.identityCore = "旅行者"
    return NovelBookcase(meta: .init(sourceSnapshotHash: job.sourceSnapshotHash, extractorVersion: "synthetic-v1"),
      characters: [character],
      worldRules: [.init(id: "no-fire", name: "禁火", facts: ["山中禁止点火"], evidence: [mountain])],
      chapters: [.init(chapterID: "river", summary: "林舟准备渡河。", evidence: [river])]
        + (complete ? [.init(chapterID: "mountain", summary: "二人入山。", evidence: [mountain])] : []))
  }
  func approved(_ store: AdaptationJobStore) async throws -> (AdaptationJob, BookcaseProposal) {
    let initial = try await store.create(document: document)
    let pending = try await store.proposeBookcase(bookcase(for: initial), jobID: initial.id, expectedRevision: initial.revision)
    let current = try await store.load(initial.id)
    let approved = try await store.decideBookcase(jobID: initial.id, proposalID: pending.id,
      expectedRevision: current.revision, action: .approve)
    return (try await store.load(initial.id), approved)
  }
  func directory(_ id: UUID) -> URL { root.appendingPathComponent("jobs/\(id.uuidString.lowercased()).adaptationjob") }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct AdaptationJobTests {
  @Test func importedTextIsSelfContainedAndTamperingStopsUse() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let source = fixture.root.appendingPathComponent("纯合成小说.txt")
    let original = Data("第一章 起程\n林舟走到岸边。\n第二章 回信\n一封信送到了。".utf8)
    try original.write(to: source)
    let store = fixture.store, job = try await store.create(from: source)
    try FileManager.default.removeItem(at: source)
    let reopened = fixture.store
    let document = try await reopened.source(job.id)
    #expect(document.sourceFileName == "纯合成小说.txt")
    let archived = try #require(try await reopened.originalFileURL(job.id))
    #expect(try Data(contentsOf: archived) == original)
    try Data("伪造".utf8).write(to: archived)
    await #expect(throws: AdaptationError.invalidSource) { try await reopened.originalFileURL(job.id) }
    let snapshot = fixture.directory(job.id).appendingPathComponent("input/document.json")
    try Data("{}".utf8).write(to: snapshot)
    await #expect(throws: AdaptationError.invalidSource) { try await reopened.source(job.id) }
    #expect(try await reopened.load(job.id) == job)
  }

  @Test func syntheticEPUBArchiveBytesAndHrefsSurviveImport() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let tree = fixture.root.appendingPathComponent("epub-content")
    let files = [
      "mimetype": "application/epub+zip",
      "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>",
      "OPS/book.opf": "<package><metadata><title>合成山路</title></metadata><manifest><item id=\"c1\" href=\"Text/one.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/></spine></package>",
      "OPS/Text/one.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>出发</title></head><body><h1>出发</h1><p id=\"first\">林舟启程。</p><a href=\"#first\">返回</a></body></html>",
      "OPS/style.css": "body { color: #123; }",
    ]
    for (path, text) in files {
      let url = tree.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    let source = fixture.root.appendingPathComponent("合成.epub")
    try FileManager.default.zipItem(at: tree, to: source, shouldKeepParent: false)
    let expected = try Data(contentsOf: source)
    let store = fixture.store, job = try await store.create(from: source)
    try FileManager.default.removeItem(at: tree); try FileManager.default.removeItem(at: source)
    let archived = try #require(try await store.originalFileURL(job.id))
    #expect(try Data(contentsOf: archived) == expected)
    #expect(try await store.source(job.id).chapters[0].sourceHref == "OPS/Text/one.xhtml")
    let detached = try await store.create(document: fixture.document)
    #expect(try await store.originalFileURL(detached.id) == nil)
  }

  @Test func unsafeOrDuplicateChapterIdentityIsRejectedWithoutCreatingJob() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, source = fixture.document
    for chapters in [
      [source.chapters[0], source.chapters[0]],
      [NovelChapter(id: "../elsewhere", ordinal: 0, title: "错", content: "字")],
      [NovelChapter(id: "c", ordinal: 8, title: "错", content: "字")],
      [NovelChapter(id: "c", ordinal: 0, title: "错", content: "字", characterCount: 4)],
    ] {
      let bad = NovelDocument(id: source.id, title: source.title, sourceFormat: .text, sourceFileName: "a.txt",
        contentHash: source.contentHash, chapters: chapters)
      await #expect(throws: AdaptationError.invalidSource) { try await store.create(document: bad) }
    }
    #expect(try await store.list().isEmpty)
  }

  @Test func exactUnicodeQuoteRequiresUnambiguousValidLocation() throws {
    let fixture = AdaptationFixture(), source = fixture.document
    let anchored = try BookcaseEvidence(chapterID: "river", quote: "她说：船留在岸边。").anchored(in: source)
    #expect(try anchored.anchor?.resolve(in: source) == anchored.quote)
    #expect(anchored.utf16Location == 7)
    for evidence in [
      BookcaseEvidence(chapterID: "river", quote: "她说：船留在海边。"),
      BookcaseEvidence(chapterID: "missing", quote: "林舟收起地图。"),
      BookcaseEvidence(chapterID: "river", quote: "林舟", utf16Location: Int.max),
      BookcaseEvidence(chapterID: "river", quote: "林舟", utf16Location: -1),
    ] { #expect(throws: AdaptationError.evidenceMismatch) { try evidence.anchored(in: source) } }
    let repeated = NovelDocument(id: source.id, title: "重复", sourceFormat: .text, sourceFileName: "b.txt",
      contentHash: source.contentHash, chapters: [.init(id: "c", ordinal: 0, title: "c", content: "👩🏽‍🚀哈哈哈，终点")])
    #expect(throws: AdaptationError.evidenceMismatch) { try BookcaseEvidence(chapterID: "c", quote: "哈哈").anchored(in: repeated) }
    let offset = "👩🏽‍🚀哈".utf16.count
    #expect(try BookcaseEvidence(chapterID: "c", quote: "哈哈", utf16Location: offset).anchored(in: repeated).utf16Location == offset)
    #expect(throws: AdaptationError.evidenceMismatch) { try BookcaseEvidence(chapterID: "c", quote: "哈", utf16Location: 1).anchored(in: repeated) }
  }

  @Test func canonicalIDsWinOverModelOrdinalsAndCrossChapterQuotesFail() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let source = fixture.document, job = try await fixture.store.create(document: source)
    var bookcase = fixture.bookcase(for: job)
    bookcase.chapters.reverse(); bookcase.chapters[0].ordinal = 99; bookcase.chapters[0].title = "模型错题"
    let normalized = try bookcase.validated(in: source, snapshotHash: job.sourceSnapshotHash)
    #expect(normalized.chapters.map(\.chapterID) == ["river", "mountain"])
    #expect(normalized.chapters.map(\.ordinal) == [0, 1])
    #expect(normalized.chapters[1].title == "入山")
    bookcase.chapters[0].evidence = [BookcaseEvidence(chapterID: "river", quote: "林舟收起地图。")]
    #expect(throws: AdaptationError.evidenceMismatch) { try bookcase.validated(in: source, snapshotHash: job.sourceSnapshotHash) }
    bookcase.chapters = [.init(chapterID: "chapter-2", summary: "假定第二章", evidence: [])]
    #expect(throws: AdaptationError.invalidBookcase) { try bookcase.validated(in: source, snapshotHash: job.sourceSnapshotHash) }
    bookcase = fixture.bookcase(for: job); bookcase.characters[0].sampleLines = ["虚构台词"]
    #expect(throws: AdaptationError.evidenceMismatch) { try bookcase.validated(in: source, snapshotHash: job.sourceSnapshotHash) }
  }

  @Test func optionalFieldsDefaultButWrongTypesAndUnsupportedSchemaDoNot() throws {
    let raw = Data(#"{"schema_version":1,"meta":{"source_snapshot_hash":"h","extractor_version":"v1"},"characters":[{"id":"a","name":"同名"}]}"#.utf8)
    let result = try AdaptationCoding.decoder().decode(NovelBookcase.self, from: raw)
    #expect(result.relationships.isEmpty && result.worldRules.isEmpty && result.chapters.isEmpty)
    #expect(result.characters[0].speechStyle.isEmpty && result.characters[0].relationshipProgress.isEmpty)
    #expect(result.meta.manualCharacterIDs.isEmpty)
    let encoded = String(decoding: try AdaptationCoding.encoder().encode(result), as: UTF8.self)
    #expect(encoded.contains("identity_core") && !encoded.contains("identityCore"))
    #expect(throws: (any Error).self) {
      try AdaptationCoding.decoder().decode(NovelBookcase.self, from: Data(#"{"schema_version":1,"meta":{},"characters":false}"#.utf8))
    }
    let defaults = try AdaptationCoding.decoder().decode(AdaptationDirectionContract.self, from: Data("{}".utf8))
    #expect(defaults == AdaptationDirectionContract())
    #expect(defaults.minimumCharacterCount == 1_200)
  }

  @Test func manualLegacyCardsReplaceExplicitIDsAndCannotMasqueradeAsExtraction() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document)
    let legacy = Data(#"{"name":"林舟","voice_style":"短句","identity_core":"作者指定为船匠","sample_lines":[]}"#.utf8)
    let first = try BookcaseCharacter.importLegacy(legacy, characterID: "lin")
    let second = try BookcaseCharacter.importLegacy(legacy, characterID: "another-lin")
    let updated = try fixture.bookcase(for: job).applyingManualCharacters([first, second])
    #expect(updated.characters.count == 2)
    #expect(updated.characters[0].identityCore == "作者指定为船匠")
    #expect(updated.characters[0].speechStyle == "短句")
    #expect(updated.characters[0].evidence.isEmpty)
    #expect(updated.meta.manualCharacterIDs == ["another-lin", "lin"])
    await #expect(throws: AdaptationError.invalidBookcase) {
      try await store.proposeBookcase(updated, jobID: job.id, expectedRevision: job.revision)
    }
    let pending = try await store.proposeBookcase(updated, jobID: job.id, expectedRevision: job.revision, authorRevision: true)
    #expect(pending.status == .pending)
    #expect(try await store.load(job.id).approvedBookcaseID == nil)
  }

  @Test func partialBookcaseNeedsExplicitGapAcknowledgementAndImmutableDecision() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document)
    let pending = try await store.proposeBookcase(fixture.bookcase(for: job, complete: false),
      jobID: job.id, expectedRevision: job.revision)
    let current = try await store.load(job.id)
    await #expect(throws: AdaptationError.invalidBookcase) {
      try await store.decideBookcase(jobID: job.id, proposalID: pending.id, expectedRevision: current.revision, action: .approve)
    }
    await #expect(throws: AdaptationError.staleEdit) {
      try await store.decideBookcase(jobID: job.id, proposalID: pending.id, expectedRevision: job.revision,
        action: .approve, acknowledgeMissingChapters: true)
    }
    let approved = try await store.decideBookcase(jobID: job.id, proposalID: pending.id,
      expectedRevision: current.revision, action: .approve, note: "稍后补齐", acknowledgeMissingChapters: true)
    let event = try await store.approval(jobID: job.id, proposalID: pending.id)
    #expect(event.note?.contains("mountain") == true)
    let retry = try await store.decideBookcase(jobID: job.id, proposalID: pending.id,
      expectedRevision: current.revision, action: .approve)
    #expect(retry == approved)
    #expect(try await store.approval(jobID: job.id, proposalID: pending.id) == event)
    await #expect(throws: AdaptationError.alreadyDecided) {
      try await store.decideBookcase(jobID: job.id, proposalID: pending.id, expectedRevision: current.revision, action: .reject)
    }
  }

  @Test func rejectedOrPendingBookcasesCannotCreateDirectionAndProposalRetriesAreExact() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document)
    await #expect(throws: AdaptationError.missingBookcase) {
      try await store.createVariant(jobID: job.id, title: "方向", contract: .init(), expectedRevision: job.revision)
    }
    let content = fixture.bookcase(for: job), id = UUID()
    let proposal = try await store.proposeBookcase(content, jobID: job.id, expectedRevision: job.revision, proposalID: id)
    #expect(try await store.proposeBookcase(content, jobID: job.id, expectedRevision: job.revision, proposalID: id) == proposal)
    var changed = content; changed.characters[0].identityCore = "另一种解读"
    await #expect(throws: AdaptationError.staleEdit) {
      try await store.proposeBookcase(changed, jobID: job.id, expectedRevision: job.revision, proposalID: id)
    }
    let current = try await store.load(job.id)
    _ = try await store.decideBookcase(jobID: job.id, proposalID: id, expectedRevision: current.revision, action: .reject)
    let rejected = try await store.load(job.id)
    await #expect(throws: AdaptationError.missingBookcase) {
      try await store.createVariant(jobID: job.id, title: "方向", contract: .init(), expectedRevision: rejected.revision)
    }
  }

  @Test func allDirectionFieldsAffectCanonicalHashAndInvalidValuesFail() throws {
    let initial = AdaptationDirectionContract(), baseline = try initial.fingerprint()
    let edits: [(inout AdaptationDirectionContract) -> Void] = [
      { $0.mode = .abridge }, { $0.protagonistIDs = ["lin"] }, { $0.viewpoint = "第一人称" },
      { $0.identityInvariants = ["不撒谎"] }, { $0.relationshipDirection = "朋友" }, { $0.allowNewRelationships = true },
      { $0.plotIntensity = 5 }, { $0.eventMobility = .reorder }, { $0.ironEvents = ["必须渡河"] },
      { $0.allowDropEvents = true }, { $0.allowedAdditions = ["旁白"] }, { $0.forbiddenAdditions = ["新人物"] },
      { $0.targetCharacterCount = 2_000 }, { $0.minimumCharacterCount = 1_000 },
      { $0.maximumCharacterCount = 2_000 },
      { $0.originalRetentionPercent = 50 }, { $0.includeOriginalChapter = false }, { $0.style = "简练" }, { $0.notes = "作者意见" },
    ]
    var hashes: Set<String> = [baseline]
    for edit in edits {
      var changed = initial; edit(&changed)
      #expect(hashes.insert(try changed.fingerprint()).inserted)
    }
    let roundtrip = try AdaptationCoding.decoder().decode(AdaptationDirectionContract.self, from: AdaptationCoding.encoder().encode(initial))
    #expect(try roundtrip.fingerprint() == baseline)
    var bad = initial; bad.minimumCharacterCount = 20_001
    #expect(throws: AdaptationError.invalidContract) { try bad.validated() }
    bad = initial; bad.protagonistIDs = ["unknown"]
    #expect(throws: AdaptationError.invalidContract) { try bad.validated(characterIDs: ["lin"]) }
  }

  @Test func maximumLengthIsOptionalAndRejectsConflictingContractBounds() throws {
    let legacy = try AdaptationCoding.decoder().decode(AdaptationDirectionContract.self,
      from: Data(#"{"minimum_character_count":500,"target_character_count":650}"#.utf8))
    #expect(legacy.maximumCharacterCount == nil)
    let encoded = try AdaptationCoding.encoder().encode(legacy)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("maximum_character_count"))
    var contract = legacy
    for limit in [0, 499, 649, 20_001] {
      contract.maximumCharacterCount = limit
      #expect(throws: AdaptationError.invalidContract) { try contract.validated() }
    }
    contract.maximumCharacterCount = 700
    let roundtrip = try AdaptationCoding.decoder().decode(AdaptationDirectionContract.self,
      from: AdaptationCoding.encoder().encode(contract))
    #expect(roundtrip.maximumCharacterCount == 700)
    #expect(try roundtrip.fingerprint() != legacy.fingerprint())
    contract.maximumCharacterCount = 650
    #expect(try contract.validated().maximumCharacterCount == 650)
    contract.maximumCharacterCount = nil
    #expect(try contract.fingerprint() == legacy.fingerprint())
  }

  @Test func variantsShareSourceButRetainTheirOwnVersionsAndBookcaseBindings() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, (job, approved) = try await fixture.approved(store)
    let a = try await store.createVariant(jobID: job.id, title: "精简版", contract: .init(), expectedRevision: job.revision)
    let afterA = try await store.load(job.id)
    let b = try await store.createVariant(jobID: job.id, title: "扩写版", contract: .init(), expectedRevision: afterA.revision)
    let basisA = try await store.generationBasis(jobID: job.id, variantID: a.id)
    let basisB = try await store.generationBasis(jobID: job.id, variantID: b.id)
    var direction = AdaptationDirectionContract(); direction.mode = .abridge; direction.protagonistIDs = ["lin"]
    let edited = try await store.updateDirection(jobID: job.id, variantID: a.id,
      expectedContractRevisionID: a.contractRevisionID, contract: direction)
    let revision = try await store.direction(jobID: job.id, revisionID: edited.contractRevisionID)
    #expect(revision.parentID == a.contractRevisionID)
    #expect(try await store.direction(jobID: job.id, revisionID: a.contractRevisionID).contract == .init())
    #expect(try await store.generationBasis(jobID: job.id, variantID: a.id) != basisA)
    #expect(try await store.generationBasis(jobID: job.id, variantID: b.id) == basisB)
    await #expect(throws: AdaptationError.staleEdit) {
      try await store.updateDirection(jobID: job.id, variantID: a.id, expectedContractRevisionID: a.contractRevisionID, contract: direction)
    }
    let noOp = try await store.updateDirection(jobID: job.id, variantID: a.id,
      expectedContractRevisionID: edited.contractRevisionID, contract: direction)
    #expect(noOp == edited)
    let current = try await store.load(job.id)
    var newer = approved.content; newer.characters[0].identityCore = "经作者核对的旅行者"
    let proposal = try await store.proposeBookcase(newer, jobID: job.id, expectedRevision: current.revision, parentID: approved.id)
    let beforeApproval = try await store.load(job.id)
    _ = try await store.decideBookcase(jobID: job.id, proposalID: proposal.id,
      expectedRevision: beforeApproval.revision, action: .approve)
    #expect(try await store.generationBasis(jobID: job.id, variantID: b.id) == basisB)
    let rebound = try await store.updateDirection(jobID: job.id, variantID: b.id,
      expectedContractRevisionID: b.contractRevisionID, contract: .init(), bookcaseID: proposal.id)
    #expect(rebound.bookcaseID == proposal.id)
    #expect(try await store.direction(jobID: job.id, revisionID: b.contractRevisionID).bookcaseID == approved.id)
    #expect(try await fixture.store.load(job.id).variants == store.load(job.id).variants)
  }

  @Test func concurrentStoreActorsCannotBothCommitSameContractBase() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, (job, _) = try await fixture.approved(store)
    let variant = try await store.createVariant(jobID: job.id, title: "方向", contract: .init(), expectedRevision: job.revision)
    let success = await withTaskGroup(of: Bool.self) { group in
      for index in 0..<8 {
        group.addTask {
          var contract = AdaptationDirectionContract(); contract.notes = "编辑 \(index)"
          do {
            _ = try await fixture.store.updateDirection(jobID: job.id, variantID: variant.id,
              expectedContractRevisionID: variant.contractRevisionID, contract: contract)
            return true
          } catch { return false }
        }
      }
      var successes = 0
      for await value in group { if value { successes += 1 } }
      return successes
    }
    #expect(success == 1)
  }

  @Test func returningToOldContractContentStillChangesGenerationBasisAndRejectsABAEdit() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, (job, _) = try await fixture.approved(store)
    let initial = try await store.createVariant(jobID: job.id, title: "方向", contract: .init(), expectedRevision: job.revision)
    let initialBasis = try await store.generationBasis(jobID: job.id, variantID: initial.id)
    var changed = AdaptationDirectionContract(); changed.notes = "一度改动"
    let middle = try await store.updateDirection(jobID: job.id, variantID: initial.id,
      expectedContractRevisionID: initial.contractRevisionID, contract: changed)
    _ = try await store.updateDirection(jobID: job.id, variantID: initial.id,
      expectedContractRevisionID: middle.contractRevisionID, contract: .init())
    let finalBasis = try await store.generationBasis(jobID: job.id, variantID: initial.id)
    #expect(finalBasis.contractHash == initialBasis.contractHash)
    #expect(finalBasis != initialBasis)
    await #expect(throws: AdaptationError.staleEdit) {
      try await store.updateDirection(jobID: job.id, variantID: initial.id,
        expectedContractRevisionID: initial.contractRevisionID, contract: changed)
    }
  }

  @Test func unsupportedSchemaUnknownRelationshipsAndMissingEvidenceCannotBecomeCandidates() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document)
    let valid = fixture.bookcase(for: job)
    var unknown = valid
    unknown.relationships = [.init(id: "r", a: "lin", b: "missing", summary: "未知关系", evidence: valid.characters[0].evidence)]
    var unsupported = valid; unsupported.characters[0].evidence = []
    var duplicate = valid; duplicate.characters.append(valid.characters[0])
    for malformed in [unknown, unsupported, duplicate] {
      await #expect(throws: AdaptationError.invalidBookcase) {
        try await store.proposeBookcase(malformed, jobID: job.id, expectedRevision: job.revision)
      }
    }
    var object = try #require(JSONSerialization.jsonObject(with: AdaptationCoding.encoder().encode(valid)) as? [String: Any])
    object["schema_version"] = 99
    let incompatible = try AdaptationCoding.decoder().decode(NovelBookcase.self, from: JSONSerialization.data(withJSONObject: object))
    await #expect(throws: AdaptationError.invalidBookcase) {
      try await store.proposeBookcase(incompatible, jobID: job.id, expectedRevision: job.revision)
    }
    #expect(try await store.bookcases(job.id).isEmpty)
    #expect(try await store.load(job.id).revision == job.revision)
  }

  @Test func symlinkAndCorruptPackagesAreRetainedWithoutFollowingOrHidingHealthyJobs() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, good = try await store.create(document: fixture.document)
    let bad = try await store.create(document: fixture.document)
    let target = fixture.root.appendingPathComponent("outside.json")
    try Data("untouched".utf8).write(to: target)
    let document = fixture.directory(bad.id).appendingPathComponent("input/document.json")
    try FileManager.default.removeItem(at: document)
    try FileManager.default.createSymbolicLink(at: document, withDestinationURL: target)
    await #expect(throws: AdaptationError.corruptPackage) { try await store.source(bad.id) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    try Data("{}".utf8).write(to: fixture.directory(bad.id).appendingPathComponent("job.json"))
    #expect(try await store.list().map(\.id) == [good.id])
    #expect(await store.listDiagnostics.count == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.directory(bad.id).path))
  }

  @Test func missingApprovalOrModifiedContractNeverEntersGenerationBasis() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, (job, approved) = try await fixture.approved(store)
    let variant = try await store.createVariant(jobID: job.id, title: "方向", contract: .init(), expectedRevision: job.revision)
    let approvalURL = fixture.directory(job.id).appendingPathComponent("approvals/\(approved.id.uuidString.lowercased()).json")
    let bytes = try Data(contentsOf: approvalURL)
    try FileManager.default.removeItem(at: approvalURL)
    await #expect(throws: AdaptationError.corruptPackage) { try await store.generationBasis(jobID: job.id, variantID: variant.id) }
    try bytes.write(to: approvalURL)
    let contractURL = fixture.directory(job.id).appendingPathComponent("contracts/\(variant.contractRevisionID.uuidString.lowercased()).json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any])
    var content = try #require(object["contract"] as? [String: Any]); content["notes"] = "悄悄改写"; object["contract"] = content
    try JSONSerialization.data(withJSONObject: object).write(to: contractURL)
    await #expect(throws: AdaptationError.corruptPackage) { try await store.generationBasis(jobID: job.id, variantID: variant.id) }
  }

  @Test func journalRecoveryRollsBackInterruptedBookcaseApprovalTogether() async throws {
    let fixture = AdaptationFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document)
    let proposal = try await store.proposeBookcase(fixture.bookcase(for: job), jobID: job.id, expectedRevision: job.revision)
    let root = fixture.directory(job.id)
    let jobURL = root.appendingPathComponent("job.json")
    let proposalURL = root.appendingPathComponent("bookcases/\(proposal.id.uuidString.lowercased()).json")
    let approvalURL = root.appendingPathComponent("approvals/\(proposal.id.uuidString.lowercased()).json")
    let oldJob = try Data(contentsOf: jobURL), oldProposal = try Data(contentsOf: proposalURL)
    let journal = fixture.root.appendingPathComponent("jobs/.replacement-journals/update-test")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    try oldJob.write(to: journal.appendingPathComponent("backup-0")); try oldProposal.write(to: journal.appendingPathComponent("backup-1"))
    let entries: [[String: Any]] = [
      ["path": jobURL.path, "backupName": "backup-0"], ["path": proposalURL.path, "backupName": "backup-1"], ["path": approvalURL.path],
    ]
    try JSONSerialization.data(withJSONObject: ["entries": entries, "createdAt": Date().timeIntervalSinceReferenceDate])
      .write(to: journal.appendingPathComponent("manifest.json"))
    try Data("broken job".utf8).write(to: jobURL); try Data("broken proposal".utf8).write(to: proposalURL)
    try FileManager.default.createDirectory(at: approvalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("partial approval".utf8).write(to: approvalURL)
    #expect(try await fixture.store.load(job.id).approvedBookcaseID == nil)
    #expect(try Data(contentsOf: jobURL) == oldJob)
    #expect(try Data(contentsOf: proposalURL) == oldProposal)
    #expect(!FileManager.default.fileExists(atPath: approvalURL.path))
    #expect(try await store.bookcases(job.id)[0].status == .pending)
  }
}
