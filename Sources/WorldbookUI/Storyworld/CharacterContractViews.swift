import CharacterLibraryCore
import StoryworldCore
import SwiftUI

/// This projection only runs on explicit preview/copy. No runtime reads of the global library.
enum CharacterContractProjection {
  static func preview(_ profile: CharacterProfile, existing: CharacterContract? = nil)
    -> CharacterContract
  {
    var card = existing ?? CharacterContract(displayName: profile.name)
    card.displayName = profile.name
    card.immutableTraits = lines(profile.fields.personality)
    card.speechRules = lines(profile.fields.speechStyle)
    card.sourceLibraryID = profile.id
    return card
  }

  static func lines(_ value: String) -> [String] {
    value.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    .filter { !$0.isEmpty }
  }
}

private struct ContractEdit: Identifiable {
  let id = UUID()
  let storyworldID: UUID
  let state: CharacterContractState
  let card: CharacterContract
}

struct StoryworldCharacterContractsView: View {
  @ObservedObject var model: StoryworldViewModel
  let storyworldID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var state: CharacterContractState?
  @State private var editing: ContractEdit?
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("身份内核与说话方式保存在本世界书。当前情绪、持有物与知情范围属于游玩过程，不写入静态契约。")
          Text("保存后，已有游玩线会提示确认设定变化。")
        }.foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        if let state {
          ForEach(state.file.contracts) { card in
            Button {
              editing = .init(storyworldID: storyworldID, state: state, card: card)
            } label: {
              VStack(alignment: .leading) {
                Text(card.displayName).font(.headline)
                Text(card.entityID).font(.caption).foregroundStyle(.secondary)
                if !card.speechRules.isEmpty {
                  Text(card.speechRules.joined(separator: "；")).lineLimit(2)
                }
              }
            }
          }
          Button("新增角色契约") {
            editing = .init(storyworldID: storyworldID, state: state, card: .init(displayName: ""))
          }
        }
      }
      .navigationTitle("角色契约")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
      .task(id: storyworldID) { await reload() }
      .sheet(item: $editing, onDismiss: { Task { await reload() } }) { edit in
        CharacterContractEditor(
          model: model, storyworldID: edit.storyworldID, state: edit.state,
          initial: edit.card, saveTitle: "保存契约")
      }
    }
    #if os(macOS)
      .frame(minWidth: 540, minHeight: 520)
    #endif
  }

  private func reload() async {
    do {
      state = try await model.characterContractState(storyworldID)
      error = nil
    } catch {
      state = nil
      self.error = error.localizedDescription
    }
  }
}

struct CharacterContractCopySheet: View {
  @ObservedObject var model: StoryworldViewModel
  let profile: CharacterProfile
  @Environment(\.dismiss) private var dismiss
  @State private var targetID: UUID?
  @State private var editing: ContractEdit?
  @State private var error: String?
  @State private var working = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("从「\(profile.name)」复制性格与语言风格。先预览并编辑，再写入所选世界书；角色库的后续修改不会同步。")
          Picker("目标世界书", selection: $targetID) {
            Text("请选择").tag(UUID?.none)
            ForEach(model.records) { record in Text(record.manifest.title).tag(Optional(record.id))
            }
          }
          Button("预览契约") { Task { await preview() } }
            .disabled(targetID == nil || working)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("复制角色契约")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
      .task { await model.reload() }
      .sheet(item: $editing) { edit in
        CharacterContractEditor(
          model: model, storyworldID: edit.storyworldID, state: edit.state,
          initial: edit.card, saveTitle: "复制到这本世界书")
      }
    }
    #if os(macOS)
      .frame(minWidth: 540, minHeight: 460)
    #endif
  }

  private func preview() async {
    guard !working, let selected = targetID else { return }
    working = true
    defer { working = false }
    do {
      let current = try await model.characterContractState(selected)
      guard targetID == selected else { return }
      let matches = current.file.contracts.filter { $0.sourceLibraryID == profile.id }
      guard matches.count <= 1 else {
        error = "这本世界书已有多份来自该角色的契约，请在世界书的角色契约页选择要编辑的一份。"
        return
      }
      editing = .init(
        storyworldID: selected, state: current,
        card: CharacterContractProjection.preview(profile, existing: matches.first))
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

private struct CharacterContractEditor: View {
  @ObservedObject var model: StoryworldViewModel
  let storyworldID: UUID
  let state: CharacterContractState
  let saveTitle: String
  @Environment(\.dismiss) private var dismiss
  @State private var card: CharacterContract
  @State private var working = false
  @State private var error: String?

  init(
    model: StoryworldViewModel, storyworldID: UUID, state: CharacterContractState,
    initial: CharacterContract, saveTitle: String
  ) {
    self.model = model
    self.storyworldID = storyworldID
    self.state = state
    self.saveTitle = saveTitle
    _card = State(initialValue: initial)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("角色身份") {
          TextField("姓名（最多 100 字）", text: $card.displayName)
          Text("独立标识：\(card.entityID)").font(.caption).textSelection(.enabled)
          lines("别名（每行一个，最多 20 个）", field: \.aliases)
        }
        Section("静态约束（每行一条，最多 20 条，每条 500 字）") {
          lines("身份内核与稳定性格", field: \.immutableTraits)
          lines("长期动机", field: \.baselineMotivations)
          lines("说话方式", field: \.speechRules)
          lines("不可突破的底线", field: \.neverDo)
          lines("示例台词（最多 4 句，每句 200 字）", field: \.sampleLines)
        }
        Section {
          Text("同名角色仍按独立标识区分。保存改变世界设定，已有游玩线需确认后使用。")
            .foregroundStyle(.secondary)
          if state.file.contracts.contains(where: { $0.id == card.id }) {
            Button("移除此契约", role: .destructive) { Task { await save(removing: true) } }
          }
          if let error { Text(error).foregroundStyle(.red) }
        }
      }
      .disabled(working)
      .navigationTitle("预览角色契约")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) }
        ToolbarItem(placement: .confirmationAction) {
          Button(saveTitle) { Task { await save(removing: false) } }.disabled(working)
        }
      }
      .interactiveDismissDisabled(working)
    }
    #if os(macOS)
      .frame(minWidth: 560, minHeight: 600)
    #endif
  }

  private func lines(_ title: String, field: WritableKeyPath<CharacterContract, [String]>)
    -> some View
  {
    TextField(
      title,
      text: Binding(
        get: { card[keyPath: field].joined(separator: "\n") },
        set: { card[keyPath: field] = $0.components(separatedBy: "\n") }), axis: .vertical
    )
    .lineLimit(2...8)
  }

  private func save(removing: Bool) async {
    guard !working else { return }
    working = true
    defer { working = false }
    var file = state.file
    file.contracts.removeAll { $0.id == card.id }
    if !removing {
      var cleaned = card
      cleaned.displayName = cleaned.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      for key in [
        \CharacterContract.aliases, \.immutableTraits, \.baselineMotivations,
        \.speechRules, \.sampleLines, \.neverDo,
      ] {
        cleaned[keyPath: key] = CharacterContractProjection.lines(
          cleaned[keyPath: key].joined(separator: "\n"))
      }
      if let index = state.file.contracts.firstIndex(where: { $0.id == card.id }) {
        file.contracts.insert(cleaned, at: index)
      } else {
        file.contracts.append(cleaned)
      }
    }
    do {
      try await model.saveCharacterContracts(
        file, storyworldID: storyworldID,
        expectedFingerprint: state.fingerprint)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
