import CharacterLibraryCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct CharacterLibraryWallView: View {
  @ObservedObject var model: CharacterLibraryViewModel
  @ObservedObject var storyworldModel: StoryworldViewModel
  @State private var isCreatingCharacter = false
  @State private var isExtractSheetPresented = false
  @State private var newCharacterName = ""
  @State private var deletionCandidate: CharacterProfile?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var columns: [GridItem] {
    let compact = horizontalSizeClass == .compact
    return [
      GridItem(
        .adaptive(
          minimum: compact ? 108 : 200,
          maximum: compact ? 156 : 240
        ),
        spacing: compact ? 12 : 20
      )
    ]
  }

  var body: some View {
    NavigationStack {
      ZStack {
        WBAmbientScenery()
        VStack(spacing: 0) {
          toolbar
          if model.characters.isEmpty && !model.isWorking {
            emptyState
          } else if model.filteredCharacters.isEmpty {
            WBEmptyStateView(
              title: "没有匹配的角色",
              symbol: "person.crop.circle.badge.questionmark",
              message: "调整搜索词、分类或标签筛选后再试。"
            )
          } else {
            posterGrid
          }
        }
        if model.isWorking && model.characters.isEmpty {
          ProgressView("正在读取角色库…")
            .padding(22)
            .wbGlassPanel()
        }
      }
      .navigationTitle("角色")
      .task {
        if model.characters.isEmpty { await model.reload() }
      }
      .sheet(isPresented: $isCreatingCharacter) {
        createSheet
      }
      .sheet(isPresented: $isExtractSheetPresented) {
        CharacterExtractSheet(model: model, storyworldModel: storyworldModel)
      }
      .confirmationDialog(
        "删除角色",
        isPresented: Binding(
          get: { deletionCandidate != nil },
          set: { if !$0 { deletionCandidate = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("删除", role: .destructive) {
          guard let target = deletionCandidate else { return }
          deletionCandidate = nil
          Task { await model.deleteCharacter(id: target.id) }
        }
        Button("取消", role: .cancel) { deletionCandidate = nil }
      } message: {
        if let target = deletionCandidate {
          Text("将永久删除「\(target.name)」及其全部图片。")
        }
      }
      .alert(
        "角色库操作未完成",
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
  }

  private var toolbar: some View {
    #if os(iOS)
      iosToolbar
    #else
      macToolbar
    #endif
  }

  // iPhone 宽度放不下整行控件，拆成「搜索 + 筛选/操作」两行
  private var iosToolbar: some View {
    VStack(spacing: 10) {
      searchField
      HStack(spacing: 10) {
        categoryMenu
        tagMenu
        Spacer(minLength: 0)
        extractButton
        createButton
      }
      .controlSize(.small)
      .lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var macToolbar: some View {
    HStack(spacing: 12) {
      searchField
      categoryMenu
      tagMenu

      Spacer(minLength: 0)

      extractButton
      createButton
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("搜索姓名或简介", text: $model.searchText)
        .textFieldStyle(.plain)
      if !model.searchText.isEmpty {
        Button {
          model.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.primary.opacity(0.05), in: Capsule())
    .frame(maxWidth: 380)
  }

  private var categoryMenu: some View {
    Menu {
      Button("全部分类") { model.selectedCategory = nil }
      ForEach(model.allCategories, id: \.self) { category in
        Button(category) { model.selectedCategory = category }
      }
    } label: {
      Label(model.selectedCategory ?? "分类", systemImage: "folder")
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.bordered)
  }

  private var tagMenu: some View {
    Menu {
      Button("全部标签") { model.selectedTag = nil }
      ForEach(model.allTags, id: \.self) { tag in
        Button(tag) { model.selectedTag = tag }
      }
    } label: {
      Label(model.selectedTag ?? "标签", systemImage: "tag")
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.bordered)
  }

  private var extractButton: some View {
    Button {
      isExtractSheetPresented = true
    } label: {
      #if os(iOS)
        Label("提取", systemImage: "square.and.arrow.down.on.square")
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      #else
        Label("从世界书提取", systemImage: "square.and.arrow.down.on.square")
      #endif
    }
    .buttonStyle(.bordered)
  }

  private var createButton: some View {
    Button {
      newCharacterName = ""
      isCreatingCharacter = true
    } label: {
      Label("新建角色", systemImage: "plus")
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.borderedProminent)
    .tint(.wbViolet)
  }

  private var posterGrid: some View {
    ScrollView {
      // 单角色全宽行卡，避免窄海报配大片空白
      if horizontalSizeClass == .compact,
        model.filteredCharacters.count == 1,
        let character = model.filteredCharacters.first
      {
        NavigationLink {
          CharacterDetailView(profile: character, model: model, storyworldModel: storyworldModel)
        } label: {
          fullWidthCharacterRow(character)
        }
        .buttonStyle(WBPressableButtonStyle())
        .contextMenu {
          Button(role: .destructive) {
            deletionCandidate = character
          } label: {
            Label("删除角色", systemImage: "trash")
          }
        }
        .frame(maxWidth: .infinity)
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
          ForEach(model.filteredCharacters) { character in
            NavigationLink {
              CharacterDetailView(profile: character, model: model, storyworldModel: storyworldModel)
            } label: {
              characterCard(character)
            }
            .buttonStyle(WBPressableButtonStyle())
            .contextMenu {
              Button(role: .destructive) {
                deletionCandidate = character
              } label: {
                Label("删除角色", systemImage: "trash")
              }
            }
          }
        }
      }
    }
    .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 24)
    .padding(.bottom, 28)
  }

  private func fullWidthCharacterRow(_ character: CharacterProfile) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Group {
        if let url = model.portraitURL(for: character) {
          CharacterLocalImage(url: url)
        } else {
          CharacterPortraitPlaceholder(name: character.name)
        }
      }
      .frame(width: 72, height: 96)
      .clipped()
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 6) {
        Text(character.name)
          .font(.system(.title3, design: .serif, weight: .bold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        if !character.summary.isEmpty {
          Text(character.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.14), radius: 13, y: 7)
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func characterCard(_ character: CharacterProfile) -> some View {
    // 底图用 Color.clear 撑出 3:4，形象图放 overlay 里，
    // 避免横版图片的固有宽高比把卡片撑宽
    Color.clear
      .aspectRatio(3.0 / 4.0, contentMode: .fit)
      .overlay(alignment: .bottomLeading) {
        ZStack(alignment: .bottomLeading) {
          Group {
            if let url = model.portraitURL(for: character) {
              CharacterLocalImage(url: url)
            } else {
              CharacterPortraitPlaceholder(name: character.name)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)

          LinearGradient(
            colors: [.clear, .black.opacity(0.78)],
            startPoint: .center,
            endPoint: .bottom
          )

          VStack(alignment: .leading, spacing: 4) {
            Text(character.name)
              .font(.system(.title3, design: .serif, weight: .bold))
              .foregroundStyle(.white)
              .lineLimit(1)
            if !character.summary.isEmpty {
              Text(character.summary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
            }
          }
          .padding(15)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.14), radius: 13, y: 7)
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var emptyState: some View {
    VStack(spacing: 20) {
      WBEmptyStateView(
        title: "还没有角色",
        symbol: "person.crop.rectangle.stack.fill",
        message: "新建角色，录入资料并导入形象图片。",
        gradient: LinearGradient(
          colors: [.wbViolet, .wbIndigo],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      HStack(spacing: 12) {
        Button {
          isExtractSheetPresented = true
        } label: {
          Label("从世界书提取", systemImage: "square.and.arrow.down.on.square")
        }
        .buttonStyle(.bordered)
        Button {
          newCharacterName = ""
          isCreatingCharacter = true
        } label: {
          Label("新建角色", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(.wbViolet)
      }
    }
    .padding(.bottom, 50)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var createSheet: some View {
    NavigationStack {
      Form {
        TextField("角色姓名", text: $newCharacterName)
        Text("创建后可继续编辑资料并导入形象图片。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("新建角色")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { isCreatingCharacter = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("创建") {
            let name = newCharacterName
            Task {
              await model.createCharacter(name: name)
              if model.errorMessage == nil { isCreatingCharacter = false }
            }
          }
          .disabled(
            model.isWorking
              || newCharacterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 380, minHeight: 170)
    #endif
  }
}

struct CharacterLocalImage: View {
  let url: URL

  var body: some View {
    #if os(macOS)
      if let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.primary.opacity(0.06)
      }
    #else
      if let image = UIImage(contentsOfFile: url.path) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.primary.opacity(0.06)
      }
    #endif
  }
}

struct CharacterPortraitPlaceholder: View {
  let name: String

  private var initial: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map(String.init) ?? "角"
  }

  var body: some View {
    // 占位圆与首字随卡宽缩放，避免在窄卡中溢出
    GeometryReader { geometry in
      let cardWidth = geometry.size.width
      ZStack {
        LinearGradient(
          colors: [.wbViolet.opacity(0.9), .wbIndigo.opacity(0.65)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Circle()
          .fill(Color.white.opacity(0.12))
          .frame(width: cardWidth * 0.8, height: cardWidth * 0.8)
          .blur(radius: 2)
        Text(initial)
          .font(.system(size: cardWidth * 0.45, weight: .bold, design: .serif))
          .foregroundStyle(.white.opacity(0.9))
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }
}
