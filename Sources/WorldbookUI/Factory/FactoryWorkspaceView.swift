import LibraryCore
import StoryworldFactory
import StoryworldCore
import SwiftUI

struct FactoryWorkspaceView: View {
  let record: NovelLibraryRecord?
  let requestID: UUID?
  @ObservedObject var model: FactoryViewModel
  let enterPublishedStoryworld: (UUID, UUID) -> Void
  @State private var tasteEditing: FactoryTasteEditing?
  @State private var globalTasteEditing: PlayerTasteEditing?

  private var hasUnansweredDecisions: Bool {
    model.selectedJob?.stage == .waitingForUser
      && model.decisions.contains(where: { $0.resolution == .unanswered })
  }

  var body: some View {
    ZStack {
      WBAmbientScenery()
      #if os(iOS)
        compactLayout
      #else
        HStack(spacing: 0) {
          jobSidebar
          Divider()
          detail
        }
      #endif
    }
    .task {
      await model.initialize()
    }
    .sheet(item: $tasteEditing) { editing in
      FactoryTasteEditor(settings: editing.settings) { overrides in
        await model.saveTaste(overrides, replacing: editing.settings)
      }
    }
    .sheet(item: $globalTasteEditing) { editing in
      PlayerTasteEditor(profile: editing.snapshot.profile) { profile in
        await model.saveGlobalTaste(profile, replacing: editing.snapshot)
      }
    }
    .task(id: requestID) {
      if let record, let requestID {
        await model.prepare(record: record, requestID: requestID)
      }
    }
    .confirmationDialog("重新发送可能重复计费",
      isPresented: Binding(get: { model.pendingRetry != nil },
        set: { if !$0 { model.pendingRetry = nil } }),
      titleVisibility: .visible, presenting: model.pendingRetry
    ) { request in
      Button("确认重新发送") { Task { await model.confirmRetry(request) } }
      Button("暂不重发", role: .cancel) { model.pendingRetry = nil }
    } message: { request in
      Text("此任务有 \(request.approval.requestCount) 个请求尚不能确认结果。已完成批次会复用；这些请求可能已被服务商计费，再次发送可能重复扣费。")
    }
    .alert(
      "工坊操作未完成",
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

  private var jobSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("世界书工坊")
          .font(.system(.title2, design: .serif, weight: .bold))
        Text("任务保存在本机，可中断后重试")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(20)

      Divider()
      if model.jobs.isEmpty {
        Text("在书架右键一本小说，选择“生成世界书”。")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(20)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(model.jobs) { job in
              Button {
                Task { await model.select(job.id) }
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Text(job.sourceTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                  HStack {
                    Label(job.stage.displayName, systemImage: job.stage.symbol)
                      .foregroundStyle(job.stage.tint)
                    Spacer()
                    Text("\(Int(job.progress * 100))%")
                      .monospacedDigit()
                  }
                  .font(.caption)
                  ProgressView(value: job.progress)
                    .tint(job.stage.tint)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                      model.selectedJobID == job.id
                        ? Color.wbGold.opacity(0.14) : Color.primary.opacity(0.035))
                }
              }
              .buttonStyle(.plain)
            }
          }
          .padding(12)
        }
      }
    }
    .frame(width: 270)
    .background(.ultraThinMaterial)
  }

  /// iOS 窄屏布局：任务改为顶部横向滑动胶囊列表，下方直接显示任务详情。
  private var compactLayout: some View {
    VStack(spacing: 0) {
      if !model.jobs.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(model.jobs) { job in
              Button {
                Task { await model.select(job.id) }
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text(job.sourceTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  HStack(spacing: 4) {
                    Image(systemName: job.stage.symbol)
                    Text("\(Int(job.progress * 100))%")
                      .monospacedDigit()
                  }
                  .font(.caption2)
                  .foregroundStyle(job.stage.tint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                      model.selectedJobID == job.id
                        ? Color.wbGold.opacity(0.16) : Color.primary.opacity(0.05))
                }
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
        }
        Divider()
      }
      detail
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let job = model.selectedJob {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            header(job)
            statusCard(job)
            tasteSection(job)
            if let coverage = model.coverage {
              coverageSection(coverage)
            }
            if job.stage == .waitingForUser || !model.decisions.isEmpty {
              decisionsSection(job) {
                acceptAllAndRevealActions(proxy)
              }
            }
            if let preview = model.preview {
              previewSection(preview)
            }
            actions(job)
              .id("factory-actions")
          }
          .padding(30)
          .frame(maxWidth: 940)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        #if os(macOS)
          .overlay(alignment: .trailing) {
            if hasUnansweredDecisions {
              Button {
                acceptAllAndRevealActions(proxy)
              } label: {
                Label(
                  "接受全部建议 · \(model.decisions.filter { $0.resolution == .unanswered }.count)",
                  systemImage: "checkmark.seal.fill"
                )
                .padding(.horizontal, 4)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .tint(.wbGold)
              .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
              .padding(.trailing, 24)
              .accessibilityHint("接受后跳到生成候选操作")
            }
          }
        #endif
      }
    } else {
      WBEmptyStateView(
        title: "世界书工坊",
        symbol: "wand.and.sparkles",
        message: Self.emptyStateHint,
        gradient: .wbWarm
      )
    }
  }

  private static var emptyStateHint: String {
    #if os(iOS)
      return "从书架长按一本小说，选择「生成世界书」。工坊执行器只处理该任务的只读章节快照。"
    #else
      return "从书架右键一本小说开始。工坊执行器只处理该任务的只读章节快照。"
    #endif
  }

  private static var runningHint: String {
    #if os(iOS)
      return "处理中，请保持 App 在前台；中断后可从已保存进度继续。"
    #else
      return "后台处理中，可以继续阅读其他小说。"
    #endif
  }

  private func tasteSection(_ job: FactoryJob) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("候选表达偏好").font(.headline)
      if let settings = model.tasteSettings, settings.jobID == job.id, let value = try? settings.effective {
        Text("\(value.pace.label)节奏 · \(value.style.label)文风 · \(value.detail.label)描写 · 强度 \(value.styleIntensity)")
          .font(.subheadline)
        Text(settings.overrides.isEmpty ? "全部沿用默认来源" : "本任务已覆盖部分偏好，未覆盖维度继续沿用默认来源")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("设置本任务偏好…") {
          Task { if let settings = await model.tasteForEditing() { tasteEditing = .init(settings: settings) } }
        }.disabled(model.isBusy || job.stage.isRunning)
        Button("编辑跨书个人默认…") {
          Task { if let snapshot = await model.globalTasteForEditing() { globalTasteEditing = .init(snapshot: snapshot) } }
        }.disabled(model.isBusy)
      }
      Text("个人偏好只调整候选表达，不改变原文分析和人工答案。非默认偏好会在生成时处理候选，每次最多 80 条，未完成部分会显示；模型结果仍需审阅。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func coverageSection(_ coverage: FactoryCoverageSummary) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("分析覆盖")
            .font(.system(.title2, design: .serif, weight: .bold))
          Text("覆盖率是质量提示，不会阻止你使用已有结果。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(coverage.percentage)%")
          .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
          .foregroundStyle(coverage.missingChapters.isEmpty ? Color.wbTeal : Color.wbGold)
      }
      ProgressView(value: coverage.fraction)
        .tint(coverage.missingChapters.isEmpty ? Color.wbTeal : Color.wbGold)
      Text("已覆盖 \(coverage.coveredChapterCount) / \(coverage.totalChapterCount) 章")
        .font(.subheadline.weight(.medium))
      Text("主线摘要完整 \(coverage.plotlineCoverage.completeChapterCount) / \(coverage.plotlineCoverage.sourceChapterCount) 章")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(coverage.plotlineCoverage.gaps.isEmpty ? Color.wbTeal : Color.wbGold)
      if !coverage.plotlineCoverage.gaps.isEmpty {
        Text("缺失或分段不完整：\(coverage.plotlineCoverage.gaps.prefix(5).map(\.chapterTitle).joined(separator: " · "))\(coverage.plotlineCoverage.gaps.count > 5 ? " 等 \(coverage.plotlineCoverage.gaps.count) 章" : "")")
          .font(.caption).foregroundStyle(.secondary)
        Text("继续补全将复用已完成分析，只请求缺失的章节或摘要；可能产生新的模型费用。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !coverage.missingChapters.isEmpty {
        let visible = coverage.missingChapters.prefix(5).map(\.title).joined(separator: " · ")
        Text("尚未覆盖：\(visible)\(coverage.missingChapters.count > 5 ? " 等 \(coverage.missingChapters.count) 章" : "")")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      ForEach(Array(coverage.warnings.prefix(4).enumerated()), id: \.offset) { _, warning in
        Label(warning, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if coverage.warnings.count > 4 {
        Text("另有 \(coverage.warnings.count - 4) 条处理提示")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .wbGlassPanel(
      cornerRadius: 18,
      tint: (coverage.missingChapters.isEmpty ? Color.wbTeal : Color.wbGold).opacity(0.035),
      shadowOpacity: 0.05
    )
  }

  private func header(_ job: FactoryJob) -> some View {
    HStack(alignment: .top, spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(LinearGradient.wbWarm)
        Image(systemName: "wand.and.sparkles")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(Color.wbOnAccent)
      }
      .frame(width: 66, height: 66)
      VStack(alignment: .leading, spacing: 5) {
        Text(job.sourceTitle)
          .font(.system(.largeTitle, design: .serif, weight: .bold))
        Text("\(job.sourceFormat.rawValue.uppercased()) · \(job.sourceName)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private func statusCard(_ job: FactoryJob) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(job.stage.displayName, systemImage: job.stage.symbol)
          .font(.headline)
          .foregroundStyle(job.stage.tint)
        Spacer()
        Text("\(Int(job.progress * 100))%")
          .font(.headline.monospacedDigit())
      }
      ProgressView(value: job.progress)
        .tint(job.stage.tint)
      Text(job.stage.explanation)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let version = job.executorVersion {
        Text("执行器 \(version) · 协议 v\(job.executorProtocolVersion)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      if let failure = job.failure {
        Label(
          failure.message,
          systemImage: failure.retryable ? "arrow.clockwise.circle" : "exclamationmark.triangle"
        )
        .font(.subheadline)
        .foregroundStyle(failure.retryable ? Color.orange : Color.red)
      }
    }
    .padding(20)
    .wbGlassPanel(cornerRadius: 18, tint: job.stage.tint.opacity(0.035), shadowOpacity: 0.05)
  }

  private func decisionsSection(
    _ job: FactoryJob,
    acceptAll: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("需要你确认")
            .font(.system(.title2, design: .serif, weight: .bold))
          Text("这些是内容解释，不会授予后台更多权限。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        #if os(iOS)
          if model.decisions.contains(where: { $0.resolution == .unanswered }) {
            Button("接受全部建议", action: acceptAll)
              .buttonStyle(.borderedProminent)
              .tint(.wbGold)
          }
        #endif
      }
      if model.decisions.isEmpty {
        Text("分析没有发现必须研讨的冲突，可以直接生成候选世界书。")
          .foregroundStyle(.secondary)
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
          .wbGlassPanel(shadowOpacity: 0.03)
      } else {
        ForEach(model.decisions) { decision in
          FactoryDecisionCard(
            decision: decision,
            accept: { Task { await model.accept(decision.id) } },
            submitCustom: { value in Task { await model.answer(decision.id, value: value) } },
            reopen: { Task { await model.reopen(decision.id) } }
          )
          .disabled(model.isBusy)
        }
      }
      if job.stage == .waitingForUser,
        !model.decisions.contains(where: { $0.resolution == .unanswered })
      {
        Label("所有问题均已确认，可以生成候选。", systemImage: "checkmark.seal.fill")
          .foregroundStyle(Color.wbTeal)
      }
    }
  }

  private func acceptAllAndRevealActions(_ proxy: ScrollViewProxy) {
    Task {
      await model.acceptAll()
      withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo("factory-actions", anchor: .center)
      }
    }
  }

  private func previewSection(_ preview: FactoryDiffPreview) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("发布预览")
        .font(.system(.title2, design: .serif, weight: .bold))
      if let fingerprint = preview.candidateFingerprint {
        Text("候选版本 \(fingerprint.prefix(12))")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 22) {
        previewMetric("新增设定", "\(preview.newEntryTitles.count)")
        previewMetric("已确认问题", "\(preview.resolvedDecisionCount)")
        previewMetric("原有关联世界", "\(preview.existingStoryworldCount)")
      }
      Text(preview.newEntryTitles.joined(separator: " · "))
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let validation = model.validation {
        Label(
          "候选包校验通过：\(validation.lorebookEntryCount) 条设定，来源指纹一致",
          systemImage: "checkmark.shield.fill"
        )
        .font(.subheadline)
        .foregroundStyle(Color.wbTeal)
        ForEach(Array(validation.warnings.enumerated()), id: \.offset) { _, warning in
          Label(warning, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("本次候选使用的表达偏好") {
          if let taste = validation.playerTaste {
            VStack(alignment: .leading, spacing: 6) {
              Text("\(taste.pace.label)节奏 · \(taste.style.label)文风 · \(taste.detail.label)描写 · 强度 \(taste.styleIntensity)")
              if !taste.avoidElements.isEmpty { Text("希望避开：" + taste.avoidElements.joined(separator: "、")) }
              if !taste.notes.isEmpty { Text(taste.notes) }
            }.font(.caption).textSelection(.enabled)
          } else { Text("默认表达，未附加个人偏好。") .font(.caption) }
        }
        if let bake = validation.bakeReport, !model.decisions.isEmpty || !bake.targets.isEmpty {
          DisclosureGroup("决策与表达调整对照") {
            VStack(alignment: .leading, spacing: 12) {
              Text("应用范围按条目标题、触发词及同一原文证据匹配。模型返回编号只证明协议齐全，请核对改写是否符合你的决定。")
                .font(.caption).foregroundStyle(.secondary)
              ForEach(model.decisions) { decision in
                let targets = bake.targets.filter { $0.decisionIDs.contains(decision.id) }
                let returned = bake.rewrites.filter { $0.decisionIDs.contains(decision.id) }.count
                Text("\(decision.question) · 已返回 \(returned)/\(targets.count) 条\(bake.unresolvedDecisionIDs.contains(decision.id) ? "，待完整应用" : "，请核对")")
                  .font(.caption)
              }
              ForEach(bake.rewrites, id: \.proposalID) { rewrite in
                if let original = model.analysis?.proposals.first(where: { $0.id == rewrite.proposalID }) {
                  DisclosureGroup(original.title) {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("原候选：\(original.content)").foregroundStyle(.secondary)
                      Text("改写后：\(rewrite.content)")
                    }.font(.caption).textSelection(.enabled)
                  }
                }
              }
              if !bake.isComplete {
                Text("\(bake.retainedCount) 条尚未调整，保留原候选。未完整应用的人工决策另存为待核对条目；表达偏好不会写成世界规则。")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.top, 6)
          }
        }
      }
      Text(preview.updatesExistingWorld != true
        ? "发布会新建一个世界书并关联本小说。"
        : "发布将更新本任务生成的设定并保留旧包备份。游玩线、分支和存档保留，继续游玩前需要确认新设定；已被手工修改的生成内容会停止覆盖。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if preview.legacyUpdate == true {
        Text("这本旧版世界书没有生成内容的版本记录，无法判断其中是否有手工修改。发布会先完整备份，再更新工坊生成的设定；请先导出需单独保留的修改。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .wbGlassPanel(cornerRadius: 18, tint: Color.wbTeal.opacity(0.035), shadowOpacity: 0.05)
  }

  private func previewMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title2.bold().monospacedDigit())
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func actions(_ job: FactoryJob) -> some View {
    HStack {
      switch job.stage {
      case .queued:
        Button {
          Task { await model.start() }
        } label: {
          Label("解析并生成世界书", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.wbGold)
      case .parsing, .indexing, .analyzing, .generating, .validating:
        ProgressView()
        Text(Self.runningHint)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消任务", role: .destructive) { Task { await model.cancel() } }
      case .waitingForUser:
        Button {
          Task { await model.generate() }
        } label: {
          Label("按已确认决策生成候选", systemImage: "doc.badge.gearshape")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.decisions.contains(where: { $0.resolution == .unanswered }))
        Text("相关条目将分块调用模型改写，可能产生费用；完成块可复用。")
          .font(.caption).foregroundStyle(.secondary)
        if model.coverage?.needsSupplement == true {
          Button {
            Task { await model.supplement() }
          } label: {
            Label("继续补全章节与摘要", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
        }
      case .readyToPublish:
        if model.validation?.bakeReport?.isComplete == false {
          Button("继续调整未完成条目") { Task { await model.generate() } }
            .buttonStyle(.bordered)
        }
        if model.coverage?.needsSupplement == true {
          Button("继续补全章节与摘要") { Task { await model.supplement() } }
            .buttonStyle(.bordered)
        }
        Button {
          Task { await model.publish() }
        } label: {
          Label(job.publishedStoryworldID == nil ? "发布并关联到小说" : "更新已发布世界书", systemImage: "checkmark.seal.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.wbTeal)
      case .completed:
        if model.coverage?.needsSupplement == true {
          Button("继续补全章节与摘要") { Task { await model.supplement() } }
            .buttonStyle(.bordered)
        }
        if let storyworldID = job.publishedStoryworldID {
          Button {
            enterPublishedStoryworld(job.documentID, storyworldID)
          } label: {
            Label("进入这个世界", systemImage: "sparkles")
          }
          .buttonStyle(.borderedProminent)
        }
        Button("重新生成候选") { Task { await model.generate() } }
          .buttonStyle(.bordered)
      case .failed, .cancelled:
        let offersIntelligentRepair = job.failure?.category == .model
          || job.failure?.category == .invalidOutput
        Button {
          Task { await model.retry() }
        } label: {
          Label(
            offersIntelligentRepair ? "智能修复并继续" : "从已保存进度重试",
            systemImage: offersIntelligentRepair ? "wand.and.sparkles" : "arrow.clockwise"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(job.failure?.retryable == false)
        if offersIntelligentRepair {
          Text("先执行本地安全修复；仍无法解析时，启动权限受限的模型格式修复会话。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
    .disabled(model.isBusy && !job.stage.isRunning)
  }
}

private struct FactoryDecisionCard: View {
  let decision: FactoryDecision
  let accept: () -> Void
  let submitCustom: (String) -> Void
  let reopen: () -> Void
  @State private var customAnswer = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Text(decision.question)
          .font(.headline)
        Spacer()
        if decision.resolution != .unanswered {
          Label("已确认", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(Color.wbTeal)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("建议").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(decision.recommendation)
      }
      if !decision.rationale.isEmpty {
        Text(decision.rationale)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      if let evidence = decision.evidence.first {
        Text("《\(evidence.chapterTitle)》：\(evidence.excerpt)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      if decision.resolution == .unanswered {
        #if os(iOS)
          VStack(alignment: .leading, spacing: 10) {
            Button("接受建议", action: accept)
              .buttonStyle(.borderedProminent)
            HStack {
              TextField("或输入你的解释", text: $customAnswer)
                .textFieldStyle(.roundedBorder)
              Button("确认") { submitCustom(customAnswer) }
                .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
        #else
          HStack {
            Button("接受建议", action: accept)
              .buttonStyle(.borderedProminent)
            TextField("或输入你的解释", text: $customAnswer)
              .textFieldStyle(.roundedBorder)
            Button("确认自定义答案") { submitCustom(customAnswer) }
              .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        #endif
      } else if let answer = decision.answer {
        HStack(alignment: .firstTextBaseline) {
          Text("确认结果：\(answer)")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.wbTeal)
          Spacer()
          Button("修改", action: reopen)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("撤销确认并重新选择")
        }
      }
    }
    .padding(18)
    .wbGlassPanel(cornerRadius: 16, shadowOpacity: 0.04)
  }
}

extension FactoryStage {
  fileprivate var displayName: String {
    switch self {
    case .queued: "等待开始"
    case .parsing: "校验小说"
    case .indexing: "建立章节索引"
    case .analyzing: "分析全文"
    case .waitingForUser: "等待确认"
    case .generating: "生成候选"
    case .validating: "校验候选"
    case .readyToPublish: "可以发布"
    case .completed: "已发布"
    case .failed: "需要处理"
    case .cancelled: "已取消"
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .queued: "clock"
    case .parsing, .indexing: "text.magnifyingglass"
    case .analyzing: "brain.head.profile"
    case .waitingForUser: "person.crop.circle.badge.questionmark"
    case .generating: "wand.and.sparkles"
    case .validating: "checkmark.shield"
    case .readyToPublish: "shippingbox.fill"
    case .completed: "checkmark.seal.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .cancelled: "xmark.circle"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .completed, .readyToPublish: .wbTeal
    case .failed: .red
    case .cancelled: .secondary
    case .waitingForUser: .wbViolet
    default: .wbGold
    }
  }

  fileprivate var explanation: String {
    switch self {
    case .queued: "小说快照已经锁定，尚未调用模型。"
    case .parsing: "核对书架正文与任务创建时的内容指纹。"
    case .indexing: "复用阅读器章节顺序，准备完整批次。"
    case .analyzing: "工坊执行器正在分析尚未覆盖的章节，并为结论绑定原文位置。"
    case .waitingForUser: "分析已持久保存。可使用当前结果，也可继续补全缺失章节。"
    case .generating: "根据分析和你的确认生成临时 Lorebook。"
    case .validating: "检查来源版本、决策消费、包结构和发布边界。"
    case .readyToPublish: "候选已通过校验，等待你明确发布。"
    case .completed: "世界书已发布并关联到小说。"
    case .failed: "权威进度仍保存在 App 中，可按提示重试。"
    case .cancelled: "后台已停止，已有批次不会重复生成。"
    }
  }
}
