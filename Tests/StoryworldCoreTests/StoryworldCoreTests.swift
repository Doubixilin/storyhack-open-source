import Foundation
import Testing

@testable import StoryworldCore

struct StoryworldCoreTests {
  @Test
  func playModesRecognizeLegacyAndNewBranchNames() {
    let playthroughID = UUID()
    func branch(_ title: String, parent: UUID? = UUID()) -> RuntimeBranchDescriptor {
      RuntimeBranchDescriptor(
        branch: BranchDescriptor(
          playthroughID: playthroughID,
          parentBranchID: parent,
          title: title
        ),
        sessionID: UUID(),
        baseStateHash: "hash"
      )
    }

    #expect(StoryPlayMode.infer(from: branch("主线", parent: nil)) == .canon)
    #expect(StoryPlayMode.infer(from: branch("godmode")) == .godMode)
    #expect(StoryPlayMode.infer(from: branch("God Mode")) == .godMode)
    #expect(StoryPlayMode.infer(from: branch("邪神线")) == .evilGod)
    #expect(StoryPlayMode.infer(from: branch("我的实验分支")) == nil)
  }

  @Test
  func manifestUsesVersionedSnakeCaseContract() throws {
    let manifest = StoryworldManifest(
      storyworldID: UUID(uuidString: "D86FB2C4-9C20-41D7-8C46-12EE522792E1")!,
      revision: 3,
      title: "测试故事世界",
      createdAt: Date(timeIntervalSince1970: 0),
      modifiedAt: Date(timeIntervalSince1970: 1)
    )

    let data = try StoryworldCoding.makeEncoder().encode(manifest)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let content = try #require(object["content"] as? [String: Any])

    #expect(object["format_version"] as? Int == 1)
    #expect(
      object["storyworld_id"] as? String
        == "D86FB2C4-9C20-41D7-8C46-12EE522792E1"
    )
    #expect(object["minimum_core_version"] as? String == "0.1.0")
    #expect(content["lorebook_entry"] as? String == "lorebook/lorebook.json")
  }

  @Test
  func validatesMinimalStoryworldPackage() throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "测试故事世界"),
      lorebook: Lorebook(
        title: "测试 Lorebook",
        entries: [LoreEntry(title: "地点", content: "这里是一座山城。")]
      )
    )

    let manifest = try StoryworldPackageValidator().validate(at: root)
    #expect(manifest.title == "测试故事世界")
  }

  @Test
  func runtimeRegistryReturnsSameStoreForStandardizedPackageURL() async {
    let root = temporaryURL(pathExtension: "storyworld")
    let registry = StoryworldRuntimeStoreRegistry()
    let first = await registry.store(forPackageURL: root)
    let second = await registry.store(
      forPackageURL: root.appendingPathComponent(".", isDirectory: true)
    )

    #expect(first === second)
  }

  @Test
  func runtimeRegistrySerializesConcurrentCommits() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "并发提交测试"),
      lorebook: Lorebook(title: "并发提交测试", entries: [])
    )
    let registry = StoryworldRuntimeStoreRegistry()
    let runtime = await registry.store(forPackageURL: root)
    let context = try await runtime.createPlaythrough(title: "主线")

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...100 {
        group.addTask {
          _ = try await runtime.commitTurn(
            address: context.address,
            turnID: UUID(),
            userMessage: "第 \(index) 步",
            narrative: "第 \(index) 回。"
          )
        }
      }
      try await group.waitForAll()
    }

    let logURL = eventLogURL(root: root, address: context.address)
    let records = try Data(contentsOf: logURL).split(separator: 0x0A)
    let events = try records.map {
      try StoryworldCoding.makeDecoder().decode(CommittedStoryTurn.self, from: Data($0))
    }
    #expect(records.count == 100)
    #expect(events.map(\.sequence) == Array(1...100))

    let stateURL = logURL.deletingLastPathComponent().appendingPathComponent("state.json")
    let stateObject = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    )
    #expect(stateObject["last_event_sequence"] as? Int == 100)
  }

  @Test
  func runtimeRegistryEvictionCreatesNewStore() async {
    let root = temporaryURL(pathExtension: "storyworld")
    let registry = StoryworldRuntimeStoreRegistry()
    let first = await registry.store(forPackageURL: root)
    await registry.evict(forPackageURL: root)
    let second = await registry.store(forPackageURL: root)

    #expect(first !== second)
  }

  @Test
  func rejectsLorebookPathTraversal() throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = StoryworldManifest(
      title: "不安全",
      content: .init(lorebookEntry: "../lorebook.json")
    )
    try StoryworldCoding.makeEncoder()
      .encode(manifest)
      .write(to: root.appendingPathComponent("manifest.json"))

    #expect(throws: StoryworldPackageValidationError.unsafeLorebookEntry) {
      try StoryworldPackageValidator().validate(at: root)
    }
  }

  @Test
  func rejectsInvalidLorebookInsidePackage() throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }

    let lorebook = Lorebook(
      title: "重复条目",
      entries: [
        LoreEntry(id: "same", title: "甲", content: "内容甲"),
        LoreEntry(id: "same", title: "乙", content: "内容乙"),
      ]
    )
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "测试故事世界"),
      lorebook: lorebook
    )

    #expect(
      throws: StoryworldPackageValidationError.invalidLorebook(.duplicateEntryID("same"))
    ) {
      try StoryworldPackageValidator().validate(at: root)
    }
  }

  @Test
  func importsNovelAIShapedLorebookEntries() throws {
    let url = temporaryURL(pathExtension: "lorebook")
    defer { try? FileManager.default.removeItem(at: url) }
    let json = #"""
      {
        "title": "群岛设定",
        "entries": [
          {
            "id": "island-1",
            "displayName": "雾岛",
            "text": "雾岛终年被潮雾覆盖。",
            "keys": ["雾岛", "潮雾"],
            "enabled": true,
            "forceActivation": false
          }
        ]
      }
      """#
    try Data(json.utf8).write(to: url)

    let lorebook = try LorebookImporter().load(from: url)

    #expect(lorebook.title == "群岛设定")
    #expect(lorebook.entries.count == 1)
    #expect(lorebook.entries[0].id == "island-1")
    #expect(lorebook.entries[0].activationKeys == ["雾岛", "潮雾"])
  }

  @Test
  func importsSillyTavernWorldInfoDictionary() throws {
    let url = temporaryURL(pathExtension: "json")
    defer { try? FileManager.default.removeItem(at: url) }
    let json = #"""
      {
        "name": "人物设定",
        "entries": {
          "7": {
            "uid": 7,
            "comment": "林遥",
            "content": "林遥是档案馆管理员。",
            "key": ["林遥", "管理员"],
            "disable": false,
            "constant": true
          }
        }
      }
      """#
    try Data(json.utf8).write(to: url)

    let lorebook = try LorebookImporter().load(from: url)

    #expect(lorebook.title == "人物设定")
    #expect(lorebook.entries[0].id == "7")
    #expect(lorebook.entries[0].title == "林遥")
    #expect(lorebook.entries[0].alwaysActive)
    #expect(lorebook.entries[0].enabled)
  }

  @Test
  func managesLorebookAssociationExportAndReimport() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let incoming = container.appendingPathComponent("incoming", isDirectory: true)
    let exportDirectory = container.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let lorebookURL = incoming.appendingPathComponent("群岛.lorebook")
    try Data(
      #"{"title":"群岛","entries":[{"id":"island","text":"群岛终年多雾。","keys":["群岛"]}]}"#.utf8
    ).write(to: lorebookURL)
    let documentID = UUID()
    let target = StoryworldAssociationTarget(
      documentID: documentID,
      contentHash: "novel-content-hash"
    )
    let sourceReference = StoryworldSourceReference(
      contentHash: target.contentHash,
      sourceFormat: "epub",
      sourceFileName: "群岛.epub",
      title: "群岛"
    )
    let libraryRoot = container.appendingPathComponent("library", isDirectory: true)
    let library = StoryworldLibrary(rootURL: libraryRoot)

    let imported = try await library.importLorebook(
      from: lorebookURL,
      sourceReference: sourceReference,
      associateWith: target
    )
    #expect(imported.lorebookEntryCount == 1)
    #expect(imported.associatedDocumentIDs == [documentID])
    #expect(try await library.listAssociated(with: target).map(\.id) == [imported.id])

    let exported = try await library.exportPackage(
      storyworldID: imported.id,
      to: exportDirectory
    )
    #expect(exported.pathExtension == "storyworld")
    #expect(FileManager.default.fileExists(atPath: exported.path))

    let reopened = StoryworldLibrary(rootURL: libraryRoot)
    #expect(try await reopened.list().map(\.id) == [imported.id])
    let secondLibrary = StoryworldLibrary(
      rootURL: container.appendingPathComponent("second-library", isDirectory: true)
    )
    let reimported = try await secondLibrary.importPackage(from: exported)
    #expect(reimported.id == imported.id)
    #expect(reimported.manifest.sourceReference?.contentHash == target.contentHash)
  }

  @Test
  func conflictingImportCanBackupReplaceOrBecomeCopy() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )
    let original = try await library.create(
      lorebook: Lorebook(
        title: "原始设定",
        entries: [LoreEntry(title: "规则", content: "最初的规则。")]
      )
    )
    let managedURL = try await library.managedPackageURL(storyworldID: original.id)
    let incomingURL = container.appendingPathComponent("更新.storyworld", isDirectory: true)
    try FileManager.default.copyItem(at: managedURL, to: incomingURL)

    let incomingManifestURL = incomingURL.appendingPathComponent("manifest.json")
    let oldManifest = try StoryworldCoding.makeDecoder().decode(
      StoryworldManifest.self,
      from: Data(contentsOf: incomingManifestURL)
    )
    let updatedManifest = StoryworldManifest(
      storyworldID: oldManifest.storyworldID,
      revision: 2,
      title: "更新设定",
      createdAt: oldManifest.createdAt,
      modifiedAt: Date(),
      minimumCoreVersion: oldManifest.minimumCoreVersion,
      sourceReference: oldManifest.sourceReference,
      content: oldManifest.content
    )
    try StoryworldCoding.makeEncoder().encode(updatedManifest).write(
      to: incomingManifestURL,
      options: [.atomic]
    )

    await #expect(throws: StoryworldLibraryError.self) {
      try await library.importPackage(from: incomingURL)
    }
    let replaced = try await library.importPackage(
      from: incomingURL,
      conflictPolicy: .replaceWithBackup
    )
    #expect(replaced.id == original.id)
    #expect(replaced.manifest.revision == 2)
    #expect(try await library.listBackups(storyworldID: original.id).count == 1)

    let copied = try await library.importPackage(
      from: incomingURL,
      conflictPolicy: .importAsCopy
    )
    #expect(copied.id != original.id)
    #expect(copied.manifest.revision == 1)
    #expect(try await library.list().count == 2)
  }

  @Test
  func manualRoundtripPreservesRuntimeAndCopyRewritesAddresses() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let macLibrary = StoryworldLibrary(
      rootURL: container.appendingPathComponent("mac", isDirectory: true)
    )
    let phoneLibrary = StoryworldLibrary(
      rootURL: container.appendingPathComponent("phone", isDirectory: true)
    )
    let returnedLibrary = StoryworldLibrary(
      rootURL: container.appendingPathComponent("returned", isDirectory: true)
    )

    let created = try await macLibrary.create(
      lorebook: Lorebook(
        title: "往返测试",
        entries: [LoreEntry(title: "规则", content: "只保存已提交内容。")]
      )
    )
    let macPackage = try await macLibrary.managedPackageURL(storyworldID: created.id)
    let macRuntime = StoryworldRuntimeStore(packageURL: macPackage)
    let macContext = try await macRuntime.createPlaythrough(title: "Mac 主线")
    _ = try await macRuntime.commitTurn(
      address: macContext.address,
      turnID: UUID(),
      userMessage: "从 Mac 出发",
      narrative: "故事在 Mac 上开始。"
    )

    let outbound = try await macLibrary.exportPackage(
      storyworldID: created.id,
      to: container.appendingPathComponent("outbound", isDirectory: true)
    )
    let phoneRecord = try await phoneLibrary.importPackage(from: outbound)
    let phonePackage = try await phoneLibrary.managedPackageURL(storyworldID: phoneRecord.id)
    let phoneRuntime = StoryworldRuntimeStore(packageURL: phonePackage)
    let phoneSnapshot = try await phoneRuntime.loadActive(playthroughID: macContext.playthrough.id)
    #expect(phoneSnapshot.turns.map(\.narrative) == ["故事在 Mac 上开始。"])
    _ = try await phoneRuntime.commitTurn(
      address: phoneSnapshot.context.address,
      turnID: UUID(),
      userMessage: "在手机继续",
      narrative: "故事在手机上继续。"
    )
    _ = try await phoneRuntime.createSave(
      address: phoneSnapshot.context.address,
      title: "手机存档"
    )

    let inbound = try await phoneLibrary.exportPackage(
      storyworldID: phoneRecord.id,
      to: container.appendingPathComponent("inbound", isDirectory: true)
    )
    let returned = try await returnedLibrary.importPackage(from: inbound)
    let returnedPackage = try await returnedLibrary.managedPackageURL(storyworldID: returned.id)
    let returnedRuntime = StoryworldRuntimeStore(packageURL: returnedPackage)
    let returnedSnapshot = try await returnedRuntime.loadActive(
      playthroughID: macContext.playthrough.id
    )
    #expect(returnedSnapshot.turns.count == 2)
    #expect(returnedSnapshot.saves.map(\.title) == ["手机存档"])

    let copied = try await phoneLibrary.importPackage(
      from: inbound,
      conflictPolicy: .importAsCopy
    )
    let copiedPackage = try await phoneLibrary.managedPackageURL(storyworldID: copied.id)
    let copiedRuntime = StoryworldRuntimeStore(packageURL: copiedPackage)
    let copiedSnapshot = try await copiedRuntime.loadActive(
      playthroughID: macContext.playthrough.id
    )
    #expect(copiedSnapshot.context.address.storyworldID == copied.id)
    #expect(copiedSnapshot.turns.count == 2)
    #expect(copiedSnapshot.turns.allSatisfy { $0.address.storyworldID == copied.id })
    #expect(copiedSnapshot.saves.allSatisfy { $0.address.storyworldID == copied.id })
  }

  @Test
  func malformedAndSymlinkImportsLeaveExistingPackageUntouched() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )
    let original = try await library.create(
      lorebook: Lorebook(
        title: "原始设定",
        entries: [LoreEntry(title: "规则", content: "原始内容。")]
      )
    )
    let managed = try await library.managedPackageURL(storyworldID: original.id)
    let malformed = container.appendingPathComponent("malformed.storyworld", isDirectory: true)
    try FileManager.default.copyItem(at: managed, to: malformed)
    try Data("not-json".utf8).write(
      to: malformed.appendingPathComponent("lorebook/lorebook.json"),
      options: [.atomic]
    )

    await #expect(throws: (any Error).self) {
      try await library.importPackage(
        from: malformed,
        conflictPolicy: .replaceWithBackup
      )
    }
    #expect(try await library.load(storyworldID: original.id).lorebook.title == "原始设定")
    #expect(try await library.listBackups(storyworldID: original.id).isEmpty)

    let unsafe = container.appendingPathComponent("unsafe.storyworld", isDirectory: true)
    try FileManager.default.copyItem(at: managed, to: unsafe)
    try FileManager.default.createSymbolicLink(
      at: unsafe.appendingPathComponent("linked-secret"),
      withDestinationURL: container.appendingPathComponent("outside")
    )
    await #expect(throws: StoryworldLibraryError.self) {
      try await library.importPackage(from: unsafe)
    }
    #expect(try await library.list().map(\.id) == [original.id])
  }

  @Test
  func runtimeCommitsIdempotentlyAndReplaysLaggingState() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "运行测试"),
      lorebook: Lorebook(
        title: "运行测试",
        entries: [LoreEntry(title: "港口", content: "港口终年有雾。")]
      )
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let context = try await runtime.createPlaythrough(title: "第一次游玩")
    let initial = try await runtime.load(address: context.address).state
    let turnID = UUID()
    let event = try await runtime.commitTurn(
      address: context.address,
      turnID: turnID,
      userMessage: "走向港口",
      narrative: "你抵达了雾港。",
      statePatchData: Data(#"{"location":"雾港","flags":{"arrived":true}}"#.utf8)
    )
    let duplicate = try await runtime.commitTurn(
      address: context.address,
      turnID: turnID,
      userMessage: "走向港口",
      narrative: "你抵达了雾港。",
      statePatchData: Data(#"{"location":"雾港","flags":{"arrived":true}}"#.utf8)
    )
    #expect(duplicate.id == event.id)
    #expect(duplicate.turnID == event.turnID)
    #expect(duplicate.sequence == event.sequence)
    await #expect(throws: StoryworldRuntimeError.turnPayloadConflict(turnID)) {
      try await runtime.commitTurn(
        address: context.address,
        turnID: turnID,
        userMessage: "重复请求",
        narrative: "不应静默返回旧结果"
      )
    }
    await #expect(throws: StoryworldRuntimeError.malformedStatePatch) {
      try await runtime.commitTurn(
        address: context.address,
        turnID: UUID(),
        userMessage: "非法补丁",
        narrative: "不会写入",
        statePatchData: Data("[]".utf8)
      )
    }

    let stateURL =
      root
      .appendingPathComponent("playthroughs")
      .appendingPathComponent(context.address.playthroughID.uuidString.lowercased())
      .appendingPathComponent("branches")
      .appendingPathComponent(context.address.branchID.uuidString.lowercased())
      .appendingPathComponent("state.json")
    try StoryworldCoding.makeEncoder().encode(initial).write(to: stateURL, options: [.atomic])

    // 旧事件没有 payload_fingerprint，仍须可读且同内容重试保持幂等。
    let logURL = eventLogURL(root: root, address: context.address)
    var legacyRecord = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [String: Any]
    )
    legacyRecord.removeValue(forKey: "payload_fingerprint")
    var legacyLogData = try JSONSerialization.data(
      withJSONObject: legacyRecord,
      options: [.sortedKeys]
    )
    legacyLogData.append(0x0A)
    try legacyLogData.write(to: logURL, options: [.atomic])

    let reopened = StoryworldRuntimeStore(packageURL: root)
    let snapshot = try await reopened.load(address: context.address)
    #expect(snapshot.turns.count == 1)
    #expect(snapshot.state.lastEventSequence == 1)
    #expect(snapshot.state.values["location"] == .string("雾港"))
    #expect(snapshot.state.stateHash == event.resultingStateHash)
    let legacyDuplicate = try await reopened.commitTurn(
      address: context.address,
      turnID: turnID,
      userMessage: "走向港口",
      narrative: "你抵达了雾港。",
      statePatchData: Data(#"{"location":"雾港","flags":{"arrived":true}}"#.utf8)
    )
    #expect(legacyDuplicate.id == event.id)
  }

  @Test
  func concurrentClientsCanOnlyCommitOneTurnFromTheSameBase() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "并发 CAS")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try await runtime.load(address: context.address).state

    let first = Task {
      try await runtime.commitTurn(
        address: context.address,
        turnID: UUID(),
        userMessage: "客户端甲",
        narrative: "甲的回合",
        expectedEventSequence: base.lastEventSequence,
        expectedStateHash: base.stateHash
      )
    }
    let second = Task {
      try await runtime.commitTurn(
        address: context.address,
        turnID: UUID(),
        userMessage: "客户端乙",
        narrative: "乙的回合",
        expectedEventSequence: base.lastEventSequence,
        expectedStateHash: base.stateHash
      )
    }

    var committed = 0
    var staleHeads: [(Int, String)] = []
    for task in [first, second] {
      do {
        _ = try await task.value
        committed += 1
      } catch let error as StoryworldRuntimeError {
        guard case .staleTurnBase(let sequence, let hash) = error else {
          throw error
        }
        staleHeads.append((sequence, hash))
      }
    }
    let snapshot = try await runtime.load(address: context.address)
    #expect(committed == 1)
    #expect(staleHeads.count == 1)
    #expect(staleHeads.first?.0 == 1)
    #expect(staleHeads.first?.1 == snapshot.state.stateHash)
    #expect(snapshot.turns.count == 1)
  }

  @Test
  func runtimeRebuildsTamperedSameSequenceStateFromBaseAndEvents() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "同序恢复")
    defer { try? FileManager.default.removeItem(at: root) }
    let event = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "进入港口",
      narrative: "你进入港口。",
      statePatchData: Data(#"{"location":"港口"}"#.utf8)
    )
    let stateURL = runtimeStateURL(root: root, address: context.address)
    var tampered = try StoryworldCoding.makeDecoder().decode(
      BranchStateSnapshot.self,
      from: Data(contentsOf: stateURL)
    )
    tampered.values["location"] = .string("伪造地点")
    try StoryworldCoding.makeEncoder().encode(tampered).write(to: stateURL, options: [.atomic])

    let recovered = try await StoryworldRuntimeStore(packageURL: root).load(
      address: context.address
    )
    #expect(recovered.state.lastEventSequence == 1)
    #expect(recovered.state.values["location"] == .string("港口"))
    #expect(recovered.state.stateHash == event.resultingStateHash)
  }

  @Test
  func runtimeFailsClosedWhenTamperedStateHasNoReliableBase() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "无基线损坏")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "前进",
      narrative: "向前一步。"
    )
    let stateURL = runtimeStateURL(root: root, address: context.address)
    var tampered = try StoryworldCoding.makeDecoder().decode(
      BranchStateSnapshot.self,
      from: Data(contentsOf: stateURL)
    )
    tampered.values["tampered"] = .bool(true)
    try StoryworldCoding.makeEncoder().encode(tampered).write(to: stateURL, options: [.atomic])
    try FileManager.default.removeItem(
      at: stateURL.deletingLastPathComponent().appendingPathComponent("base_state.json")
    )

    await #expect(throws: StoryworldRuntimeError.baseStateUnavailable) {
      try await StoryworldRuntimeStore(packageURL: root).load(address: context.address)
    }
  }

  @Test
  func runtimeEventLogLoadsCompleteNewlineTerminatedRecords() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "完整日志")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "第一步",
      narrative: "第一回。"
    )
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "第二步",
      narrative: "第二回。"
    )
    let logURL = eventLogURL(root: root, address: context.address)
    #expect(try Data(contentsOf: logURL).last == 0x0A)

    let reopened = StoryworldRuntimeStore(packageURL: root)
    let snapshot = try await reopened.load(address: context.address)
    #expect(snapshot.turns.map(\.sequence) == [1, 2])
    #expect(tornBackups(beside: logURL).isEmpty)
  }

  @Test
  func runtimeEventLogLoadsCompleteFinalRecordWithoutNewline() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "无尾换行")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "前进",
      narrative: "完整的一回。"
    )
    let logURL = eventLogURL(root: root, address: context.address)
    var logData = try Data(contentsOf: logURL)
    #expect(logData.last == 0x0A)
    logData.removeLast()
    try logData.write(to: logURL, options: [.atomic])

    let reopened = StoryworldRuntimeStore(packageURL: root)
    let snapshot = try await reopened.load(address: context.address)
    #expect(snapshot.turns.count == 1)
    #expect(try Data(contentsOf: logURL) == logData)
    #expect(tornBackups(beside: logURL).isEmpty)
  }

  @Test
  func runtimeEventLogRecoversTornTailAndCanAppend() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "撕裂尾恢复")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "第一步",
      narrative: "第一回。"
    )
    let logURL = eventLogURL(root: root, address: context.address)
    let completeData = try Data(contentsOf: logURL)
    let tornTail = Data(#"{"address":{"branch_id":"broken""#.utf8)
    var damagedData = completeData
    damagedData.append(tornTail)
    try damagedData.write(to: logURL, options: [.atomic])

    let reopened = StoryworldRuntimeStore(packageURL: root)
    let recovered = try await reopened.load(address: context.address)
    #expect(recovered.turns.count == 1)
    #expect(try Data(contentsOf: logURL) == completeData)
    let backups = tornBackups(beside: logURL)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == tornTail)

    _ = try await reopened.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "恢复后继续",
      narrative: "第二回。"
    )
    let loadedAgain = try await StoryworldRuntimeStore(packageURL: root).load(
      address: context.address
    )
    #expect(loadedAgain.turns.map(\.sequence) == [1, 2])
    #expect(try Data(contentsOf: logURL).last == 0x0A)
  }

  @Test
  func runtimeEventLogRejectsMiddleCorruptionWithoutModification() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "中间损坏")
    defer { try? FileManager.default.removeItem(at: root) }
    for step in 1...2 {
      _ = try await runtime.commitTurn(
        address: context.address,
        turnID: UUID(),
        userMessage: "第 \(step) 步",
        narrative: "第 \(step) 回。"
      )
    }
    let logURL = eventLogURL(root: root, address: context.address)
    let validData = try Data(contentsOf: logURL)
    let firstNewline = try #require(validData.firstIndex(of: 0x0A))
    var damagedData = Data("not-json".utf8)
    damagedData.append(validData[firstNewline..<validData.endIndex])
    try damagedData.write(to: logURL, options: [.atomic])

    let reopened = StoryworldRuntimeStore(packageURL: root)
    await #expect(throws: StoryworldRuntimeError.corruptedEventLog) {
      try await reopened.load(address: context.address)
    }
    #expect(try Data(contentsOf: logURL) == damagedData)
    #expect(tornBackups(beside: logURL).isEmpty)
  }

  @Test
  func runtimeEventLogRejectsMultipleInvalidTailRecordsWithoutModification() async throws {
    let (root, runtime, context) = try await makeRuntimeFixture(title: "多条损坏")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: context.address,
      turnID: UUID(),
      userMessage: "第一步",
      narrative: "第一回。"
    )
    let logURL = eventLogURL(root: root, address: context.address)
    var damagedData = try Data(contentsOf: logURL)
    damagedData.append(Data("bad-one\nbad-two".utf8))
    try damagedData.write(to: logURL, options: [.atomic])

    let reopened = StoryworldRuntimeStore(packageURL: root)
    await #expect(throws: StoryworldRuntimeError.corruptedEventLog) {
      try await reopened.load(address: context.address)
    }
    #expect(try Data(contentsOf: logURL) == damagedData)
    #expect(tornBackups(beside: logURL).isEmpty)
  }

  @Test
  func savesAndBranchesRemainIsolated() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "分支测试"),
      lorebook: Lorebook(
        title: "分支测试",
        entries: [LoreEntry(title: "规则", content: "选择会产生分支。")]
      )
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let original = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: original.address,
      turnID: UUID(),
      userMessage: "选择甲",
      narrative: "你选择了甲。",
      statePatchData: Data(#"{"choice":"甲"}"#.utf8)
    )
    let save = try await runtime.createSave(address: original.address, title: "选择之后")
    _ = try await runtime.commitTurn(
      address: original.address,
      turnID: UUID(),
      userMessage: "继续前进",
      narrative: "你继续前进。",
      statePatchData: Data(#"{"step":2}"#.utf8)
    )

    let currentFork = try await runtime.forkBranch(
      address: original.address,
      title: "当前状态分支"
    )
    let currentSnapshot = try await runtime.load(address: currentFork.address)
    #expect(currentSnapshot.turns.isEmpty)
    #expect(currentSnapshot.effectiveTurns.map(\.userMessage) == ["选择甲", "继续前进"])
    #expect(currentSnapshot.state.values["choice"] == .string("甲"))
    #expect(currentSnapshot.state.values["step"] == .number(2))

    let restored = try await runtime.restoreSaveAsNewBranch(
      address: original.address,
      saveID: save.id,
      title: "从存档重开"
    )
    let restoredSnapshot = try await runtime.load(address: restored.address)
    #expect(restoredSnapshot.turns.isEmpty)
    #expect(restoredSnapshot.effectiveTurns.map(\.userMessage) == ["选择甲"])
    #expect(restoredSnapshot.state.values["choice"] == .string("甲"))
    #expect(restoredSnapshot.state.values["step"] == nil)
    #expect(
      try await runtime.listBranches(playthroughID: original.address.playthroughID).count == 3)

    let originalSnapshot = try await runtime.load(address: original.address)
    #expect(originalSnapshot.turns.count == 2)
    #expect(originalSnapshot.state.values["step"] == .number(2))
  }

  @Test
  func branchGraphMapsLanesForksAndSaves() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "图谱测试"),
      lorebook: Lorebook(
        title: "图谱测试",
        entries: [LoreEntry(title: "规则", content: "分支会留下轨迹。")]
      )
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let main = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "第一步",
      narrative: "第一回。"
    )
    let save = try await runtime.createSave(address: main.address, title: "岔路口")
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "第二步",
      narrative: "第二回。"
    )
    let fork = try await runtime.restoreSaveAsNewBranch(
      address: main.address,
      saveID: save.id,
      title: "另一条路"
    )
    _ = try await runtime.commitTurn(
      address: fork.address,
      turnID: UUID(),
      userMessage: "分支第一步",
      narrative: "分支第一回。"
    )

    let graph = try await runtime.loadBranchGraph(playthroughID: main.address.playthroughID)
    #expect(graph.playthroughTitle == "主线")
    #expect(graph.nodes.count == 2)
    #expect(graph.activeBranchID == fork.address.branchID)

    let mainNode = try #require(graph.node(branchID: main.address.branchID))
    #expect(mainNode.lane == 0)
    #expect(mainNode.startAbsoluteSequence == 0)
    #expect(mainNode.headEventSequence == 2)
    #expect(!mainNode.isActive)
    #expect(mainNode.isOnActivePath)
    #expect(mainNode.saves.map(\.absoluteSequence) == [1])
    #expect(mainNode.saves.first?.save.title == "岔路口")

    let forkNode = try #require(graph.node(branchID: fork.address.branchID))
    #expect(forkNode.lane == 1)
    #expect(forkNode.parentBranchID == main.address.branchID)
    #expect(forkNode.startAbsoluteSequence == 1)
    #expect(forkNode.headEventSequence == 1)
    #expect(forkNode.endAbsoluteSequence == 2)
    #expect(forkNode.isActive)
    #expect(forkNode.isOnActivePath)
    #expect(graph.maxAbsoluteSequence == 2)
  }

  @Test
  func branchGraphKeepsInactiveLineOffActivePath() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "路径测试"),
      lorebook: Lorebook(title: "路径测试", entries: [])
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let main = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "走一步",
      narrative: "一回。"
    )
    let fork = try await runtime.forkBranch(address: main.address, title: "支线")
    // 切回主线，支线应不在当前路径上
    _ = try await runtime.activateBranch(
      playthroughID: main.address.playthroughID,
      branchID: main.address.branchID
    )

    let graph = try await runtime.loadBranchGraph(playthroughID: main.address.playthroughID)
    let mainNode = try #require(graph.node(branchID: main.address.branchID))
    let forkNode = try #require(graph.node(branchID: fork.address.branchID))
    #expect(mainNode.isActive)
    #expect(mainNode.isOnActivePath)
    #expect(!forkNode.isActive)
    #expect(!forkNode.isOnActivePath)
    #expect(forkNode.startAbsoluteSequence == 1)
  }

  @Test
  func forkAndSaveAtPastEventReplayState() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "回放测试"),
      lorebook: Lorebook(title: "回放测试", entries: [])
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let main = try await runtime.createPlaythrough(title: "主线")
    for step in 1...3 {
      _ = try await runtime.commitTurn(
        address: main.address,
        turnID: UUID(),
        userMessage: "第 \(step) 步：" + String(repeating: "很长", count: 15),
        narrative: "第 \(step) 回。",
        statePatchData: Data("{\"step\":\(step)}".utf8)
      )
    }

    let replayed = try await runtime.stateSnapshot(address: main.address, atEventSequence: 2)
    #expect(replayed.lastEventSequence == 2)
    #expect(replayed.values["step"] == .number(2))

    let save = try await runtime.createSave(
      address: main.address,
      atEventSequence: 2,
      title: "第二回合"
    )
    #expect(save.eventSequence == 2)
    #expect(save.state["step"] == .number(2))

    let fork = try await runtime.forkBranch(
      address: main.address,
      atEventSequence: 2,
      title: "回到第二回合"
    )
    #expect(fork.branch.branch.forkedAtEventSequence == 2)
    let forkSnapshot = try await runtime.load(address: fork.address)
    #expect(forkSnapshot.state.values["step"] == .number(2))
    #expect(forkSnapshot.turns.isEmpty)
    #expect(forkSnapshot.effectiveTurns.map(\.sequence) == [1, 2])

    let graph = try await runtime.loadBranchGraph(playthroughID: main.address.playthroughID)
    let mainNode = try #require(graph.node(branchID: main.address.branchID))
    #expect(mainNode.turns.map(\.sequence) == [1, 2, 3])
    #expect(mainNode.turns.map(\.absoluteSequence) == [1, 2, 3])
    #expect(mainNode.turns.first?.preview.hasSuffix("…") == true)
    #expect(mainNode.saves.map(\.absoluteSequence) == [2])
    let forkNode = try #require(graph.node(branchID: fork.address.branchID))
    #expect(forkNode.startAbsoluteSequence == 2)
    #expect(forkNode.turns.isEmpty)
  }

  @Test
  func effectiveHistoryProjectsRootChildAndGrandchildBoundariesWithoutRenumbering() async throws {
    let (root, runtime, main) = try await makeRuntimeFixture(title: "祖先投影")
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 1...3 {
      _ = try await runtime.commitTurn(
        address: main.address,
        turnID: UUID(),
        userMessage: "root-\(index)",
        narrative: "root narrative \(index)"
      )
    }
    let child = try await runtime.forkBranch(
      address: main.address,
      atEventSequence: 2,
      title: "child"
    )
    for index in 1...2 {
      _ = try await runtime.commitTurn(
        address: child.address,
        turnID: UUID(),
        userMessage: "child-\(index)",
        narrative: "child narrative \(index)"
      )
    }
    let grandchild = try await runtime.forkBranch(
      address: child.address,
      atEventSequence: 1,
      title: "grandchild"
    )
    _ = try await runtime.commitTurn(
      address: grandchild.address,
      turnID: UUID(),
      userMessage: "grandchild-1",
      narrative: "grandchild narrative 1"
    )

    let snapshot = try await runtime.load(address: grandchild.address)
    #expect(snapshot.turns.map(\.userMessage) == ["grandchild-1"])
    #expect(
      snapshot.effectiveTurns.map(\.userMessage)
        == ["root-1", "root-2", "child-1", "grandchild-1"]
    )
    #expect(snapshot.effectiveTurns.map(\.sequence) == [1, 2, 1, 1])
    #expect(
      snapshot.effectiveTurns.map(\.address.branchID)
        == [
          main.address.branchID, main.address.branchID, child.address.branchID,
          grandchild.address.branchID,
        ]
    )

    let graph = try await runtime.loadBranchGraph(playthroughID: main.address.playthroughID)
    #expect(graph.node(branchID: main.address.branchID)?.turns.count == 3)
    #expect(graph.node(branchID: child.address.branchID)?.turns.count == 2)
    #expect(graph.node(branchID: grandchild.address.branchID)?.turns.count == 1)
  }

  @Test
  func effectiveHistoryCapsAncestorDepthAndStopsCycles() async throws {
    let (root, runtime, main) = try await makeRuntimeFixture(title: "投影保护")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "depth-0",
      narrative: "root"
    )
    var current = main
    for depth in 1...34 {
      current = try await runtime.forkBranch(address: current.address, title: "depth-\(depth)")
      _ = try await runtime.commitTurn(
        address: current.address,
        turnID: UUID(),
        userMessage: "depth-\(depth)",
        narrative: "branch \(depth)"
      )
    }
    let capped = try await runtime.load(address: current.address)
    #expect(capped.effectiveTurns.count == 33)
    #expect(capped.effectiveTurns.first?.userMessage == "depth-2")
    #expect(capped.effectiveTurns.last?.userMessage == "depth-34")

    let parent = try #require(current.branch.branch.parentBranchID)
    let parentMetadataURL = branchMetadataURL(
      root: root,
      playthroughID: current.address.playthroughID,
      branchID: parent
    )
    var parentDescriptor = try StoryworldCoding.makeDecoder().decode(
      RuntimeBranchDescriptor.self,
      from: Data(contentsOf: parentMetadataURL)
    )
    parentDescriptor = RuntimeBranchDescriptor(
      branch: BranchDescriptor(
        id: parentDescriptor.id,
        playthroughID: current.address.playthroughID,
        parentBranchID: current.address.branchID,
        forkedAtEventSequence: 1,
        title: parentDescriptor.branch.title,
        createdAt: parentDescriptor.branch.createdAt
      ),
      sessionID: parentDescriptor.sessionID,
      baseStateHash: parentDescriptor.baseStateHash
    )
    try StoryworldCoding.makeEncoder().encode(parentDescriptor).write(
      to: parentMetadataURL,
      options: .atomic
    )
    let cycleSafe = try await StoryworldRuntimeStore(packageURL: root).load(
      address: current.address)
    #expect(cycleSafe.effectiveTurns.count == 2)
    #expect(cycleSafe.effectiveTurns.map(\.userMessage) == ["depth-33", "depth-34"])
  }

  @Test
  func nilForkSequenceFallsBackToZeroEffectiveAncestors() async throws {
    let (root, runtime, main) = try await makeRuntimeFixture(title: "nil 分叉点")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "父分支回合",
      narrative: "不应被投影"
    )
    let child = try await runtime.forkBranch(address: main.address, title: "旧分支")
    let metadataURL = branchMetadataURL(
      root: root,
      playthroughID: child.address.playthroughID,
      branchID: child.address.branchID
    )
    let descriptor = RuntimeBranchDescriptor(
      branch: BranchDescriptor(
        id: child.branch.id,
        playthroughID: child.address.playthroughID,
        parentBranchID: main.address.branchID,
        forkedAtEventSequence: nil,
        title: child.branch.branch.title,
        createdAt: child.branch.branch.createdAt
      ),
      sessionID: child.branch.sessionID,
      baseStateHash: child.branch.baseStateHash
    )
    try StoryworldCoding.makeEncoder().encode(descriptor).write(to: metadataURL, options: .atomic)
    let snapshot = try await StoryworldRuntimeStore(packageURL: root).load(address: child.address)
    #expect(snapshot.turns.isEmpty)
    #expect(snapshot.effectiveTurns.isEmpty)
  }

  @Test
  func recapCacheFailsOpenAndDoesNotCrossExportOrImport() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(rootURL: container.appendingPathComponent("source"))
    let record = try await library.create(
      lorebook: Lorebook(title: "摘要导出", entries: [])
    )
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)
    let context = try await runtime.createPlaythrough(title: "游玩")
    let recap = StoryRecap(
      throughEffectiveTurnCount: 0,
      lastAttemptedEffectiveTurnCount: 0,
      narrative: "累计前情",
      generatedAt: Date()
    )
    try await runtime.saveRecap(recap, address: context.address)
    #expect(try await runtime.load(address: context.address).recap?.narrative == "累计前情")

    let recapURL = branchMetadataURL(
      root: packageURL,
      playthroughID: context.address.playthroughID,
      branchID: context.address.branchID
    ).deletingLastPathComponent().appendingPathComponent("recap.json")
    try Data("not-json".utf8).write(to: recapURL, options: .atomic)
    #expect(try await runtime.load(address: context.address).recap == nil)
    try await runtime.saveRecap(recap, address: context.address)

    let exported = try await library.exportPackage(
      storyworldID: record.id,
      to: container.appendingPathComponent("shared.storyworld")
    )
    #expect(
      !FileManager.default.fileExists(atPath: exportedRecapURL(exported, context.address).path))

    try StoryworldCoding.makeEncoder().encode(recap).write(
      to: exportedRecapURL(exported, context.address),
      options: .atomic
    )
    let destination = StoryworldLibrary(rootURL: container.appendingPathComponent("destination"))
    let imported = try await destination.importPackage(from: exported)
    let importedURL = try await destination.managedPackageURL(storyworldID: imported.id)
    #expect(
      !FileManager.default.fileExists(atPath: exportedRecapURL(importedURL, context.address).path))
  }

  @Test
  func timelineKeywordMatchingAndGraphBeats() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "节拍测试"),
      lorebook: Lorebook(title: "节拍测试", entries: [])
    )
    let timeline = StoryTimeline(
      beats: [
        StoryBeat(
          id: "beat-feast",
          title: "英雄大宴",
          summary: "丐帮换帮主",
          order: 1,
          keywords: ["陆家庄", "英雄宴"]
        ),
        StoryBeat(
          id: "beat-duel",
          title: "绝情谷之战",
          summary: "谷中决战",
          order: 2,
          keywords: ["绝情谷"]
        ),
      ],
      source: "factory"
    )
    try StoryworldCoding.makeEncoder()
      .encode(timeline)
      .write(to: root.appendingPathComponent("timeline.json"))

    // 关键词兜底：命中顺序最大的节拍
    #expect(timeline.matchedBeatID(for: "你赶到了陆家庄外。") == "beat-feast")
    #expect(timeline.matchedBeatID(for: "陆家庄与绝情谷都提到了。") == "beat-duel")
    #expect(timeline.matchedBeatID(for: "后山闲逛。") == nil)

    let runtime = StoryworldRuntimeStore(packageURL: root)
    let loaded = try #require(try await runtime.loadTimeline())
    #expect(loaded.beats == timeline.beats)
    #expect(loaded.source == timeline.source)

    let main = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "入宴",
      narrative: "你随众人入席。",
      beatID: "beat-feast"
    )
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "闲逛",
      narrative: "你四处走动。"
    )

    let graph = try await runtime.loadBranchGraph(playthroughID: main.address.playthroughID)
    #expect(graph.timeline?.beats == timeline.beats)
    let mainNode = try #require(graph.node(branchID: main.address.branchID))
    #expect(mainNode.turns.map(\.beatID) == ["beat-feast", nil])
    #expect(graph.reachedBeatIDsOnActivePath == ["beat-feast"])

    // 重开 store 读旧日志，beat_id 保持往返一致
    let reopened = StoryworldRuntimeStore(packageURL: root)
    let snapshot = try await reopened.load(address: main.address)
    #expect(snapshot.turns.map(\.beatID) == ["beat-feast", nil])
  }

  @Test
  func plotlineRoundTripsThroughPackageAndWindowSlides() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "主线测试"),
      lorebook: Lorebook(title: "主线测试", entries: [])
    )
    let plotline = StoryPlotline(
      nodes: [
        StoryPlotNode(id: "plot-0001", title: "第一章", summary: "开端。", order: 1, chapterOrdinal: 0),
        StoryPlotNode(id: "plot-0002", title: "第二章", summary: "发展。", order: 2, chapterOrdinal: 1),
        StoryPlotNode(id: "plot-0003", title: "第三章", summary: "高潮。", order: 3, chapterOrdinal: 2),
      ],
      source: "factory"
    )
    try StoryworldCoding.makeEncoder()
      .encode(plotline)
      .write(to: root.appendingPathComponent("plotline.json"))

    // 包内 plotline.json 随文档加载；无该文件的包 plotline 为 nil（旧包兼容）
    let library = StoryworldLibrary(
      rootURL: root.deletingLastPathComponent()
        .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
    )
    let record = try await library.importPackage(from: root)
    let document = try await library.load(storyworldID: record.id)
    #expect(document.plotline?.nodes == plotline.nodes)
    #expect(document.plotline?.source == "factory")

    // 滑窗：当前节点 + 前一节点回顾 + 后两节点标题
    let window = plotline.window(around: 2)
    #expect(window.current?.id == "plot-0002")
    #expect(window.previous?.id == "plot-0001")
    #expect(window.upcoming.map(\.id) == ["plot-0003"])
    let first = plotline.window(around: 1)
    #expect(first.previous == nil)
    #expect(first.upcoming.map(\.id) == ["plot-0002", "plot-0003"])
  }

  @Test
  func materialProfileRoundTripsAndDamageFailsOpen() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "素材配置测试"),
      lorebook: Lorebook(title: "素材配置测试", entries: [])
    )
    let libraryRoot = root.deletingLastPathComponent()
      .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: libraryRoot) }
    let library = StoryworldLibrary(rootURL: libraryRoot)
    let record = try await library.importPackage(from: root)
    #expect(try await library.load(storyworldID: record.id).materialProfile == nil)

    let profile = MaterialProfile(
      primaryGenre: "xianxia",
      secondaryGenres: ["wuxia"],
      confidence: 0.88,
      source: "factory",
      evidence: ["修炼境界与雷劫是主要世界规则"],
      plotSceneMap: ["plot-0001": ["duizhi", "liangnan"]],
      beatSceneMap: ["beat-001": ["tanpan"]]
    )
    try await library.saveMaterialProfile(profile, storyworldID: record.id)
    let loaded = try await library.load(storyworldID: record.id)
    #expect(loaded.materialProfile == profile)

    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let profileURL = packageURL.appendingPathComponent("material_profile.json")
    let raw = try String(contentsOf: profileURL, encoding: .utf8)
    #expect(raw.contains("\"primary_genre\""))
    #expect(raw.contains("\"plot_scene_map\""))
    try Data("{not-json".utf8).write(to: profileURL, options: .atomic)
    #expect(try await library.load(storyworldID: record.id).materialProfile == nil)
  }

  @Test
  func pastEventStateRequiresBaseSnapshot() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "旧分支测试"),
      lorebook: Lorebook(title: "旧分支测试", entries: [])
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let main = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: main.address,
      turnID: UUID(),
      userMessage: "走一步",
      narrative: "一回。"
    )
    // 模拟旧版本创建的分支：没有 base_state.json
    let baseURL = root
      .appendingPathComponent("playthroughs")
      .appendingPathComponent(main.address.playthroughID.uuidString.lowercased())
      .appendingPathComponent("branches")
      .appendingPathComponent(main.address.branchID.uuidString.lowercased())
      .appendingPathComponent("base_state.json")
    try FileManager.default.removeItem(at: baseURL)

    // 最新位置不受影响，历史位置报 baseStateUnavailable
    let head = try await runtime.stateSnapshot(address: main.address, atEventSequence: 1)
    #expect(head.lastEventSequence == 1)
    await #expect(throws: StoryworldRuntimeError.baseStateUnavailable) {
      try await runtime.stateSnapshot(address: main.address, atEventSequence: 0)
    }
    await #expect(throws: StoryworldRuntimeError.eventSequenceOutOfRange(5)) {
      try await runtime.stateSnapshot(address: main.address, atEventSequence: 5)
    }
  }

  @Test
  func migratesLegacyMarkdownStateAndOriginalFiles() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let legacy = container.appendingPathComponent("旧版", isDirectory: true)
    let libraryRoot = container.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(
      at: legacy.appendingPathComponent("存档", isDirectory: true),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    try Data("# 世界书 - 《雾港》\n\n基础规则。".utf8).write(
      to: legacy.appendingPathComponent("世界书.md")
    )
    try Data("# 人物\n\n## 林遥\n档案馆管理员。".utf8).write(
      to: legacy.appendingPathComponent("人物-主要角色.md")
    )
    try Data(#"{"location":"旧档案馆","revision":7}"#.utf8).write(
      to: legacy.appendingPathComponent("状态.json")
    )
    try Data("{\"seq\":1,\"事件\":\"旧事件\"}\n".utf8).write(
      to: legacy.appendingPathComponent("事件日志.jsonl")
    )
    try Data("旧存档".utf8).write(
      to: legacy.appendingPathComponent("存档/最新.md")
    )

    let library = StoryworldLibrary(rootURL: libraryRoot)
    let receipt = try await library.importLegacyWorldbook(from: legacy)
    let managed = try await library.managedPackageURL(storyworldID: receipt.record.id)
    let runtime = StoryworldRuntimeStore(packageURL: managed)
    let snapshot = try await runtime.load(address: receipt.playthrough.address)

    #expect(receipt.record.manifest.title == "雾港")
    #expect(receipt.record.lorebookEntryCount == 2)
    #expect(snapshot.state.values["location"] == .string("旧档案馆"))
    #expect(snapshot.state.values["revision"] == .number(7))
    #expect(receipt.preservedFileCount == 5)
    #expect(
      FileManager.default.fileExists(
        atPath: managed.appendingPathComponent("legacy/originals/事件日志.jsonl").path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: managed.appendingPathComponent("legacy/originals/存档/最新.md").path
      )
    )
  }

  @Test
  func libraryDeleteMovesPackageToBackupsAndClearsAssociations() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )
    let target = StoryworldAssociationTarget(
      documentID: UUID(),
      contentHash: "novel-content-hash"
    )
    let record = try await library.create(
      lorebook: Lorebook(
        title: "待删除",
        entries: [LoreEntry(title: "规则", content: "会被移入备份。")]
      ),
      associateWith: target
    )
    #expect(try await library.listAssociated(with: target).map(\.id) == [record.id])

    try await library.delete(storyworldID: record.id)

    #expect(try await library.list().isEmpty)
    #expect(try await library.listAssociated(with: target).isEmpty)
    // 软删除：包仍在 Backups 下，可重新导入恢复
    let backups = try await library.listBackups(storyworldID: record.id)
    #expect(backups.count == 1)
    #expect(backups[0].lastPathComponent.hasPrefix("deleted-"))
    let restored = try await library.importPackage(from: backups[0])
    #expect(restored.id == record.id)
  }

  @Test
  func createEmptyStoryworldProducesValidPlayablePackage() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )

    let record = try await library.createEmpty(title: " 融合世界 ")

    #expect(record.manifest.title == "融合世界")
    #expect(record.lorebookEntryCount == 0)
    let document = try await library.load(storyworldID: record.id)
    #expect(document.lorebook.entries.isEmpty)
    // 空白世界可以像普通世界一样直接建游玩线
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)
    _ = try await runtime.createPlaythrough(title: "第一次游玩")
  }

  @Test
  func importEntriesDeepCopiesWithFreshIDsAndMergesCategoriesByName() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )
    let source = try await library.create(
      lorebook: Lorebook(
        title: "源世界",
        entries: [
          LoreEntry(id: "src-tangsan", title: "唐三", content: "武魂蓝银草。", categoryID: "cat-char"),
          LoreEntry(id: "src-xiaoyan", title: "萧炎", content: "斗之气三段。", categoryID: "cat-char"),
          LoreEntry(id: "src-skip", title: "路人", content: "不导入。"),
        ],
        categories: [LorebookCategory(id: "cat-char", name: "人物")]
      )
    )
    let target = try await library.create(
      lorebook: Lorebook(
        title: "融合世界",
        entries: [LoreEntry(title: "唐三", content: "目标世界已有同名。", categoryID: "tgt-char")],
        categories: [LorebookCategory(id: "tgt-char", name: "人物")]
      )
    )

    let copied = try await library.importEntries(
      from: source.id,
      entryIDs: ["src-tangsan", "src-xiaoyan"],
      into: target.id
    )

    #expect(copied == 2)
    let document = try await library.load(storyworldID: target.id)
    #expect(document.lorebook.entries.count == 3)
    // 分类按名称合并，不新建重复分类
    #expect(document.lorebook.categories.count == 1)
    let imported = document.lorebook.entries.filter { $0.content.contains("武魂") || $0.content.contains("斗之气") }
    #expect(imported.count == 2)
    // 条目 ID 重新生成
    #expect(!imported.map(\.id).contains("src-tangsan"))
    #expect(!imported.map(\.id).contains("src-xiaoyan"))
    // 标题撞名自动加后缀
    #expect(imported.map(\.title).contains("唐三 (2)"))
    #expect(imported.map(\.title).contains("萧炎"))
    // 分类指向目标世界的既有分类
    #expect(imported.allSatisfy { $0.categoryID == "tgt-char" })
    // 修订号推进
    #expect(document.manifest.revision == 2)
    // 源世界不受影响
    let sourceDocument = try await library.load(storyworldID: source.id)
    #expect(sourceDocument.lorebook.entries.count == 3)
    #expect(sourceDocument.manifest.revision == 1)
  }

  @Test
  func addEntryAppendsManualEntryWithMergedCategory() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )
    let record = try await library.createEmpty(title: "新世界")

    try await library.addEntry(
      LoreEntry(title: "世界基底", content: "四位主角同处一个时空。", alwaysActive: true),
      categoryName: "世界基底",
      storyworldID: record.id
    )

    let document = try await library.load(storyworldID: record.id)
    #expect(document.lorebook.entries.count == 1)
    #expect(document.lorebook.entries[0].alwaysActive)
    #expect(document.lorebook.categories.map(\.name) == ["世界基底"])
    #expect(document.lorebook.entries[0].categoryID == document.lorebook.categories[0].id)
    #expect(document.manifest.revision == 2)
  }

  @Test
  func runtimeDeletePlaythroughRemovesBranchesAndSessions() async throws {
    let root = temporaryURL(pathExtension: "storyworld")
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: "删除测试"),
      lorebook: Lorebook(
        title: "删除测试",
        entries: [LoreEntry(title: "规则", content: "游玩线可整条删除。")]
      )
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let doomed = try await runtime.createPlaythrough(title: "将被删除")
    _ = try await runtime.commitTurn(
      address: doomed.address,
      turnID: UUID(),
      userMessage: "前进",
      narrative: "你走出一步。"
    )
    let forked = try await runtime.forkBranch(address: doomed.address, title: "岔路")
    let kept = try await runtime.createPlaythrough(title: "保留")
    #expect(try await runtime.listPlaythroughs().count == 2)

    try await runtime.deletePlaythrough(playthroughID: doomed.playthrough.id)

    let remaining = try await runtime.listPlaythroughs()
    #expect(remaining.map(\.id) == [kept.playthrough.id])
    #expect(
      !FileManager.default.fileExists(
        atPath: root
          .appendingPathComponent("playthroughs")
          .appendingPathComponent(doomed.playthrough.id.uuidString.lowercased()).path
      )
    )
    // 被删游玩线两个分支的会话目录一并移除；保留线的会话仍可加载
    for sessionID in [doomed.branch.sessionID, forked.branch.sessionID] {
      #expect(
        !FileManager.default.fileExists(
          atPath: root
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID.uuidString.lowercased()).path
        )
      )
    }
    let snapshot = try await runtime.load(address: kept.address)
    #expect(snapshot.context.playthrough.id == kept.playthrough.id)
  }

  private func makeRuntimeFixture(
    title: String
  ) async throws -> (URL, StoryworldRuntimeStore, PlaythroughContext) {
    let root = temporaryURL(pathExtension: "storyworld")
    try writePackage(
      at: root,
      manifest: StoryworldManifest(title: title),
      lorebook: Lorebook(title: title, entries: [])
    )
    let runtime = StoryworldRuntimeStore(packageURL: root)
    let context = try await runtime.createPlaythrough(title: title)
    return (root, runtime, context)
  }

  private func eventLogURL(root: URL, address: SessionAddress) -> URL {
    root
      .appendingPathComponent("playthroughs")
      .appendingPathComponent(address.playthroughID.uuidString.lowercased())
      .appendingPathComponent("branches")
      .appendingPathComponent(address.branchID.uuidString.lowercased())
      .appendingPathComponent("events.jsonl")
  }

  private func runtimeStateURL(root: URL, address: SessionAddress) -> URL {
    eventLogURL(root: root, address: address)
      .deletingLastPathComponent()
      .appendingPathComponent("state.json")
  }

  private func branchMetadataURL(root: URL, playthroughID: UUID, branchID: UUID) -> URL {
    root
      .appendingPathComponent("playthroughs")
      .appendingPathComponent(playthroughID.uuidString.lowercased())
      .appendingPathComponent("branches")
      .appendingPathComponent(branchID.uuidString.lowercased())
      .appendingPathComponent("metadata.json")
  }

  private func exportedRecapURL(_ root: URL, _ address: SessionAddress) -> URL {
    branchMetadataURL(
      root: root,
      playthroughID: address.playthroughID,
      branchID: address.branchID
    ).deletingLastPathComponent().appendingPathComponent("recap.json")
  }

  private func tornBackups(beside logURL: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: logURL.deletingLastPathComponent(),
      includingPropertiesForKeys: nil
    )) ?? []).filter {
      $0.lastPathComponent.hasPrefix("events.jsonl.torn-")
        && $0.lastPathComponent.hasSuffix(".bak")
    }
  }

  private func temporaryURL(pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(pathExtension)
  }

  private func writePackage(
    at root: URL,
    manifest: StoryworldManifest,
    lorebook: Lorebook
  ) throws {
    let lorebookDirectory = root.appendingPathComponent("lorebook", isDirectory: true)
    try FileManager.default.createDirectory(
      at: lorebookDirectory,
      withIntermediateDirectories: true
    )
    try StoryworldCoding.makeEncoder()
      .encode(lorebook)
      .write(to: lorebookDirectory.appendingPathComponent("lorebook.json"))
    try StoryworldCoding.makeEncoder()
      .encode(manifest)
      .write(to: root.appendingPathComponent("manifest.json"))
  }
}
