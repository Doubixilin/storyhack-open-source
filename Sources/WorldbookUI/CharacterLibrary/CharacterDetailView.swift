import CharacterLibraryCore
import Foundation
import LLMProviderKit
#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers

struct CharacterDetailView: View {
  @ObservedObject var model: CharacterLibraryViewModel
  @ObservedObject var storyworldModel: StoryworldViewModel
  let profile: CharacterProfile

  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var draft: CharacterProfile
  @State private var tagsText: String
  @State private var categoryText: String
  @State private var isImporterPresented = false
  @State private var isDeleteConfirmationPresented = false
  @State private var isContractCopyPresented = false
#if os(iOS)
  @State private var isPhotosPickerPresented = false
  @State private var selectedPhotoItem: PhotosPickerItem?
#endif

  init(profile: CharacterProfile, model: CharacterLibraryViewModel, storyworldModel: StoryworldViewModel) {
    self.profile = profile
    self.model = model
    self.storyworldModel = storyworldModel
    _draft = State(initialValue: profile)
    _tagsText = State(initialValue: profile.tags.joined(separator: "，"))
    _categoryText = State(initialValue: profile.category ?? "")
  }

  private var assets: [CharacterAsset] {
    model.assetsByCharacter[profile.id] ?? []
  }

  var body: some View {
    ZStack {
      WBAmbientScenery()
      ScrollView {
        if horizontalSizeClass == .compact {
          VStack(alignment: .leading, spacing: 24) {
            imageSection
            editorSection
          }
        } else {
          HStack(alignment: .top, spacing: 30) {
            imageSection
              .frame(width: 340)
            editorSection
              .frame(maxWidth: 720)
          }
        }
      }
      .padding(horizontalSizeClass == .compact ? 18 : 30)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .navigationTitle(draft.name)
    .toolbar {
      ToolbarItem {
        Button("复制角色契约") { isContractCopyPresented = true }
      }
      ToolbarItem(placement: .primaryAction) {
        Button("保存") {
          save()
        }
        .disabled(model.isWorking || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      ToolbarItem {
        Button(role: .destructive) {
          isDeleteConfirmationPresented = true
        } label: {
          Label("删除角色", systemImage: "trash")
        }
      }
    }
    .sheet(isPresented: $isContractCopyPresented) {
      CharacterContractCopySheet(model: storyworldModel, profile: draft)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        Task { await model.importImage(from: url, characterID: profile.id) }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
    }
#if os(iOS)
    .photosPicker(
      isPresented: $isPhotosPickerPresented,
      selection: $selectedPhotoItem,
      matching: .images
    )
    .onChange(of: selectedPhotoItem) { _, item in
      guard let item else { return }
      Task { await importPhoto(item) }
    }
#endif
    .confirmationDialog(
      "删除角色",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        Task {
          await model.deleteCharacter(id: profile.id)
          if model.errorMessage == nil { dismiss() }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将永久删除「\(draft.name)」及其全部图片。")
    }
    .onChange(of: model.characters) { _, characters in
      guard let updated = characters.first(where: { $0.id == profile.id }) else { return }
      // 只跟随主形象变化，避免批准/设主形象触发的刷新覆盖未保存的文本编辑
      draft.portraitAssetID = updated.portraitAssetID
    }
  }

  private var imageSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      // 同海报墙：Color.clear 撑 3:4，图片放 overlay，防止横版图撑破比例
      Color.clear
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay {
          Group {
            if let url = model.portraitURL(for: draft) {
              CharacterLocalImage(url: url)
            } else {
              CharacterPortraitPlaceholder(name: draft.name)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(0.14), radius: 16, y: 8)

#if os(iOS)
      // R26：相册与文件双入口，汇入同一导入管线
      Menu {
        Button {
          isPhotosPickerPresented = true
        } label: {
          Label("从照片选择", systemImage: "photo.on.rectangle")
        }
        Button {
          isImporterPresented = true
        } label: {
          Label("从文件选择", systemImage: "folder")
        }
      } label: {
        Label("导入图片", systemImage: "photo.badge.plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.wbViolet)
      .disabled(model.isWorking)
#else
      Button {
        isImporterPresented = true
      } label: {
        Label("导入图片", systemImage: "photo.badge.plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.wbViolet)
      .disabled(model.isWorking)
#endif

      if !assets.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(assets) { asset in
              assetThumbnail(asset)
            }
          }
          .padding(.vertical, 2)
        }
      } else {
        Text("导入图片后，第一张自动设为头像，之后可手动更换。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func assetThumbnail(_ asset: CharacterAsset) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Group {
        if let url = model.fileURL(for: asset) {
          CharacterLocalImage(url: url)
        } else {
          Color.primary.opacity(0.06)
        }
      }
      .frame(width: 112, height: 140)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(alignment: .topTrailing) {
        Text(statusTitle(asset.status))
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .foregroundStyle(statusForeground(asset.status))
          .background(statusColor(asset.status), in: Capsule())
          .padding(6)
      }

      if asset.status == .candidate {
        // 仅历史遗留候选图需要手动批准；手动导入的新图已自动批准
        HStack(spacing: 6) {
          Button("批准") {
            Task { await model.approveAsset(characterID: profile.id, assetID: asset.id) }
          }
          .buttonStyle(.borderedProminent)
          .tint(.wbViolet)
          Button("拒绝", role: .destructive) {
            Task { await model.rejectAsset(characterID: profile.id, assetID: asset.id) }
          }
          .buttonStyle(.bordered)
        }
        .font(.caption)
        .controlSize(.small)
      } else if asset.status == .approved {
        Button(draft.portraitAssetID == asset.id ? "当前头像" : "设为头像") {
          Task { await model.setPortrait(characterID: profile.id, assetID: asset.id) }
        }
        .font(.caption)
        .buttonStyle(.borderedProminent)
        .tint(.wbViolet)
        .controlSize(.small)
        .disabled(draft.portraitAssetID == asset.id)
      }
    }
    .frame(width: 112)
  }

  private var editorSection: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("角色资料")
        .font(.system(.title2, design: .serif, weight: .bold))

      labeledField("姓名") {
        TextField("角色姓名", text: $draft.name)
          .textFieldStyle(.roundedBorder)
      }
      labeledField("简介") {
        TextField("一句话介绍角色", text: $draft.summary, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...4)
      }
      labeledField("分类") {
        TextField("例如：主角、盟友、反派", text: $categoryText)
          .textFieldStyle(.roundedBorder)
      }
      labeledField("标签") {
        TextField("用逗号分隔", text: $tagsText)
          .textFieldStyle(.roundedBorder)
      }

      multilineField("外貌", text: $draft.fields.appearance)
      multilineField("性格", text: $draft.fields.personality)
      multilineField("语言风格", text: $draft.fields.speechStyle)
      multilineField("背景经历", text: $draft.fields.background)
      multilineField("能力身份", text: $draft.fields.abilities)
      multilineField("备注", text: $draft.fields.notes)
      multilineField("生成提示词", text: $draft.promptProfile, minimumHeight: 150)

      Button {
        save()
      } label: {
        if model.isWorking {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Label("保存角色资料", systemImage: "checkmark.circle.fill")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(.wbViolet)
      .disabled(model.isWorking || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(22)
    .wbGlassPanel(cornerRadius: 20, shadowOpacity: 0.07)
  }

  private func labeledField<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      content()
    }
  }

  private func multilineField(
    _ title: String,
    text: Binding<String>,
    minimumHeight: CGFloat = 105
  ) -> some View {
    labeledField(title) {
      TextEditor(text: text)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: minimumHeight)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
  }

  private func save() {
    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let category = categoryText.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.category = category.isEmpty ? nil : category
    draft.tags = tagsText
      .components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    Task { await model.updateProfile(draft) }
  }

#if os(iOS)
  private func importPhoto(_ item: PhotosPickerItem) async {
    defer { selectedPhotoItem = nil }
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        throw PhotoImportError.unreadableSelection
      }
      let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("worldbook-photo-\(UUID().uuidString)")
        .appendingPathExtension(photoFilenameExtension(for: item))
      try data.write(to: temporaryURL, options: .atomic)
      defer { try? FileManager.default.removeItem(at: temporaryURL) }
      await model.importImage(from: temporaryURL, characterID: profile.id)
    } catch {
      model.errorMessage = ProviderErrorMessage.message(for: error)
    }
  }

  private func photoFilenameExtension(for item: PhotosPickerItem) -> String {
    guard let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }),
          let filenameExtension = contentType.preferredFilenameExtension,
          !filenameExtension.isEmpty
    else { return "jpg" }
    return filenameExtension.lowercased() == "jpeg" ? "jpg" : filenameExtension
  }

  private enum PhotoImportError: LocalizedError {
    case unreadableSelection

    var errorDescription: String? {
      "无法读取所选照片。"
    }
  }
#endif

  private func statusTitle(_ status: CharacterAssetStatus) -> String {
    switch status {
    case .candidate: "候选"
    case .approved: "已批准"
    case .rejected: "已拒绝"
    }
  }

  /// 状态徽章底：金色与青瓷为亮底，配深棕文字；拒绝态用固定暖深灰，
  /// 避免系统 `.secondary` 在深色界面上变成浅灰导致白字不可读。
  private func statusColor(_ status: CharacterAssetStatus) -> Color {
    switch status {
    case .candidate: .wbGold
    case .approved: .wbTeal
    case .rejected: Color(red: 0.32, green: 0.29, blue: 0.26)
    }
  }

  private func statusForeground(_ status: CharacterAssetStatus) -> Color {
    switch status {
    case .candidate, .approved: .wbOnAccent
    case .rejected: .wbInk
    }
  }
}
