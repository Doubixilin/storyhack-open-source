import SwiftUI
import UniformTypeIdentifiers
import VisualMediaCore

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct VisualAssetWorkspaceView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model: VisualAssetViewModel
  @State private var isImporterPresented = false
  let title: String

  init(storyworldID: UUID, title: String) {
    _model = StateObject(wrappedValue: VisualAssetViewModel(storyworldID: storyworldID))
    self.title = title
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          safetyNotice
          bibleEditor
          importCard
          assetGallery
        }
        .padding(24)
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
      }
      .background { WBAmbientScenery() }
      .navigationTitle("\(title) · 视觉资产")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
    }
    .frame(minHeight: 620)
    .task { await model.reload() }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first { Task { await model.importCandidate(from: url) } }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
    }
    .alert(
      "视觉资产操作未完成",
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

  private var safetyNotice: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("本地模式", systemImage: "lock.shield.fill")
        .font(.headline)
      Text("只导入你选择的本地图片，不调用在线生图服务，不产生费用，也不会把图片或世界书内容发送给第三方。")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let notice = model.notice {
        Text(notice).font(.caption).foregroundStyle(Color.wbTeal)
      }
    }
    .padding(18)
    .wbGlassPanel(cornerRadius: 16, shadowOpacity: 0.04)
  }

  private var bibleEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("VisualBible").font(.title2.bold())
      Text("画风、人物不可变外观和地点基准。批准图片不会反向改写这些设定。")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      labeledEditor("画风基准", text: $model.styleGuide, height: 90)
      labeledEditor("人物 JSON", text: $model.charactersJSON, height: 130)
      labeledEditor("地点 JSON", text: $model.locationsJSON, height: 100)
      Button("保存 VisualBible") { Task { await model.saveBible() } }
        .buttonStyle(.borderedProminent)
        .disabled(model.isWorking)
    }
    .padding(20)
    .wbGlassPanel(cornerRadius: 18, shadowOpacity: 0.05)
  }

  private var importCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("导入候选图片").font(.title2.bold())
      labeledEditor("可见事实（每行一条）", text: $model.visibleFacts, height: 70)
      labeledEditor("提示词或图片说明", text: $model.prompt, height: 80)
      HStack {
        TextField("角色/场景 ID，逗号分隔", text: $model.subjectIDs)
        TextField("解锁章节序号（留空立即）", text: $model.spoilerChapter)
          .frame(maxWidth: 210)
      }
      .textFieldStyle(.roundedBorder)
      Button {
        isImporterPresented = true
      } label: {
        Label("选择本地图片", systemImage: "photo.badge.plus")
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isWorking)
    }
    .padding(20)
    .wbGlassPanel(cornerRadius: 18, shadowOpacity: 0.05)
  }

  private var assetGallery: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("候选与批准资产").font(.title2.bold())
      if model.assets.isEmpty {
        Text("尚无图片。导入后会先进入候选区。")
          .foregroundStyle(.secondary)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 14)],
          spacing: 14
        ) {
          ForEach(model.assets) { asset in
            assetCard(asset)
          }
        }
      }
    }
  }

  private func assetCard(_ asset: VisualAssetRecord) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      LocalVisualThumbnail(url: model.fileURL(for: asset))
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      HStack {
        Text(statusText(asset.status)).font(.caption.bold())
        Spacer()
        Text(spoilerText(asset.spoilerBoundary))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Text(asset.cue.prompt).font(.subheadline).lineLimit(3)
      Text(String(asset.fileSHA256.prefix(12)))
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
      if asset.status == .candidate {
        HStack {
          Button("批准") { Task { await model.approve(asset.id) } }
            .buttonStyle(.borderedProminent)
          Button("拒绝", role: .destructive) { Task { await model.reject(asset.id) } }
            .buttonStyle(.bordered)
        }
      }
    }
    .padding(14)
    .wbGlassPanel(cornerRadius: 16, shadowOpacity: 0.04)
  }

  private func labeledEditor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      TextEditor(text: text).frame(minHeight: height)
    }
  }

  private func statusText(_ status: VisualAssetStatus) -> String {
    switch status {
    case .candidate: "候选"
    case .approved: "已批准"
    case .rejected: "已拒绝"
    }
  }

  private func spoilerText(_ boundary: SpoilerBoundary) -> String {
    switch boundary {
    case .immediate: "立即可见"
    case .afterChapter(let ordinal): "第 \(ordinal) 章后"
    case .afterTurn: "指定回合后"
    }
  }
}

private struct LocalVisualThumbnail: View {
  let url: URL

  var body: some View {
    #if os(macOS)
      if let image = NSImage(contentsOf: url) {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        placeholder
      }
    #else
      if let image = UIImage(contentsOfFile: url.path) {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        placeholder
      }
    #endif
  }

  private var placeholder: some View {
    ZStack {
      Color.secondary.opacity(0.1)
      Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
    }
  }
}
