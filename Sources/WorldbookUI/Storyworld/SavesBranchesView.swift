import StoryworldCore
import SwiftUI

struct SavesBranchesView: View {
  @ObservedObject var model: StorySessionViewModel
  var openArchive: ((UUID, UUID) -> Void)? = nil
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var isSaveDialogPresented = false
  @State private var isForkDialogPresented = false
  @State private var saveTitle = ""
  @State private var forkTitle = ""
  @State private var viewMode: ViewMode = .list

  private enum ViewMode: String {
    case list = "列表"
    case graph = "分支图"
  }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    ZStack {
      WBAmbientScenery()
      if let snapshot = model.snapshot {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 14) {
            header(snapshot.context.playthrough.title)
            Picker("显示方式", selection: $viewMode) {
              Text(ViewMode.list.rawValue).tag(ViewMode.list)
              Text(ViewMode.graph.rawValue).tag(ViewMode.graph)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            if let notice = model.recoveryNotice {
              Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, isCompact ? 18 : 32)
          .padding(.top, isCompact ? 18 : 32)
          .padding(.bottom, 14)
          .frame(maxWidth: 900)
          .frame(maxWidth: .infinity)

          if viewMode == .list {
            listContent(snapshot: snapshot)
          } else if let graph = model.branchGraph {
            BranchGraphView(
              graph: graph,
              onActivateBranch: { node in
                Task { await model.activateBranch(node.id) }
              },
              onRestoreSave: { save in
                Task { await model.restoreSaveFromGraph(save) }
              },
              onForkAtEvent: { node, marker, title in
                Task { await model.forkBranchAtEvent(node: node, sequence: marker.sequence, title: title) }
              },
              onSaveAtEvent: { node, marker, title in
                Task { await model.createSaveAtEvent(node: node, sequence: marker.sequence, title: title) }
              }
            )
          } else {
            ProgressView()
              .controlSize(.large)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .task { await model.refreshBranchGraph() }
          }
        }
      } else if model.isArchiveCatalogLoading {
        ProgressView("正在整理全部世界书的存档…")
          .controlSize(.large)
      } else if !model.archiveGroups.isEmpty {
        ScrollView {
          archiveCatalog
            .padding(isCompact ? 18 : 32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
      } else {
        WBEmptyStateView(
          title: "还没有游玩记录",
          symbol: "arrow.triangle.branch",
          message: "先从“世界书”进入一个世界并建立游玩线，之后会按书集中显示在这里。",
          gradient: LinearGradient(
            colors: [.wbTeal, .wbIndigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
      }
    }
    .task { await model.reloadArchiveCatalog() }
    .alert("创建存档", isPresented: $isSaveDialogPresented) {
      TextField("存档名称", text: $saveTitle)
      Button("保存") {
        let title = saveTitle
        saveTitle = ""
        Task { await model.createSave(title: title) }
      }
      Button("取消", role: .cancel) { saveTitle = "" }
    }
    .alert("切出新分支", isPresented: $isForkDialogPresented) {
      TextField("分支名称", text: $forkTitle)
      Button("创建") {
        let title = forkTitle
        forkTitle = ""
        Task { await model.forkCurrentBranch(title: title) }
      }
      Button("取消", role: .cancel) { forkTitle = "" }
    }
    .alert(
      "操作未完成",
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

  private func listContent(snapshot: StorySessionSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        archiveCatalog

        section(title: "分支", symbol: "arrow.triangle.branch") {
          ForEach(model.branches) { branch in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(StoryPlayMode.infer(from: branch)?.displayName ?? branch.branch.title)
                  .font(.headline)
                Text(branch.branch.parentBranchID == nil ? "正史主线" : "从事件 \(branch.branch.forkedAtEventSequence ?? 0) 分叉")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if branch.id == snapshot.context.branch.id {
                Text("当前")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(Color.wbTeal)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 4)
                  .background(Color.wbTeal.opacity(0.12), in: Capsule())
                  .overlay {
                    Capsule()
                      .strokeBorder(Color.wbTeal.opacity(0.45), lineWidth: 1)
                  }
              } else {
                Button("切换") {
                  Task { await model.activateBranch(branch.id) }
                }
                .buttonStyle(WBChipButtonStyle())
              }
            }
            .padding(15)
          }
        }

        section(title: "存档", symbol: "archivebox.fill") {
          if currentPlaythroughSaves.isEmpty {
            Text("这条游玩线还没有手动存档。")
              .foregroundStyle(.secondary)
              .padding(15)
          } else {
            ForEach(currentPlaythroughSaves) { save in
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(save.title)
                    .font(.headline)
                  Text("事件 \(save.eventSequence) · \(save.createdAt.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("从这里建立分支") {
                  Task { await model.restoreSaveFromGraph(save) }
                }
                .buttonStyle(WBChipButtonStyle())
              }
              .padding(15)
            }
          }
        }
      }
      .padding(.horizontal, isCompact ? 18 : 32)
      .padding(.bottom, isCompact ? 18 : 32)
      .frame(maxWidth: 900)
      .frame(maxWidth: .infinity)
    }
  }

  private var currentPlaythroughSaves: [StorySave] {
    let graphSaves = model.branchGraph?.nodes.flatMap { $0.saves.map(\.save) } ?? []
    let values = graphSaves.isEmpty ? (model.snapshot?.saves ?? []) : graphSaves
    return values.sorted { $0.createdAt > $1.createdAt }
  }

  private var archiveCatalog: some View {
    section(title: "按世界书浏览", symbol: "books.vertical.fill") {
      if model.archiveGroups.isEmpty {
        Text("还没有可浏览的游玩线。")
          .foregroundStyle(.secondary)
          .padding(15)
      } else {
        ForEach(model.archiveGroups) { group in
          DisclosureGroup {
            VStack(spacing: 8) {
              ForEach(group.playthroughs) { item in
                Button {
                  if let openArchive {
                    openArchive(group.id, item.playthrough.id)
                  } else {
                    Task {
                      await model.openArchive(
                        storyworldID: group.id,
                        playthroughID: item.playthrough.id
                      )
                    }
                  }
                } label: {
                  HStack {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(item.playthrough.title)
                        .font(.subheadline.weight(.semibold))
                      Text("\(item.branchCount) 个分支 · \(item.saveCount) 个存档")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.storyworldID == group.id,
                      model.snapshot?.context.playthrough.id == item.playthrough.id
                    {
                      Text("当前")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.wbTeal)
                    } else {
                      Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                    }
                  }
                  .contentShape(Rectangle())
                  .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.leading, 8)
            .padding(.vertical, 6)
          } label: {
            HStack {
              Text(group.title)
                .font(.headline)
              Spacer()
              Text("\(group.playthroughs.count) 条游玩线")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(15)
          if group.id != model.archiveGroups.last?.id { Divider() }
        }
      }
    }
  }

  private func header(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("存档与分支")
          .font(.system(isCompact ? .title : .largeTitle, design: .serif, weight: .bold))
        Text(title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 9) {
        Button("保存当前位置") { isSaveDialogPresented = true }
          .buttonStyle(WBChipButtonStyle())
        Button("切出新分支") { isForkDialogPresented = true }
          .buttonStyle(WBChipButtonStyle(isActive: true))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func section<Content: View>(
    title: String,
    symbol: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Label(title, systemImage: symbol)
        .font(.system(.title3, design: .serif, weight: .semibold))
        .padding(17)
      Divider()
      content()
    }
    .wbGlassPanel(cornerRadius: 18, shadowOpacity: 0.06)
  }
}
