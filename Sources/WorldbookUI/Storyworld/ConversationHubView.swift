import LibraryCore
import MediaCore
import SpeechProviderKit
import StorySessionCore
import StoryworldCore
import SwiftUI

enum StoryTurnUserPresentation: Equatable {
  case message(String)
  case systemDirective(String)

  init(userMessage: String) {
    let prefix = "（系统指令："
    guard userMessage.hasPrefix(prefix) else {
      self = .message(userMessage)
      return
    }
    let body = userMessage.dropFirst(prefix.count)
    if body.hasPrefix("导演·"), body.hasSuffix("）") {
      self = .systemDirective(String(body.dropLast()))
    } else {
      self = .systemDirective("系统·开场")
    }
  }
}

struct ConversationHubView: View {
  let novel: NovelLibraryRecord?
  @ObservedObject var storyworldModel: StoryworldViewModel
  @ObservedObject var sessionModel: StorySessionViewModel
  let openProviderSettings: () -> Void
  let openSaves: () -> Void

  var body: some View {
    Group {
      if let selectedID = storyworldModel.selectedStoryworldID,
        sessionModel.storyworldID == selectedID,
        sessionModel.snapshot != nil
      {
        StoryChatView(
          model: sessionModel,
          close: { sessionModel.closeSessionView() },
          openProviderSettings: openProviderSettings,
          openSaves: openSaves
        )
      } else {
        StoryworldOverviewView(
          novel: novel,
          model: storyworldModel,
          startPlay: { storyworldID in
            Task {
              await sessionModel.prepare(storyworldID: storyworldID)
              await sessionModel.openOrCreatePlaythrough()
            }
          }
        )
      }
    }
    .task(id: storyworldModel.selectedStoryworldID) {
      if let selectedID = storyworldModel.selectedStoryworldID {
        await sessionModel.prepare(storyworldID: selectedID)
      }
    }
  }
}

private struct StoryChatView: View {
  @ObservedObject var model: StorySessionViewModel
  let close: () -> Void
  let openProviderSettings: () -> Void
  let openSaves: () -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var isSaveDialogPresented = false
  @State private var isForkDialogPresented = false
  @State private var saveTitle = ""
  @State private var forkTitle = ""
  @State private var selectedChoice: String?
  @State private var followLatest = true
  @StateObject private var speechPlayer = AppleSpeechPlayer()
  private let speechPlanStore = SpeechPlanStore()
  private let speechPlaybackStore = SpeechPlaybackStore()

  /// 游玩排版设置（反馈 #4/#5）：字号、行距全局持久化
  @AppStorage("storyhack.community.play.font_size") private var playFontSize: Double = 16
  @AppStorage("storyhack.community.play.line_spacing") private var playLineSpacing: Double = 5
  @State private var isAppearancePopoverPresented = false
  @State private var isPlaythroughDeletionPresented = false
  @State private var isShortEndingConfirmationPresented = false
  @State private var isEndingReportPresented = false
  @AppStorage("storyhack.community.play.onboarding.dismissed") private var didDismissPlayGuide = false
  @State private var isPlayGuidePresented = false
  @State private var reviewedCanon: CanonBindingStatus?
  @State private var anchorPresentation: StoryAnchorPresentation?
  @State private var anchorJump: StoryAnchorJump?
  @State private var showingContinuity = false
  @State private var directiveEditing: DirectiveProfileEditing?
  @State private var tasteEditing: PlayerTasteEditing?

  var body: some View {
    VStack(spacing: 0) {
      header
      if let status = model.snapshot?.canonStatus, status.requiresConfirmation {
        canonNotice(status)
      }
      if let notice = model.storyworld?.plotline?.coverage?.notice {
        Label(notice, systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 20).padding(.vertical, 7)
      }
      HStack {
        Button { anchorPresentation = .list } label: {
          Label("记忆锚点 · \(model.snapshot?.anchorState.anchors.count ?? 0)", systemImage: "bookmark")
        }
        .buttonStyle(.plain)
        .font(.caption)
        if model.snapshot?.anchorState.notice != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
        Spacer()
        Button { showingContinuity = true } label: {
          Label("连续性", systemImage: "list.bullet.clipboard")
        }.buttonStyle(.plain).font(.caption)
      }.padding(.horizontal, 20).padding(.vertical, 7)
      Divider()
      transcript
      Divider()
      composer
    }
    .background { WBAmbientScenery() }
    .task(id: model.snapshot?.context.playthrough.id) {
      await model.refreshCanonStatus()
      await model.reloadDirectiveProfiles()
    }
    .sheet(item: $tasteEditing) { context in
      PlayerTasteEditor(profile: context.snapshot.profile) { profile in
        await model.savePlayerTaste(profile, replacing: context.snapshot)
      }
    }
    .sheet(item: $directiveEditing) { context in
      DirectiveProfileEditor(context: context, save: { profile in
        if let error = await model.saveDirectiveProfile(profile, replacing: context.previous) { return error }
        return await model.applyDirectiveProfile(profile, address: context.address, revision: context.revision)
      }, remove: {
        guard let previous = context.previous else { return nil }
        return await model.deleteDirectiveProfile(previous)
      })
    }
    .sheet(item: $anchorPresentation) { presentation in
      switch presentation {
      case .list:
        if let snapshot = model.snapshot {
          StoryAnchorPanel(snapshot: snapshot, edit: { anchor in
            anchorPresentation = .edit(.init(anchor: anchor, address: snapshot.context.address,
              revision: snapshot.anchorState.revision, isExisting: true))
          }, jump: { ref in
            followLatest = false
            anchorPresentation = nil
            anchorJump = StoryAnchorJump(ref: ref)
          })
        }
      case .edit(let context):
        StoryAnchorEditor(context: context, save: { anchor in
          await model.saveAnchor(anchor, address: context.address, revision: context.revision)
        }, remove: {
          await model.removeAnchor(id: context.anchor.id, address: context.address, revision: context.revision)
        })
      }
    }
    .sheet(isPresented: $showingContinuity) {
      if let snapshot = model.snapshot {
        ContinuityPanel(snapshot: snapshot, propose: model.proposeCalibration,
          decide: model.decideCalibration) { ref in
          followLatest = false
          showingContinuity = false
          anchorJump = .init(ref: ref)
        }
      }
    }
    .confirmationDialog("确认使用当前世界设定", isPresented: Binding(
      get: { reviewedCanon != nil }, set: { if !$0 { reviewedCanon = nil } }
    ), titleVisibility: .visible) {
      if let status = reviewedCanon {
        Button("确认绑定") {
          reviewedCanon = nil
          Task { await model.confirmCanonBinding(status) }
        }
      }
      Button("取消", role: .cancel) { reviewedCanon = nil }
    } message: {
      Text("本条游玩线的所有分支将在后续使用当前设定。既有事件与存档保持原样；绑定记录只保存指纹，不能恢复旧版设定文件。")
    }
    .overlay(alignment: .bottomTrailing) {
      if isPlayGuidePresented {
        playGuideCard
          .padding(.trailing, horizontalSizeClass == .compact ? 12 : 24)
          .padding(.bottom, horizontalSizeClass == .compact ? 172 : 152)
          .transition(.move(edge: .trailing).combined(with: .opacity))
          .zIndex(20)
      }
    }
    .confirmationDialog(
      "删除当前游玩线",
      isPresented: $isPlaythroughDeletionPresented,
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        if let id = model.snapshot?.context.playthrough.id {
          Task { await model.deletePlaythrough(id) }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将删除这条游玩线的全部分支、事件与存档，且不可恢复。")
    }
    .alert("创建存档", isPresented: $isSaveDialogPresented) {
      TextField("存档名称", text: $saveTitle)
      Button("保存") {
        let title = saveTitle
        saveTitle = ""
        Task { await model.createSave(title: title) }
      }
      Button("取消", role: .cancel) { saveTitle = "" }
    } message: {
      Text("保存当前状态和事件位置。")
    }
    .alert("剧情尚短", isPresented: $isShortEndingConfirmationPresented) {
      Button("仍要完结") { isEndingReportPresented = true }
      Button("再走一程", role: .cancel) {}
    } message: {
      Text("剧情尚短，判词与统计会缺少素材，仍要完结吗？")
    }
    .sheet(isPresented: $isEndingReportPresented) {
      EndingReportView(model: model) { isEndingReportPresented = false }
    }
    .alert("切出新分支", isPresented: $isForkDialogPresented) {
      TextField("分支名称", text: $forkTitle)
      Button("创建") {
        let title = forkTitle
        forkTitle = ""
        Task { await model.forkCurrentBranch(title: title) }
      }
      Button("取消", role: .cancel) { forkTitle = "" }
    } message: {
      Text("新分支从当前状态开始，拥有独立会话和后续事件。")
    }
    .alert(
      "本轮未提交",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      if model.canRetry {
        Button("重试同一轮") { model.retryLastTurn() }
      }
      Button("好") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
    .onChange(of: model.latestChoices) { _, _ in
      selectedChoice = nil
    }
    .onChange(of: speechPlayer.location) { _, location in
      guard let location else { return }
      Task { try? await speechPlaybackStore.save(location) }
    }
    .onDisappear { speechPlayer.stop() }
    .onAppear {
      if !didDismissPlayGuide,
        model.snapshot?.effectiveTurns.count ?? 0 <= 1,
        model.snapshot?.saves.isEmpty != false
      {
        isPlayGuidePresented = true
      }
    }
  }

  private var header: some View {
    Group {
      if horizontalSizeClass == .compact {
        compactHeader
      } else {
        wideHeader
      }
    }
  }

  private var wideHeader: some View {
    HStack(spacing: 12) {
      Button(action: close) {
        Label("世界书", systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)

      VStack(alignment: .leading, spacing: 2) {
        Text(model.storyworld?.manifest.title ?? "故事世界")
          .font(.system(.title3, design: .serif, weight: .bold))
        if let snapshot = model.snapshot {
          Text("\(snapshot.context.playthrough.title) · \(model.currentBranchDisplayTitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if model.providerProfiles.isEmpty {
        Button("添加模型", action: openProviderSettings)
          .buttonStyle(.borderedProminent)
      } else {
        Picker("模型", selection: $model.selectedProviderID) {
          ForEach(model.providerProfiles) { profile in
            Text(profile.displayName).tag(Optional(profile.id))
          }
        }
        .frame(maxWidth: 210)
      }

      playthroughMenu {
        Label("游玩线", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
      }

      branchMenu {
        Label("分支", systemImage: "arrow.triangle.branch")
      }

      saveMenu {
        Label("存档", systemImage: "archivebox")
      }

      Button(action: finishLife) {
        Label("完结此生", systemImage: "scroll")
      }
      .buttonStyle(.borderless)
      .disabled(model.isStreaming)

      Button {
        isAppearancePopoverPresented.toggle()
      } label: {
        Image(systemName: "textformat.size")
      }
      .buttonStyle(.borderless)
      .popover(isPresented: $isAppearancePopoverPresented) { appearancePanel }
      .accessibilityLabel("游玩显示设置")

      Button {
        withAnimation(WBMotion.snappy) { isPlayGuidePresented = true }
      } label: {
        Image(systemName: "questionmark.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("玩法说明")
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 14)
  }

  /// 游玩排版面板：字号 + 行距（反馈 #4）
  private var appearancePanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Stepper(value: $playFontSize, in: 13...24, step: 1) {
        Text("字号 \(Int(playFontSize))")
      }
      Picker("行距", selection: $playLineSpacing) {
        Text("紧凑").tag(2.0)
        Text("标准").tag(5.0)
        Text("宽松").tag(8.0)
      }
      .pickerStyle(.segmented)
    }
    .padding(14)
    .frame(width: 240)
  }

  private var compactHeader: some View {
    HStack(spacing: 8) {
      Button(action: close) {
        Image(systemName: "chevron.left")
          .font(.subheadline.weight(.semibold))
          .frame(width: 30, height: 30)
          .background(Color.primary.opacity(0.05), in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("返回世界列表")

      VStack(alignment: .leading, spacing: 2) {
        Text(model.storyworld?.manifest.title ?? "故事世界")
          .font(.system(.headline, design: .serif, weight: .bold))
          .lineLimit(1)
          .truncationMode(.middle)
        if let snapshot = model.snapshot {
          Text(
            [
              snapshot.context.playthrough.title,
              model.currentBranchDisplayTitle,
              model.currentPlotNodeTitle,
            ].compactMap { $0 }.joined(separator: " · ")
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }

      Spacer(minLength: 6)

      compactModelControl

      Button {
        isAppearancePopoverPresented.toggle()
      } label: {
        Image(systemName: "textformat.size")
          .font(.subheadline.weight(.medium))
          .frame(width: 30, height: 30)
          .background(Color.primary.opacity(0.05), in: Circle())
      }
      .buttonStyle(.plain)
      .popover(isPresented: $isAppearancePopoverPresented) { appearancePanel }
      .accessibilityLabel("游玩显示设置")

      Menu {
        Button("记忆锚点") { anchorPresentation = .list }
        historyWindowMenu
        directiveMenu
        Section("游玩线") {
          Button("新建游玩线") {
            Task { await model.createPlaythrough(title: "新的游玩线") }
          }
          ForEach(model.playthroughs) { playthrough in
            Button(playthrough.title) {
              Task { await model.openPlaythrough(playthrough.id) }
            }
          }
          Button("删除当前游玩线…", role: .destructive) {
            isPlaythroughDeletionPresented = true
          }
        }
        Section("分支") {
          ForEach(model.branches) { branch in
            Button(branch.branch.title) {
              Task { await model.activateBranch(branch.id) }
            }
          }
          Button("从当前位置切出新分支") { isForkDialogPresented = true }
        }
        Section("存档") {
          Button("保存当前位置") { isSaveDialogPresented = true }
          ForEach(model.snapshot?.saves ?? []) { save in
            Button("从“\(save.title)”继续") {
              Task { await model.restoreSave(save.id, title: "从 \(save.title) 继续") }
            }
          }
          Button("管理存档与分支…", action: openSaves)
        }
        Section("结局") {
          Button("完结此生", action: finishLife)
        }
        Section("帮助") {
          Button("玩法说明") {
            withAnimation(WBMotion.snappy) { isPlayGuidePresented = true }
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.subheadline.weight(.medium))
          .frame(width: 30, height: 30)
          .background(Color.primary.opacity(0.05), in: Circle())
      }
      .disabled(model.isStreaming)
      .accessibilityLabel("游玩线、分支与存档")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  /// 模型切换胶囊：显示当前模型，点按弹出切换菜单
  @ViewBuilder
  private var compactModelControl: some View {
    if model.providerProfiles.isEmpty {
      Button("添加模型", action: openProviderSettings)
        .buttonStyle(WBChipButtonStyle(isActive: true))
    } else {
      Menu {
        ForEach(model.providerProfiles) { profile in
          Button {
            model.selectedProviderID = profile.id
          } label: {
            if profile.id == model.selectedProviderID {
              Label(profile.displayName, systemImage: "checkmark")
            } else {
              Text(profile.displayName)
            }
          }
        }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "sparkles")
            .font(.caption2)
          Text(currentProviderName)
            .lineLimit(1)
            .frame(maxWidth: 120)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(WBChipButtonStyle(isActive: true))
      .disabled(model.isStreaming)
      .accessibilityLabel("切换模型，当前为 \(currentProviderName)")
    }
  }

  private var currentProviderName: String {
    model.providerProfiles.first { $0.id == model.selectedProviderID }?.displayName ?? "选择模型"
  }

  private func finishLife() {
    if model.endingReadiness.requiresConfirmation {
      isShortEndingConfirmationPresented = true
    } else {
      isEndingReportPresented = true
    }
  }

  private var playGuideCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("三步开始游玩", systemImage: "sparkles")
          .font(.headline)
        Spacer()
        Button {
          withAnimation(WBMotion.snappy) { isPlayGuidePresented = false }
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭玩法说明")
      }
      Text("1. 点一个行动选项，或自己输入想做的事\n2. 正史跟随原著；God Mode 保证行动成功；邪神线可改写世界\n3. 随时存档，并从任意存档切出新分支")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("查看存档与分支", action: openSaves)
          .buttonStyle(.bordered)
        Spacer()
        Button("不再显示") {
          didDismissPlayGuide = true
          withAnimation(WBMotion.snappy) { isPlayGuidePresented = false }
        }
        .buttonStyle(.borderless)
      }
      .font(.caption)
    }
    .padding(15)
    .frame(width: horizontalSizeClass == .compact ? 310 : 360)
    .wbGlassPanel(cornerRadius: 16, tint: Color.wbGold.opacity(0.05), shadowOpacity: 0.16)
  }

  private func playthroughMenu<Label: View>(
    @ViewBuilder label: () -> Label
  ) -> some View {
    Menu {
      historyWindowMenu
      directiveMenu
      Button("新建游玩线") {
        Task { await model.createPlaythrough(title: "新的游玩线") }
      }
      if !model.playthroughs.isEmpty {
        Divider()
        ForEach(model.playthroughs) { playthrough in
          Button(playthrough.title) {
            Task { await model.openPlaythrough(playthrough.id) }
          }
        }
        Divider()
        Button("删除当前游玩线…", role: .destructive) {
          isPlaythroughDeletionPresented = true
        }
      }
    } label: { label() }
      .disabled(model.isStreaming)
  }

  private func canonNotice(_ status: CanonBindingStatus) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(status.notice).font(.callout)
      HStack {
        if status.canRebind {
          Button(status.state == .legacyUnbound ? "确认当前设定" : "查看并确认变更") {
            reviewedCanon = status
          }
        }
        Button("刷新") { Task { await model.refreshCanonStatus() } }
        Button("使用当前设定新开游玩线") {
          Task { await model.createPlaythrough(title: "新设定游玩线") }
        }
        .disabled(status.current == nil)
      }
      .buttonStyle(.bordered)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.wbGold.opacity(0.12))
    .disabled(model.isStreaming)
  }

  private var historyWindowMenu: some View {
    Menu("近期原文：\(model.snapshot?.context.playthrough.effectiveHistoryWindow ?? 20) 回合") {
      ForEach([2, 6, 10, 20, 40, 80, 200], id: \.self) { count in
        Button("最近 \(count) 回合") {
          Task { await model.setHistoryWindow(count) }
        }
      }
      Text("实际保留数量受模型窗口限制，摘要刷新不会清空近期原文。")
    }
    .disabled(model.snapshot == nil || model.isStreaming)
  }

  private var directiveMenu: some View {
    Menu("叙事档案：\(model.snapshot?.context.playthrough.effectiveDirective.name ?? "标准叙事")") {
      ForEach(model.directiveProfiles) { profile in
        Button(profile.name) {
          guard let snapshot = model.snapshot else { return }
          Task {
            model.errorMessage = await model.applyDirectiveProfile(profile,
              address: snapshot.context.address, revision: snapshot.context.playthrough.directive?.revision)
          }
        }
      }
      Divider()
      Button("基于当前档案创建副本…") {
        guard let snapshot = model.snapshot else { return }
        var profile = snapshot.context.playthrough.effectiveDirective
        profile.id = "custom." + UUID().uuidString.lowercased()
        profile.name = "自定义叙事"
        directiveEditing = .init(profile: profile, previous: nil, address: snapshot.context.address,
          revision: snapshot.context.playthrough.directive?.revision)
      }
      Menu("编辑公共档案") {
        ForEach(model.directiveProfiles.filter { !$0.isBuiltin }) { profile in
          Button(profile.name) {
            guard let snapshot = model.snapshot else { return }
            directiveEditing = .init(profile: profile, previous: profile, address: snapshot.context.address,
              revision: snapshot.context.playthrough.directive?.revision)
          }
        }
      }
      Menu("用档案新建游玩线") {
        ForEach(model.directiveProfiles) { profile in
          Button(profile.name) { Task { await model.createPlaythrough(title: "新的游玩线", directiveProfile: profile) } }
        }
      }
      Text("公共档案修改后，已有游玩线需重新选择才会应用。")
      Divider()
      Button("个人叙事偏好（跨书共用）…") {
        Task {
          if let snapshot = await model.playerTasteForEditing() { tasteEditing = .init(snapshot: snapshot) }
        }
      }
    }
    .disabled(model.snapshot == nil || model.isStreaming)
  }

  private func branchMenu<Label: View>(
    @ViewBuilder label: () -> Label
  ) -> some View {
    Menu {
      ForEach(model.branches) { branch in
        Button(branch.branch.title) {
          Task { await model.activateBranch(branch.id) }
        }
      }
      Divider()
      Button("从当前位置切出新分支") { isForkDialogPresented = true }
    } label: { label() }
      .disabled(model.isStreaming)
  }

  private func saveMenu<Label: View>(
    @ViewBuilder label: () -> Label
  ) -> some View {
    Menu {
      Button("保存当前位置") { isSaveDialogPresented = true }
      if let saves = model.snapshot?.saves, !saves.isEmpty {
        Divider()
        ForEach(saves) { save in
          Button("从“\(save.title)”建立新分支") {
            Task { await model.restoreSave(save.id, title: "从 \(save.title) 继续") }
          }
        }
      }
      Divider()
      Button("管理存档与分支…", action: openSaves)
    } label: { label() }
      .disabled(model.isStreaming)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      transcriptScrollView(proxy: proxy)
    }
  }

  @ViewBuilder
  private func transcriptScrollView(proxy: ScrollViewProxy) -> some View {
    if #available(iOS 18.0, macOS 15.0, *) {
      transcriptContent(proxy: proxy)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
          return geometry.contentSize.height - visibleBottom < 80
        } action: { _, isAtBottom in
          followLatest = isAtBottom
        }
        .overlay(alignment: .bottomTrailing) {
          if !followLatest {
            Button {
              followLatest = true
              proxy.scrollTo("bottom", anchor: .bottom)
            } label: {
              Label("回到最新", systemImage: "arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(16)
          }
        }
    } else {
      transcriptContent(proxy: proxy)
    }
  }

  private func transcriptContent(proxy: ScrollViewProxy) -> some View {
    ScrollView {
      LazyVStack(spacing: 18) {
        if model.snapshot?.effectiveTurns.isEmpty != false {
          VStack(spacing: 10) {
            Image(systemName: "sparkles")
              .font(.largeTitle)
              .foregroundStyle(Color.wbViolet)
            Text("世界已经准备好")
              .font(.system(.title2, design: .serif, weight: .bold))
            Text("写下你的第一个行动。只有格式和状态校验通过的回复才会进入事件日志。")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .padding(.vertical, 70)
        }

        ForEach(model.snapshot?.effectiveTurns ?? []) { turn in
          switch StoryTurnUserPresentation(userMessage: turn.userMessage) {
          case .message(let message):
            messageBubble(message, isUser: true)
          case .systemDirective(let label):
            systemDirectiveStrip(label)
          }
          committedBubble(turn)
        }
        if let pendingUserMessage = model.pendingUserMessage {
          messageBubble(pendingUserMessage, isUser: true)
        }
        if model.isStreaming {
          messageBubble(
            model.streamingNarrative.isEmpty ? "正在构建场景…" : model.streamingNarrative,
            isUser: false,
            isStreaming: true
          )
          .id("streaming")
        }
        Color.clear.frame(height: 1).id("bottom")
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 26)
      .frame(maxWidth: 1280)
      .frame(maxWidth: .infinity)
    }
    .onChange(of: anchorJump) { _, jump in
      if let jump { proxy.scrollTo(jump.ref.scrollID, anchor: .top) }
    }
    .onChange(of: model.pendingUserMessage) { _, pendingUserMessage in
      guard pendingUserMessage != nil else { return }
      followLatest = true
      proxy.scrollTo("bottom", anchor: .bottom)
    }
    .onChange(of: model.streamingNarrative) { _, _ in
      guard shouldFollowLatest else { return }
      // 流式期间高频触发：不要 withAnimation，动画事务叠加滚动锚定
      // 在 macOS 26 上会把主线程拖进布局失效循环（见 2026-08-14 反馈 #9）
      proxy.scrollTo("bottom", anchor: .bottom)
    }
    .onChange(of: model.snapshot?.effectiveTurns.count) { _, _ in
      guard shouldFollowLatest else { return }
      proxy.scrollTo("bottom", anchor: .bottom)
    }
  }

  private func editAnchor(for turn: CommittedStoryTurn) {
    guard let snapshot = model.snapshot else { return }
    let ref = StoryAnchorEventRef(turn)
    let existing = snapshot.anchorState.anchors.first { $0.eventRef == ref }
    let anchor = existing ?? StoryAnchor(eventRef: ref,
      label: String(turn.narrative.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)))
    anchorPresentation = .edit(.init(anchor: anchor, address: snapshot.context.address,
      revision: snapshot.anchorState.revision, isExisting: existing != nil))
  }

  private func committedBubble(_ turn: CommittedStoryTurn) -> some View {
    let ref = StoryAnchorEventRef(turn)
    let anchor = model.snapshot?.anchorState.anchors.first { $0.eventRef == ref }
    return VStack(alignment: .leading, spacing: 2) {
      messageBubble(turn.narrative, isUser: false,
        speechPlan: SpeechPlanBuilder.singleNarrator(kind: .committedTurn,
          sourceID: turn.id.uuidString.lowercased(), text: turn.narrative))
      Button { editAnchor(for: turn) } label: {
        Label(anchor.map { $0.enabled ? "锚点：" + $0.label : "锚点已停用：" + $0.label } ?? "标记锚点",
          systemImage: anchor == nil ? "bookmark" : "bookmark.fill")
          .lineLimit(1)
      }
      .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
      .padding(.leading, 16)
    }
    .id(ref.scrollID)
    .contextMenu {
      Button("复制本轮正文") { StoryAnchorClipboard.copy(turn.narrative) }
      Button(anchor == nil ? "标记锚点" : "编辑锚点") { editAnchor(for: turn) }
    }
    .accessibilityAction(named: Text("管理本轮锚点")) { editAnchor(for: turn) }
  }

  private func systemDirectiveStrip(_ label: String) -> some View {
    HStack {
      Spacer()
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: Capsule())
      Spacer()
    }
    .accessibilityLabel("系统指令：\(label)")
  }

  private var shouldFollowLatest: Bool {
    if #available(iOS 18.0, macOS 15.0, *) {
      followLatest
    } else {
      true
    }
  }

  private func messageBubble(
    _ text: String,
    isUser: Bool,
    isStreaming: Bool = false,
    speechPlan: SpeechPlan? = nil
  ) -> some View {
    HStack {
      if isUser { Spacer(minLength: horizontalSizeClass == .compact ? 44 : 100) }
      VStack(alignment: .leading, spacing: 7) {
        if isStreaming {
          ProgressView()
            .controlSize(.small)
        }
        Text(normalizedNarrative(text))
          .font(
            isUser
              ? .system(size: playFontSize)
              : .system(size: playFontSize, design: .serif)
          )
          .lineSpacing(playLineSpacing)
          .textSelection(.enabled)
        if let speechPlan {
          Button {
            toggleSpeech(speechPlan)
          } label: {
            Label(
              speechPlayer.currentPlanID == speechPlan.id && speechPlayer.state == .playing
                ? "暂停"
                : "朗读本轮",
              systemImage: speechPlayer.currentPlanID == speechPlan.id
                && speechPlayer.state == .playing
                ? "pause.fill"
                : "speaker.wave.2"
            )
          }
          .buttonStyle(.borderless)
          .font(.caption)
          .foregroundStyle(Color.wbAccent)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .foregroundStyle(isUser ? Color.wbUserBubbleText : Color.wbInk)
      .background {
        if isUser {
          UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 5,
            topTrailingRadius: 18
          )
          .fill(Color.wbUserBubble)
          .overlay {
            UnevenRoundedRectangle(
              topLeadingRadius: 18,
              bottomLeadingRadius: 18,
              bottomTrailingRadius: 5,
              topTrailingRadius: 18
            )
            .strokeBorder(Color.wbGold.opacity(0.12), lineWidth: 1)
          }
        }
        // 叙事消息去框：透明底，宋体正文直接铺在页面背景上
      }
      if !isUser { Spacer(minLength: horizontalSizeClass == .compact ? 44 : 100) }
    }
    .transition(.opacity.combined(with: .offset(y: 10)))
  }

  private func toggleSpeech(_ plan: SpeechPlan) {
    Task {
      try? await speechPlanStore.save(plan)
      let saved = try? await speechPlaybackStore.load(
        sourceID: plan.source.sourceID,
        contentHash: plan.source.contentHash
      )
      speechPlayer.toggle(plan: plan, from: saved)
    }
  }

  /// 反馈 #5：模型输出常在段落间带空行，与 UI 行距叠加后段距过大。
  /// 把连续换行折叠成单换行，段距由行距设置统一控制（保持单个 Text，
  /// 避免拆成多段后每个段落都挂一个文本选择层）。
  private func normalizedNarrative(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\n[ \t]*\n+"#,
      with: "\n",
      options: .regularExpression
    )
  }

  private var quickActionButtons: some View {
    // R25：模式收进菜单，底部只留三个入口
    HStack(spacing: 8) {
      Menu {
        Text("自动推进一段；篇幅受模型输出上限约束")
        ForEach([600, 1_200, 2_400], id: \.self) { count in
          Button("自动推进 · 约 \(count) 字") {
            model.sendDirective("自动推进", prompt: StoryAdvancePlan(targetCharacters: count).prompt)
          }
        }
      } label: {
        Label("继续", systemImage: "play.fill")
      } primaryAction: {
        model.sendDirective("继续", prompt: "继续")
      }
      .buttonStyle(WBChipButtonStyle())
      .disabled(model.isStreaming)

      Button {
        Task { await model.createQuickSave() }
      } label: {
        Label("存档", systemImage: "archivebox")
      }
      .buttonStyle(WBChipButtonStyle())
      .disabled(model.isStreaming)

      Menu {
        ForEach(StoryPlayMode.allCases) { mode in
          Button {
            Task { await model.activatePlayMode(mode) }
          } label: {
            if model.currentPlayMode == mode {
              Label(mode.displayName, systemImage: "checkmark")
            } else {
              Text(mode.displayName)
            }
          }
          .disabled(model.currentPlayMode == mode)
        }
      } label: {
        Label(
          "模式·\(model.currentPlayMode?.displayName ?? "正史")",
          systemImage: "arrow.triangle.branch"
        )
      }
      .buttonStyle(WBChipButtonStyle())
      .disabled(model.isStreaming)
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let notice = model.recoveryNotice {
        Label(notice, systemImage: "checkmark.shield")
          .font(.caption)
          .foregroundStyle(Color.wbGold)
          .padding(.horizontal, 2)
      }

      if !model.latestChoices.isEmpty, !model.isStreaming {
        // R25：两步确认防止轻点误发
        VStack(alignment: .leading, spacing: 8) {
          ScrollView {
            VStack(spacing: 8) {
              ForEach(Array(model.latestChoices.enumerated()), id: \.offset) { index, choice in
                let isSelected = selectedChoice == choice
                Button {
                  selectedChoice = isSelected ? nil : choice
                } label: {
                  HStack(alignment: .top, spacing: 8) {
                    Text(index == 0 ? "原著" : (index == 1 ? "创新" : "行动"))
                      .font(.caption.weight(.bold))
                      .foregroundStyle(Color.wbGold)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 3)
                      .background(Color.wbGold.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    Text(choice)
                      .font(.body)
                      .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isSelected {
                      Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.wbGold)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(12)
                }
                .buttonStyle(.plain)
                .background(
                  Color.wbGold.opacity(isSelected ? 0.14 : 0.06),
                  in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                      Color.wbGold.opacity(isSelected ? 0.75 : 0.22),
                      lineWidth: isSelected ? 2 : 1
                    )
                }
                .accessibilityLabel("选择行动：\(choice)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
              }
            }
          }
          .frame(maxHeight: 360)

          Button {
            guard let choice = selectedChoice else { return }
            model.sendShortcut(choice)
            selectedChoice = nil
          } label: {
            Label("确认选择", systemImage: "checkmark.circle.fill")
          }
          .buttonStyle(WBChipButtonStyle(isActive: true))
          .disabled(selectedChoice == nil)
        }
      }

      quickActionButtons

      HStack(alignment: .bottom, spacing: 12) {
        TextField("你准备做什么？", text: $model.draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .padding(.horizontal, 15)
          .padding(.vertical, 12)
          .wbGlassPanel(cornerRadius: 15, shadowOpacity: 0.04)
          .onSubmit {
            if !model.isStreaming { model.sendDraft() }
          }

        if model.isStreaming {
          Button(role: .destructive) {
            model.cancelStreaming()
          } label: {
            Image(systemName: "stop.fill")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(Color(red: 0.949, green: 0.867, blue: 0.851))
              .frame(width: 36, height: 36)
              .background {
                Circle()
                  .fill(Color(red: 0.427, green: 0.224, blue: 0.208))
                  .shadow(color: Color(red: 0.427, green: 0.224, blue: 0.208).opacity(0.4), radius: 6, y: 3)
              }
          }
          .buttonStyle(WBPressableButtonStyle(pressedScale: 0.88))
          .accessibilityLabel("停止生成")
        } else {
          Button {
            model.sendDraft()
          } label: {
            Image(systemName: "arrow.up")
          }
          .buttonStyle(
            WBGradientCircleButtonStyle(
              isEnabled: !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          )
          .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityLabel("发送")
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .frame(maxWidth: 1280)
    .frame(maxWidth: .infinity)
  }
}
