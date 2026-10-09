import SwiftUI
import WritingCore

struct AdaptationBookcaseEditor: View {
  @ObservedObject var model: AdaptationViewModel
  let proposal: BookcaseProposal
  @State private var json: String
  @State private var previous: String?
  @Environment(\.dismiss) private var dismiss
  init(model: AdaptationViewModel, proposal: BookcaseProposal) {
    self.model = model; self.proposal = proposal
    let encoder = AdaptationCoding.encoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    _json = State(initialValue: (try? encoder.encode(proposal.content)).map { String(decoding: $0, as: UTF8.self) } ?? "")
  }
  var body: some View {
    AdaptationEditorShell(title: "完整书案与高级修订", model: model) {
      Text("此处用于关系、世界规则、章节证据等完整结构的修订。人物常用字段可在人物卡中编辑。身份引用及引文仍须通过原文校验；保存不会自动批准。").font(.caption)
      TextEditor(text: $json).font(.system(.caption, design: .monospaced)).frame(minHeight: 340)
      if let id = proposal.parentID, let parent = model.bookcases.first(where: { $0.id == id }) {
        DisclosureGroup("对照上一书案版本") {
          Text((try? AdaptationCoding.encoder().encode(parent.content)).map { String(decoding: $0, as: UTF8.self) } ?? "读取失败").font(.caption).textSelection(.enabled)
        }
      }
      Button("保存为新的待审书案") {
        do {
          let value = try AdaptationCoding.decoder().decode(NovelBookcase.self, from: Data(json.utf8))
          Task { if await model.saveBookcase(value, parent: proposal) { dismiss() } }
        } catch { model.errorMessage = error.localizedDescription }
      }
    }
  }
}

struct AdaptationCharacterEditor: View {
  @ObservedObject var model: AdaptationViewModel
  let proposal: BookcaseProposal
  @State private var card: BookcaseCharacter
  @State private var mergeIDs: Set<String> = []
  @State private var legacyJSON = ""
  @Environment(\.dismiss) private var dismiss
  init(model: AdaptationViewModel, proposal: BookcaseProposal, card: BookcaseCharacter) {
    self.model = model; self.proposal = proposal; _card = State(initialValue: card)
  }
  var body: some View {
    AdaptationEditorShell(title: "人物卡核对", model: model) {
      Text("身份标识：\(card.id)").font(.caption).textSelection(.enabled)
      TextField("名字", text: $card.name)
      TextField("身份内核", text: $card.identityCore, axis: .vertical)
      TextField("说话方式", text: $card.speechStyle, axis: .vertical)
      TextField("关系立场", text: $card.relationStance, axis: .vertical)
      Text("硬事实，每行一项").font(.caption)
      TextEditor(text: adaptationArrayBinding($card.hardFacts)).frame(minHeight: 100)
      Text("示例台词，每行一项；应有对应的原文证据").font(.caption)
      TextEditor(text: adaptationArrayBinding($card.sampleLines)).frame(minHeight: 80)
      DisclosureGroup("原文引文") { ForEach(Array(card.evidence.enumerated()), id: \.offset) { _, item in Text("\(item.chapterID)：\(item.quote)").textSelection(.enabled) } }
      DisclosureGroup("将其它身份合并到本卡") {
        Text("仅选择确认是同一人的身份。以当前卡字段为准，引用会同步调整；同名不自动合并。").font(.caption)
        ForEach(proposal.content.characters.filter { $0.id != card.id }) { other in
          Toggle("\(other.name) · \(other.id)", isOn: Binding(get: { mergeIDs.contains(other.id) }, set: { if $0 { mergeIDs.insert(other.id) } else { mergeIDs.remove(other.id) } }))
        }
      }
      DisclosureGroup("导入已有人工角色卡") {
        Text("粘贴旧角色卡 JSON，沿用本卡的独立身份标识；请核对转换后的字段。").font(.caption)
        TextEditor(text: $legacyJSON).frame(minHeight: 100)
        Button("读取角色卡") {
          do { card = try BookcaseCharacter.importLegacy(Data(legacyJSON.utf8), characterID: card.id) }
          catch { model.errorMessage = error.localizedDescription }
        }
      }
      Button("保存为新的待审书案") {
        card.hardFacts = adaptationLines(card.hardFacts.joined(separator: "\n")); card.sampleLines = adaptationLines(card.sampleLines.joined(separator: "\n"))
        var ids = mergeIDs
        if !ids.isEmpty, proposal.content.characters.contains(where: { $0.id == card.id }) { ids.insert(card.id) }
        Task { if await model.saveCharacter(card, parent: proposal, mergeIDs: ids) { dismiss() } }
      }
    }
  }
}

struct AdaptationAnchorEditor: View {
  @ObservedObject var model: AdaptationViewModel
  let anchor: AdaptationAnchor?
  let revision: UUID?
  @State private var chapterID: String
  @State private var quote: String
  @State private var offset = ""
  @State private var note: String
  @State private var action: AdaptationAnchorAction
  @State private var intensity: Int
  @Environment(\.dismiss) private var dismiss
  init(model: AdaptationViewModel, anchor: AdaptationAnchor?, revision: UUID?) {
    self.model = model; self.anchor = anchor; self.revision = revision
    _chapterID = State(initialValue: anchor?.source.chapterID ?? model.source?.chapters.first?.id ?? "")
    _quote = State(initialValue: anchor?.quote ?? ""); _note = State(initialValue: anchor?.note ?? "")
    let review = anchor.flatMap { model.anchors?.reviews[$0.id] }
    _action = State(initialValue: review?.generationAction ?? anchor?.suggestedAction ?? .insertion)
    _intensity = State(initialValue: review?.intensity ?? 3)
  }
  var body: some View {
    AdaptationEditorShell(title: anchor == nil ? "人工补点" : "锚点审阅", model: model) {
      Picker("章节", selection: $chapterID) { ForEach(model.source?.chapters ?? []) { Text($0.title).tag($0.id) } }.disabled(anchor != nil)
      DisclosureGroup("查看完整原章") {
        Text(model.source?.chapters.first(where: { $0.id == chapterID })?.content ?? "").textSelection(.enabled)
      }
      Text("粘贴原文摘录；留空表示章首。原文中的重复摘录需要明确位置。").font(.caption)
      TextEditor(text: $quote).frame(minHeight: 100).disabled(anchor != nil)
      if anchor == nil { TextField("重复引文的 UTF-16 起点（可选）", text: $offset) }
      TextField("位置说明", text: $note, axis: .vertical)
      if let anchor {
        Picker("生成动作", selection: $action) { ForEach(AdaptationAnchorAction.allCases, id: \.self) { Text($0.adaptationLabel).tag($0) } }
        Stepper("强度 \(intensity)", value: $intensity, in: 1...5)
        Text("批准的是生成位置及要求，正文生成后仍需另行审阅。修改说明会撤销旧决定并记录本次审阅。").font(.caption)
        HStack {
          Button("批准位置") { decide(anchor, .approve) }
          Button("拒绝位置") { decide(anchor, .reject) }
        }
      } else {
        Button("保存待审锚点") {
          let position = offset.trimmingCharacters(in: .whitespacesAndNewlines)
          if !position.isEmpty && Int(position) == nil { model.errorMessage = "原文起点须为整数。"; return }
          Task { if await model.addAnchor(chapterID: chapterID, quote: quote, offset: Int(position), note: note) { dismiss() } }
        }
      }
    }
  }
  private func decide(_ anchor: AdaptationAnchor, _ approval: ApprovalAction) {
    Task { if await model.reviewAnchor(anchor, expectedRevision: revision, note: note, action: approval, generationAction: action, intensity: intensity) { dismiss() } }
  }
}

struct AdaptationDraftEditor: View {
  @ObservedObject var model: AdaptationViewModel
  let view: AdaptationDraftView
  let revision: UUID?
  @State private var value: AdaptationDraftContent
  @State private var note = ""
  @State private var acknowledge = false
  @State private var history: [AdaptationDraft] = []
  @Environment(\.dismiss) private var dismiss
  init(model: AdaptationViewModel, view: AdaptationDraftView, revision: UUID?) {
    self.model = model; self.view = view; self.revision = revision; _value = State(initialValue: view.draft.content)
  }
  var body: some View {
    AdaptationEditorShell(title: "正文对照与审阅", model: model) {
      Text("版本：\(view.draft.id.uuidString)").font(.caption).textSelection(.enabled)
      if view.isStale { Text("依赖已过期。先修订或重新生成前章，再处理本章。").foregroundStyle(.orange) }
      DisclosureGroup("对照原文") { Text(model.source?.chapters.first(where: { $0.id == view.draft.context.target.chapterID })?.content ?? "").textSelection(.enabled) }
      TextField("标题", text: $value.title)
      TextEditor(text: $value.body).frame(minHeight: 280)
      Text("正文 \(value.body.count) 字").font(.caption)
      TextField("前情摘要（最多 80 字）", text: $value.recap, axis: .vertical)
      Text("模型章审是自报，不代表已核验。").font(.caption).foregroundStyle(.secondary)
      TextField("章审记录", text: $value.reviewLine, axis: .vertical)
      DisclosureGroup("表达组合") {
        TextField("触发", text: $value.recipe.trigger)
        TextField("场景", text: $value.recipe.setting)
        TextField("写法", text: $value.recipe.technique)
      }
      ForEach(view.draft.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
      if !view.draft.warnings.isEmpty { Toggle("已核对上述告警", isOn: $acknowledge) }
      TextField("作者审阅说明", text: $note, axis: .vertical)
      Button("保存修改为新待审版本") { Task { if await model.saveDraft(view.draft, content: value) { dismiss() } } }.disabled(value == view.draft.content)
      HStack {
        Button("批准正文") { decide(.approve) }.disabled(view.isStale)
        Button("拒绝正文") { decide(.reject) }
      }.disabled(value != view.draft.content || view.decision != nil)
      if value != view.draft.content { Text("有未保存修改，请先保存新版本再批准。").font(.caption) }
      ForEach(history) { item in
        DisclosureGroup("历史版本 \(item.id.uuidString.prefix(8))") {
          Text(item.content.title + "\n\n" + item.content.body + "\n\n摘要：" + item.content.recap).textSelection(.enabled)
        }
      }
      if (history.last ?? view.draft).parentID != nil {
        Button("读取更早版本") { Task { if let old = await model.previousDraft(history.last ?? view.draft) { history.append(old) } } }
      }
    }
  }
  private func decide(_ action: ApprovalAction) {
    Task { if await model.decideDraft(view.draft, revision: revision, action: action, note: note, acknowledge: acknowledge) { dismiss() } }
  }
}
