import NovelDocumentCore
import StoryworldCore
import SwiftUI
import WritingCore

struct AdaptationWorkspaceView: View {
  @ObservedObject var model: AdaptationViewModel
  let importFile: () -> Void
  let didPublish: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab = "书案"
  @State private var sheet: Sheet?
  @State private var acknowledgeBookcase = false
  @State private var confirmRequest = false
  @State private var confirmRegenerate = false
  private enum Sheet: Identifiable {
    case original, configuration, direction(Bool), bookcase, character(BookcaseCharacter), anchor(AdaptationAnchor?), draft(AdaptationDraftView)
    var id: String {
      switch self {
      case .original: "original"
      case .configuration: "configuration"
      case .direction(let update): "direction-\(update)"
      case .bookcase: "bookcase"
      case .character(let card): "character-" + card.id
      case .anchor(let anchor): "anchor-" + (anchor?.id ?? "new")
      case .draft(let view): "draft-" + view.draft.id.uuidString
      }
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if let job = model.job { workspace(job) } else { taskList }
      if let error = model.errorMessage {
        HStack(alignment: .top) {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Spacer(); Button("关闭") { model.errorMessage = nil }
        }.padding().background(.thinMaterial)
      }
    }
    .task { await model.reload() }
    .onDisappear { model.cancel() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancel() } }
    .sheet(item: $sheet) { item in
      sheetView(item)
    }
    .confirmationDialog("允许重新请求？", isPresented: $confirmRequest, titleVisibility: .visible) {
      if let pending = model.pending {
        Button("已核对，允许继续") { Task { await model.acknowledgeRequest(pending) } }
      }
    } message: { Text("该请求可能已在供应商完成并计费。请先核对供应商记录；确认后再次继续可能产生重复费用。") }
    .confirmationDialog("开始新一轮正文生成？", isPresented: $confirmRegenerate, titleVisibility: .visible) {
      Button("新建生成轮次") { model.start(.write, newRound: true) }
    } message: { Text("选中范围将按新轮次请求模型并产生待审版本，旧版本仍保留。普通断点续跑请使用“继续当前轮”。") }
  }
  private var taskList: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("改编与逐章写作").font(.title2.bold())
      Text("从已有小说创建独立改编任务，或从章节计划开始原创写作。原书保留，生成结果先由你审阅。")
        .foregroundStyle(.secondary)
      HStack {
        Button("导入小说", systemImage: "square.and.arrow.down", action: importFile)
        Button("原创计划", systemImage: "plus") { sheet = .original }
        Button("刷新") { Task { await model.reload() } }
      }.disabled(model.busy)
      List(model.jobs) { job in
        Button { Task { await model.selectJob(job.id) } } label: {
          VStack(alignment: .leading) {
            Text(job.title).font(.headline)
            Text("\(job.variants.count) 个方向 · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy)
      }.listStyle(.plain)
      if model.busy { ProgressView("正在保存原文…") }
    }.padding()
  }
  private func workspace(_ job: AdaptationJob) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Button("所有任务", systemImage: "chevron.left") { model.leaveJob() }.disabled(model.busy)
          Spacer()
          Button("刷新") { Task { await model.refreshCurrent() } }.disabled(model.busy)
          Button("配置", systemImage: "slider.horizontal.3") { sheet = .configuration }.disabled(model.busy)
        }
        Text(job.title).font(.title2.bold()).textSelection(.enabled)
        if let notice = model.notice { Text(notice).foregroundStyle(Color.wbTeal) }
        if let pending = model.pending {
          // A titled GroupBox with selectable text in this scroll view crashes
          // Codex's native reader. Keep the heading and text selection separate.
          VStack(alignment: .leading, spacing: 8) {
            Text("有待核对的模型请求").font(.headline).accessibilityAddTraits(.isHeader)
            Text("用途：\(pending.identity.purpose)\n请求：\(pending.id.uuidString)\n开始：\(pending.startedAt.formatted())").font(.caption).textSelection(.enabled)
            Button("核对后允许继续") { confirmRequest = true }.disabled(model.busy)
          }.frame(maxWidth: .infinity, alignment: .leading).padding().wbGlassPanel()
        }
        if model.generating {
          HStack { ProgressView(); Text(model.progressText); Spacer(); Button("取消") { model.cancel() } }
        } else if !model.progressText.isEmpty { Text(model.progressText).font(.caption).foregroundStyle(.secondary) }
        if !model.reportDetails.isEmpty {
          DisclosureGroup("执行缺口与提示（\(model.reportDetails.count)）") {
            ForEach(Array(model.reportDetails.enumerated()), id: \.offset) { _, message in Text(message).font(.caption).textSelection(.enabled) }
          }
        }
        Picker("工作步骤", selection: $tab) {
          ForEach(["书案", "锚点", "正文", "成书"], id: \.self) { Text($0) }
        }.pickerStyle(.segmented)
        Group {
          switch tab {
          case "书案": bookcasePanel
          case "锚点": anchorPanel
          case "正文": draftPanel(job)
          default: assemblyPanel
          }
        }.disabled(model.busy)
      }.padding().frame(maxWidth: 950).frame(maxWidth: .infinity)
    }
  }
  private var bookcasePanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Button("提取／继续书案") { model.start(.bookcase) }.disabled(model.pending != nil)
        Text("先选模型与范围，再从原文提取人物、规则和章节证据。").font(.caption).foregroundStyle(.secondary)
      }
      if !model.bookcases.isEmpty {
        Picker("书案版本", selection: $model.selectedBookcaseID) {
          ForEach(model.bookcases) { proposal in
            Text("\(proposal.status.rawValue) · \(proposal.id.uuidString.prefix(8))").tag(Optional(proposal.id))
          }
        }.onChange(of: model.selectedBookcaseID) { _, _ in acknowledgeBookcase = false }
      }
      if let proposal = model.selectedBookcase {
        Text("\(proposal.content.characters.count) 人物 · \(proposal.content.relationships.count) 关系 · \(proposal.content.worldRules.count) 规则 · \(proposal.content.chapters.count) 章节")
        if let source = model.source {
          let missing = proposal.content.missingChapterIDs(in: source)
          if !missing.isEmpty {
            DisclosureGroup("缺少 \(missing.count) 章证据") { Text(missing.joined(separator: "、")).font(.caption).textSelection(.enabled) }
            Toggle("已知以上缺口，仍采用本书案", isOn: $acknowledgeBookcase)
          }
        }
        HStack {
          Button("批准书案") { Task { await model.decideBookcase(proposal, action: .approve, acknowledgeGaps: acknowledgeBookcase) } }
            .disabled(proposal.status != .pending)
          Button("拒绝") { Task { await model.decideBookcase(proposal, action: .reject, acknowledgeGaps: false) } }.disabled(proposal.status != .pending)
          Button("新增人物") { sheet = .character(.init(id: "author-" + UUID().uuidString.lowercased(), name: "")) }
        }
        ForEach(proposal.content.characters) { card in
          GroupBox {
            VStack(alignment: .leading, spacing: 7) {
              HStack { Text(card.name).font(.headline); Spacer(); Button("核对／编辑／合并") { sheet = .character(card) } }
              Text(card.identityCore)
              Text("身份标识：\(card.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              ForEach(Array(card.evidence.enumerated()), id: \.offset) { _, evidence in
                Text("\(evidence.chapterID)：\(evidence.quote)").font(.caption).textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        DisclosureGroup("关系、世界规则与章节索引") {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(proposal.content.relationships) { relation in Text("\(relation.a) ↔ \(relation.b)：\(relation.summary)") }
            ForEach(proposal.content.worldRules) { rule in Text("\(rule.name)：\(rule.facts.joined(separator: "；"))\n\(rule.binding)") }
            ForEach(proposal.content.chapters) { chapter in Text("\(chapter.title ?? chapter.chapterID)：\(chapter.summary)") }
          }.textSelection(.enabled)
        }
        Button("查看／修订完整书案") { sheet = .bookcase }
        Text("同名不等于同一人。人物合并由你明确选择；编辑后产生新的待审书案，旧版本保留。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var anchorPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Button("扫描／继续锚点") { model.start(.anchors) }.disabled(model.pending != nil)
        Button("人工补点") { sheet = .anchor(nil) }
      }
      if !model.sparseChapterIDs.isEmpty {
        DisclosureGroup("\(model.sparseChapterIDs.count) 章没有可用锚点") {
          Text("尚未扫描与扫描后无位置并不相同。可继续扫描，或核对原文后人工补点。\n" + model.sparseChapterIDs.joined(separator: "、"))
            .font(.caption).textSelection(.enabled)
        }
      }
      ForEach(model.anchors?.anchors ?? []) { anchor in
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            HStack { Text(anchor.id).font(.caption); Spacer(); Text(reviewLabel(model.anchors?.reviews[anchor.id]?.action)) }
            Text(anchor.quote.isEmpty ? "章首位置" : anchor.quote).textSelection(.enabled)
            Text(anchor.note).foregroundStyle(.secondary)
            Button("查看原文／审阅位置") { sheet = .anchor(anchor) }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
  private func draftPanel(_ job: AdaptationJob) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if !job.variants.isEmpty {
        Picker("正文方向", selection: Binding(get: { model.selectedVariantID }, set: { id in if let id { Task { await model.selectVariant(id) } } })) {
          ForEach(job.variants) { Text($0.title).tag(Optional($0.id)) }
        }
      }
      HStack {
        Button("新建方向") { sheet = .direction(false) }
        Button("核对方向合同") { sheet = .direction(true) }.disabled(model.direction == nil)
      }
      Text("生成范围：\(model.configuration.writeScope == .chapters ? "完整章节" : "已批准锚点")。可在配置中调整章节、人物和请求上限。").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("生成／继续当前轮") { model.start(.write) }
        Button("新一轮生成") { confirmRegenerate = true }
      }.disabled(model.selectedVariantID == nil || model.pending != nil)
      ForEach(model.drafts?.current ?? [], id: \.draft.id) { view in
        GroupBox {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
              Text(view.draft.content.title).font(.headline)
              Text("\(view.draft.content.body.count) 字 · \(view.isStale ? "依赖已过期" : reviewLabel(view.decision?.action))")
                .foregroundStyle(view.isStale ? Color.orange : Color.secondary)
              Text(view.draft.content.recap).font(.caption)
            }
            Spacer(); Button("对照／审阅") { sheet = .draft(view) }
          }
        }
      }
    }
  }
  private var assemblyPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("先批准正文，再查看装配预览。过期候选、未批准版本和交叠修改范围会阻止成书。").foregroundStyle(.secondary)
      Button("生成成书预览") { Task { await model.prepareAssembly() } }.disabled(model.selectedVariantID == nil)
      if let assembly = model.assembly {
        AdaptationAssemblyPanel(model: model, assembly: assembly, didPublish: didPublish).id(assembly.draftRevision)
      }
    }
  }
  @ViewBuilder private func sheetView(_ sheet: Sheet) -> some View {
    switch sheet {
    case .original: AdaptationOriginalEditor(model: model)
    case .configuration:
      if let job = model.job { AdaptationConfigurationEditor(model: model, jobID: job.id, configuration: model.configuration) }
    case .direction(let update): AdaptationDirectionEditor(model: model, revision: update ? model.direction : nil)
    case .bookcase:
      if let proposal = model.selectedBookcase { AdaptationBookcaseEditor(model: model, proposal: proposal) }
    case .character(let card):
      if let proposal = model.selectedBookcase { AdaptationCharacterEditor(model: model, proposal: proposal, card: card) }
    case .anchor(let anchor): AdaptationAnchorEditor(model: model, anchor: anchor, revision: model.anchors?.revision)
    case .draft(let view): AdaptationDraftEditor(model: model, view: view, revision: model.drafts?.revision)
    }
  }
}

private func reviewLabel(_ action: ApprovalAction?) -> String { action == .approve ? "已批准" : action == .reject ? "已拒绝" : "待审阅" }

private struct AdaptationAssemblyPanel: View {
  @ObservedObject var model: AdaptationViewModel
  let assembly: AdaptationAssembly
  let didPublish: () -> Void
  @State private var acknowledge = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("\(assembly.chapters.count) 章 · \(assembly.selectedDraftIDs.count) 个已批准版本")
      if !assembly.unchangedChapterIDs.isEmpty {
        DisclosureGroup("\(assembly.unchangedChapterIDs.count) 章沿用原文") { Text(assembly.unchangedChapterIDs.joined(separator: "、")).font(.caption) }
        Toggle("已核对并同意沿用这些原文章节", isOn: $acknowledge)
      }
      DisclosureGroup("原文与新文对照报告") { Text(assembly.comparisonMarkdown).font(.callout).textSelection(.enabled) }
      HStack {
        Button("准备导出文件") { Task { _ = await model.export(acknowledge: acknowledge, publish: false) } }
        Button("加入书架") { Task { if await model.export(acknowledge: acknowledge, publish: true) { didPublish() } } }
      }.disabled(!assembly.unchangedChapterIDs.isEmpty && !acknowledge)
      if let output = model.exported {
        HStack {
          ShareLink("导出 EPUB", item: output.epubURL)
          ShareLink("导出 TXT", item: output.textURL)
          ShareLink("导出对照报告", item: output.comparisonURL)
        }
      }
      Text("未修改资源保留原字节；修改章节重建正文区，不承诺保留原有复杂排版。原书和不同方向分别保留。").font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct AdaptationEditorShell<Content: View>: View {
  let title: String
  @ObservedObject var model: AdaptationViewModel
  @ViewBuilder let content: () -> Content
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        content().disabled(model.busy)
        if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }.formStyle(.grouped).navigationTitle(title)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(model.busy) } }
    }.frame(minWidth: 320, idealWidth: 680, minHeight: 480).interactiveDismissDisabled(model.busy)
  }
}

func adaptationLines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
func adaptationArrayBinding(_ values: Binding<[String]>) -> Binding<String> {
  Binding(get: { values.wrappedValue.joined(separator: "\n") }, set: { values.wrappedValue = $0.components(separatedBy: .newlines) })
}
