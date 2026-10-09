import Foundation

/// Local checks establish structure, identity, provenance and lifecycle only.
/// They cannot prove a model's interpretation of a Chinese sentence is correct.
public enum ContinuityReducer {
  public static func prepare(
    input: ContinuityInput, ledger: ContinuityLedger,
    source: StoryAnchorEventRef, narrative: String, contracts: [CharacterContract] = []
  ) -> ContinuityUpdate {
    guard let data = input.data else {
      return .init(
        schemaVersion: 1, status: .needsReconciliation, delta: nil,
        issue: "missing", requestFingerprint: input.fingerprint)
    }
    do {
      let draft = try ContinuityDelta.decode(data)
      let delta = try resolve(
        draft, ledger: ledger, source: source, narrative: narrative, contracts: contracts)
      return .init(
        schemaVersion: 1, status: .recorded, delta: delta,
        issue: nil, requestFingerprint: input.fingerprint)
    } catch {
      return .init(
        schemaVersion: 1, status: .needsReconciliation, delta: nil,
        issue: (error as? ContinuityError)?.rawValue ?? ContinuityError.invalidOperation.rawValue,
        requestFingerprint: input.fingerprint)
    }
  }

  public static func apply(
    _ update: ContinuityUpdate?, to original: ContinuityLedger,
    source: StoryAnchorEventRef
  ) throws -> ContinuityLedger {
    var ledger = original
    guard let update else {
      ledger.legacyTurnCount += 1
      return ledger
    }
    guard update.schemaVersion == 1 else { throw ContinuityError.corruptHistory }
    if update.status == .needsReconciliation {
      guard update.delta == nil else { throw ContinuityError.corruptHistory }
      ledger.unresolvedTurnCount += 1
      ledger.latestGap = source
      return ledger
    }
    guard let delta = update.delta,
      delta.entities.count <= 116, delta.addedFacts.count <= 16, delta.changedFacts.count <= 48,
      Set(delta.entities.map(\.id)).count == delta.entities.count,
      Set(delta.addedFacts.map(\.id)).count == delta.addedFacts.count,
      Set(delta.changedFacts.map(\.id)).count == delta.changedFacts.count
    else { throw ContinuityError.corruptHistory }
    for entity in delta.entities {
      guard ledger.entities[entity.id] == nil,
        entity.source == nil || entity.source?.event == source
      else { throw ContinuityError.corruptHistory }
      ledger.entities[entity.id] = entity
    }
    if let scene = delta.scene {
      guard scene.source.event == source,
        scene.presentEntityIDs.allSatisfy({ ledger.entities[$0]?.kind == .character })
      else { throw ContinuityError.corruptHistory }
      ledger.scene = scene
    }
    for fact in delta.changedFacts {
      guard let old = ledger.facts[fact.id], fact.kind == old.kind,
        fact.subjectID == old.subjectID, fact.objectID == old.objectID, fact.slot == old.slot,
        fact.statement == old.statement, fact.evidence.first == old.evidence.first,
        fact.evidence.last?.event == source
      else { throw ContinuityError.corruptHistory }
      ledger.facts[fact.id] = fact
    }
    for fact in delta.addedFacts {
      guard ledger.facts[fact.id] == nil, fact.status == .active,
        fact.evidence.count == 1, fact.evidence.first?.event == source
      else { throw ContinuityError.corruptHistory }
      ledger.facts[fact.id] = fact
    }
    try validateLedger(ledger)
    return ledger
  }

  public static func validateLedger(_ ledger: ContinuityLedger) throws {
    guard ledger.schemaVersion == 1, ledger.entities.count <= 2_000, ledger.facts.count <= 10_000,
      ledger.legacyTurnCount >= 0, ledger.unresolvedTurnCount >= 0,
      ledger.entities.allSatisfy({ $0.key == $0.value.id }),
      ledger.facts.allSatisfy({ $0.key == $0.value.id })
    else { throw ContinuityError.corruptHistory }
    var slots = Set<String>()
    for fact in ledger.facts.values {
      guard ledger.entities[fact.subjectID] != nil,
        fact.objectID == nil || ledger.entities[fact.objectID!] != nil,
        fact.knownByEntityIDs.allSatisfy({ ledger.entities[$0]?.kind == .character }),
        !fact.evidence.isEmpty, fact.evidence.count <= 32,
        Set(fact.knownByEntityIDs).count == fact.knownByEntityIDs.count
      else { throw ContinuityError.corruptHistory }
      if fact.status == .active, isSingleValue(fact.kind) {
        guard slots.insert(slotKey(fact)).inserted else { throw ContinuityError.slotConflict }
      }
    }
    if let scene = ledger.scene {
      guard scene.presentEntityIDs.count <= 16,
        scene.presentEntityIDs.allSatisfy({ ledger.entities[$0]?.kind == .character })
      else { throw ContinuityError.corruptHistory }
    }
  }

  static func resolve(
    _ draft: ContinuityDelta, ledger: ContinuityLedger,
    source: StoryAnchorEventRef, narrative: String, contracts: [CharacterContract],
    calibrationID: UUID? = nil
  ) throws -> CommittedContinuityDelta {
    try CharacterContractFile(contracts: contracts).validate()
    guard source.sequence > 0, draft.entities.count <= 16, draft.facts.count <= 16,
      draft.resolutions.count <= 16, draft.knowledge.count <= 16
    else { throw ContinuityError.limits }
    var working = ledger
    var introduced: [ContinuityEntity] = []
    var aliases: [String: String] = [:]
    var additions: [ContinuityFact] = []
    var changes: [String: ContinuityFact] = [:]
    // Static identities are explicitly supplied by the currently bound world, not a name search.
    for contract in contracts where working.entities[contract.entityID] == nil {
      let entity = ContinuityEntity(
        id: contract.entityID, name: contract.displayName,
        kind: .character, provisional: false, source: nil)
      introduced.append(entity)
      working.entities[entity.id] = entity
    }
    func evidence(_ quote: String) throws -> ContinuityEvidence {
      guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        quote.count <= 300, narrative.contains(quote)
      else { throw ContinuityError.invalidEvidence }
      return .init(event: source, quote: quote, calibrationID: calibrationID)
    }
    let prefix =
      source.branchID.uuidString.lowercased() + "." + (calibrationID ?? source.turnID).uuidString.lowercased()
    for (index, entity) in draft.entities.enumerated() {
      guard entity.key.hasPrefix("new."), validKey(entity.key), aliases[entity.key] == nil,
        working.entities[entity.key] == nil,
        !entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        entity.name.count <= 100
      else { throw ContinuityError.invalidOperation }
      let quote = try evidence(entity.quote)
      let id = "entity." + prefix + ".\(index)"
      guard working.entities[id] == nil else { throw ContinuityError.invalidOperation }
      let resolved = ContinuityEntity(
        id: id, name: entity.name, kind: entity.kind, provisional: true, source: quote)
      aliases[entity.key] = id
      working.entities[id] = resolved
      introduced.append(resolved)
    }
    func entityID(_ value: String, characterOnly: Bool = false) throws -> String {
      let id = aliases[value] ?? value
      guard let entity = working.entities[id], !characterOnly || entity.kind == .character
      else { throw ContinuityError.unknownEntity }
      return id
    }
    var scene: SceneContinuity?
    if let proposed = draft.scene {
      guard proposed.location.count <= 150, proposed.time.count <= 100,
        proposed.presentEntityIDs.count <= 16,
        Set(proposed.presentEntityIDs).count == proposed.presentEntityIDs.count
      else { throw ContinuityError.limits }
      scene = .init(
        location: proposed.location, time: proposed.time,
        presentEntityIDs: try proposed.presentEntityIDs.map {
          try entityID($0, characterOnly: true)
        }.sorted(),
        source: try evidence(proposed.quote))
      working.scene = scene
    }
    var resolutionsSeen = Set<String>()
    for resolution in draft.resolutions {
      guard var fact = working.facts[resolution.factID] else { throw ContinuityError.unknownFact }
      guard resolutionsSeen.insert(fact.id).inserted, fact.status == .active else {
        throw ContinuityError.invalidLifecycle
      }
      let allowed: Set<ContinuityFactStatus> =
        fact.kind == .promise
        ? [.fulfilled, .broken, .released] : [.resolved, .released]
      guard allowed.contains(resolution.status) else { throw ContinuityError.invalidLifecycle }
      fact.status = resolution.status
      addEvidence(try evidence(resolution.quote), to: &fact)
      working.facts[fact.id] = fact
      changes[fact.id] = fact
    }
    for (index, proposed) in draft.facts.enumerated() {
      guard validKey(proposed.slot), proposed.statement.count <= 500,
        !proposed.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        proposed.knownByEntityIDs.count <= 32,
        Set(proposed.knownByEntityIDs).count == proposed.knownByEntityIDs.count
      else { throw ContinuityError.limits }
      let subject = try entityID(proposed.subjectID)
      let object = try proposed.objectID.map { try entityID($0) }
      if proposed.kind == .possession {
        guard let object, working.entities[object]?.kind == .item,
          [.character, .group].contains(working.entities[subject]!.kind)
        else { throw ContinuityError.invalidOperation }
      }
      let fact = ContinuityFact(
        id: "fact." + prefix + ".\(index)", kind: proposed.kind,
        subjectID: subject, objectID: object, slot: proposed.slot, statement: proposed.statement,
        status: .active,
        knownByEntityIDs: try proposed.knownByEntityIDs.map {
          try entityID($0, characterOnly: true)
        }.sorted(),
        evidence: [try evidence(proposed.quote)])
      if let replaced = proposed.replacesFactID {
        guard var old = working.facts[replaced] else { throw ContinuityError.unknownFact }
        guard old.status == .active, isSingleValue(old.kind), slotKey(old) == slotKey(fact),
          ledger.facts[replaced] != nil
        else { throw ContinuityError.invalidLifecycle }
        old.status = .superseded
        addEvidence(fact.evidence[0], to: &old)
        working.facts[old.id] = old
        changes[old.id] = old
      }
      if isSingleValue(fact.kind),
        working.facts.values.contains(where: {
          $0.status == .active && slotKey($0) == slotKey(fact)
        })
      {
        throw ContinuityError.slotConflict
      }
      working.facts[fact.id] = fact
      additions.append(fact)
    }
    var knowledgeSeen = Set<String>()
    for proposed in draft.knowledge {
      guard var fact = working.facts[proposed.factID], ledger.facts[proposed.factID] != nil
      else { throw ContinuityError.unknownFact }
      let id = try entityID(proposed.entityID, characterOnly: true)
      guard knowledgeSeen.insert(fact.id + ":" + id).inserted else {
        throw ContinuityError.invalidOperation
      }
      let quote = try evidence(proposed.quote)
      switch proposed.operation {
      case .learn:
        if fact.knownByEntityIDs.contains(id) { continue }
        fact.knownByEntityIDs.append(id)
        fact.knownByEntityIDs.sort()
      case .forget:
        guard fact.knownByEntityIDs.contains(id) else { throw ContinuityError.invalidLifecycle }
        fact.knownByEntityIDs.removeAll { $0 == id }
      }
      addEvidence(quote, to: &fact)
      working.facts[fact.id] = fact
      changes[fact.id] = fact
    }
    try validateLedger(working)
    return .init(
      entities: introduced, scene: scene, addedFacts: additions,
      changedFacts: changes.values.sorted { $0.id < $1.id })
  }

  private static func isSingleValue(_ kind: ContinuityFactKind) -> Bool {
    [.condition, .relationship, .possession].contains(kind)
  }
  private static func slotKey(_ fact: ContinuityFact) -> String {
    if fact.kind == .possession { return "possession:" + (fact.objectID ?? "") }
    return [fact.kind.rawValue, fact.subjectID, fact.objectID ?? "", fact.slot].joined(
      separator: ":")
  }
  private static func validKey(_ key: String) -> Bool {
    !key.isEmpty && key.utf8.count <= 64
      && key.unicodeScalars.allSatisfy {
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        ).contains($0)
      }
  }
  private static func addEvidence(_ source: ContinuityEvidence, to fact: inout ContinuityFact) {
    if fact.evidence.last != source { fact.evidence.append(source) }
    if fact.evidence.count > 32 { fact.evidence.removeSubrange(1..<(fact.evidence.count - 31)) }
  }
}
