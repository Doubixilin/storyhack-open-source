import SwiftUI
import WritingAssistantCore
import WritingCore

struct WritingDeskView: View {
  @ObservedObject var model: WritingViewModel
  @ObservedObject var adaptation: AdaptationViewModel
  let importAdaptation: () -> Void
  let didPublish: () -> Void
  @State private var mode = 1
  var body: some View {
    VStack(spacing: 0) {
      Picker("写作方式", selection: $mode) {
        Text("手工作品").tag(0)
        Text("改编与逐章写作").tag(1)
      }.pickerStyle(.segmented).padding().disabled(adaptation.busy)
      if mode == 0 { LegacyWritingDeskView(model: model, didPublish: didPublish) }
      else { AdaptationWorkspaceView(model: adaptation, importFile: importAdaptation, didPublish: didPublish) }
    }
  }
}

private struct LegacyWritingDeskView: View {
  @ObservedObject var model: WritingViewModel
  let didPublish: () -> Void

  @State private var isCreatePresented = false
  @State private var newTitle = ""
  @State private var newAuthor = ""

  var body: some View {
    HStack(spacing: 0) {
      projectSidebar
      Divider()
      Group {
        if let snapshot = model.snapshot {
          workspace(snapshot)
        } else {
          WBEmptyStateView(
            title: "写作台",
            symbol: "square.and.pencil",
            message: "新建一个本地写作项目，从主题和大纲开始。"
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background { WBAmbientScenery() }
    .task { await model.reload() }
    .alert("新建写作项目", isPresented: $isCreatePresented) {
      TextField("小说标题", text: $newTitle)
      TextField("作者（可选）", text: $newAuthor)
      Button("创建") {
        let title = newTitle
        let author = newAuthor
        newTitle = ""
        newAuthor = ""
        Task { await model.create(title: title, author: author) }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("项目以 .novelproject 目录包保存在本机。")
    }
    .alert(
      "写作台操作未完成",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("好") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }

  private var projectSidebar: some View {
    VStack(spacing: 0) {
      HStack {
        Text("写作项目")
          .font(.headline)
        Spacer()
        Button {
          isCreatePresented = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
      }
      .padding(14)
      Divider()
      List(model.projects, selection: $model.selectedProjectID) { project in
        VStack(alignment: .leading, spacing: 4) {
          Text(project.manifest.title)
            .lineLimit(1)
          Text(project.manifest.stage.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(Optional(project.id))
      }
      .onChange(of: model.selectedProjectID) { _, id in
        guard let id else { return }
        Task { await model.select(id) }
      }
    }
    .frame(width: 240)
  }

  private func workspace(_ snapshot: WritingProjectSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.manifest.title)
              .font(.system(.largeTitle, design: .serif, weight: .bold))
            Text(snapshot.manifest.stage.displayName)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if model.isWorking { ProgressView() }
        }

        if let notice = model.notice {
          Label(notice, systemImage: "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(Color.wbTeal)
        }

        stageCard(snapshot)
      }
      .padding(28)
      .frame(maxWidth: 980)
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private func stageCard(_ snapshot: WritingProjectSnapshot) -> some View {
    switch snapshot.manifest.stage {
    case .themeDiscussion:
      editorCard(title: "确认主题", subtitle: "模型或人工内容都先作为候选；此处由你明确批准。") {
        TextEditor(text: $model.theme).frame(minHeight: 180)
        suggestionSection(kind: .theme, buttonTitle: "AI 建议主题")
        primaryButton("批准主题") { await model.approveTheme() }
      }
    case .themeApproved:
      editorCard(title: "人物与世界基础", subtitle: "JSON 字段用于稳定身份；世界说明使用 Markdown。") {
        labeledEditor("人物 JSON", text: $model.charactersJSON, height: 120)
        labeledEditor("世界规则", text: $model.world, height: 130)
        labeledEditor("时间线 JSON", text: $model.timelineJSON, height: 100)
        primaryButton("保存基础设定") { await model.saveBible() }
      }
    case .bibleReady:
      editorCard(title: "冻结大纲", subtitle: "冻结前不能正式写章；冻结后仍可通过新提案调整。") {
        TextEditor(text: $model.outline).frame(minHeight: 260)
        suggestionSection(kind: .outline, buttonTitle: "AI 建议大纲")
        primaryButton("批准并冻结大纲") { await model.freezeOutline() }
      }
    case .outlineFrozen, .chapterFinalized, .published:
      editorCard(title: "提交章节草稿", subtitle: "章节 ID 发布后保持稳定。草稿不会直接进入正式书架。") {
        chapterIdentityFields
        labeledEditor("本章意图", text: $model.chapterIntent, height: 80)
        labeledEditor("草稿", text: $model.draft, height: 260)
        primaryButton("批准草稿并进入审稿") { await model.submitDraft() }
        if !snapshot.finalChapters.isEmpty {
          Divider()
          Button("发布全部已定稿章节到书架") {
            Task {
              if await model.publish() { didPublish() }
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.wbTeal)
        }
      }
    case .drafting:
      ProgressView("正在保存草稿候选…")
    case .reviewing:
      editorCard(title: "审稿", subtitle: "记录具体问题，再进入修订。") {
        labeledEditor("已批准草稿", text: $model.draft, height: 180)
          .disabled(true)
        labeledEditor("审稿意见", text: $model.review, height: 180)
        primaryButton("确认审稿意见") { await model.submitReview() }
      }
    case .revising:
      editorCard(title: "修订并定稿", subtitle: "只有点击批准定稿才会更新正式章节、故事状态与伏笔台账。") {
        chapterIdentityFields
        labeledEditor("修订稿", text: $model.revision, height: 260)
        labeledEditor("故事状态 JSON", text: $model.storyStateJSON, height: 100)
        labeledEditor("伏笔 JSON", text: $model.foreshadowingJSON, height: 90)
        primaryButton("批准本章定稿") { await model.approveFinal() }
      }
    }
  }

  private var chapterIdentityFields: some View {
    HStack {
      TextField("章节 ID", text: $model.chapterID)
      TextField("章节标题", text: $model.chapterTitle)
    }
    .textFieldStyle(.roundedBorder)
  }

  private func editorCard<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.title2.bold())
      Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
      content()
    }
    .padding(22)
    .wbGlassPanel(cornerRadius: 20, shadowOpacity: 0.06)
  }

  private func labeledEditor(
    _ label: String,
    text: Binding<String>,
    height: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      TextEditor(text: text).frame(minHeight: height)
    }
  }

  private func suggestionSection(
    kind: WritingSuggestionKind,
    buttonTitle: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button(model.isSuggesting ? "取消" : buttonTitle) {
          if model.isSuggesting {
            model.cancelSuggestion()
          } else {
            Task { await model.suggest(kind) }
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.isWorking)

        if model.isSuggesting {
          ProgressView()
            .controlSize(.small)
        }
      }

      if model.suggestionKind == kind, !model.suggestionText.isEmpty {
        ScrollView {
          Text(model.suggestionText)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 220)
        .background(Color.wbCanvas.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        }

        Button("填入编辑框") {
          model.applySuggestion()
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.wbGold)
        .disabled(model.isWorking || model.isSuggesting)
      }
    }
  }

  private func primaryButton(
    _ title: String,
    action: @escaping @MainActor () async -> Void
  ) -> some View {
    Button(title) { Task { await action() } }
      .buttonStyle(.borderedProminent)
      .disabled(model.isWorking)
  }
}
