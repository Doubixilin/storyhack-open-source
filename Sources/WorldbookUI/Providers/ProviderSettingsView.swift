import LLMProviderKit
import SwiftUI

struct ProviderSettingsView: View {
  @ObservedObject var model: ProviderSettingsViewModel
  let platform: WorldbookAppPlatform
  @Binding var privacyModeEnabled: Bool

  @State private var selectedID: UUID?
  @State private var displayName = ""
  @State private var baseURL = ""
  @State private var modelID = ""
  @State private var apiKey = ""
  @State private var factoryConcurrency = ProviderProfile.defaultFactoryConcurrency
  @State private var contextWindow = ""
  @State private var maximumOutputTokens = ""
  @State private var chapterToolCalling = false
  @State private var pendingDeleteID: UUID?
  @State private var isEditorPresented = false

  var body: some View {
    ZStack {
      WBAmbientScenery()
      if platform == .iOS {
        ScrollView {
          VStack(spacing: 16) {
            privacyPanel
            profileList
          }
          .padding(16)
        }
        .sheet(isPresented: $isEditorPresented) {
          NavigationStack {
            ScrollView { editor }
              .navigationTitle(selectedID == nil ? "添加模型" : "编辑模型")
              .modify { view in
                #if os(iOS)
                  view.navigationBarTitleDisplayMode(.inline)
                #else
                  view
                #endif
              }
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button("完成") { isEditorPresented = false }
                }
              }
          }
          .presentationDragIndicator(.visible)
        }
      } else {
        HStack(spacing: 22) {
          profileList
            .frame(width: 310)
          VStack(spacing: 16) {
            privacyPanel
            ScrollView { editor }
          }
            .frame(maxWidth: 680)
          Spacer(minLength: 0)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .navigationTitle("模型设置")
    .onChange(of: selectedID) { _, newValue in
      loadForm(profileID: newValue)
    }
    .confirmationDialog(
      "删除这个模型配置？",
      isPresented: Binding(
        get: { pendingDeleteID != nil },
        set: { if !$0 { pendingDeleteID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除配置与 Keychain 密钥", role: .destructive) {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        Task {
          await model.delete(id)
          if selectedID == id {
            selectedID = nil
            clearForm()
            if platform == .iOS {
              isEditorPresented = false
            }
          }
        }
      }
      Button("取消", role: .cancel) { pendingDeleteID = nil }
    }
    .alert(
      "模型设置未完成",
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

  private var privacyPanel: some View {
    HStack(spacing: 14) {
      Image(systemName: privacyModeEnabled ? "eye.slash.fill" : "eye")
        .font(.title3)
        .foregroundStyle(privacyModeEnabled ? Color.wbViolet : Color.secondary)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text("隐私模式")
          .font(.headline)
        Text("切换到其他 App 或进入后台时，自动遮住小说、世界书和会话内容。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle("隐私模式", isOn: $privacyModeEnabled)
        .labelsHidden()
    }
    .padding(18)
    .wbGlassPanel(cornerRadius: 18, shadowOpacity: 0.06)
  }

  private var profileList: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(platform == .iOS ? "模型配置" : "模型设置")
            .font(platform == .iOS ? .headline : .system(.title2, design: .serif, weight: .bold))
          Text("密钥只保存在系统 Keychain")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          selectedID = nil
          clearForm()
          if platform == .iOS {
            isEditorPresented = true
          }
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.bordered)
        .help("新建模型配置")
      }

      if model.profiles.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "key.horizontal.fill")
            .font(.largeTitle)
            .foregroundStyle(Color.wbViolet)
          Text("还没有模型配置")
            .font(.headline)
          Text("添加用户自己拥有的 OpenAI-compatible 服务。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
      } else {
        ScrollView {
          LazyVStack(spacing: 9) {
            ForEach(model.profiles) { profile in
              Button {
                selectedID = profile.id
                if platform == .iOS {
                  isEditorPresented = true
                }
              } label: {
                HStack(spacing: 11) {
                  Image(systemName: "network")
                    .foregroundStyle(Color.wbViolet)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                      .font(.headline)
                      .foregroundStyle(.primary)
                    Text(profile.modelID)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  Spacer()
                  if selectedID == profile.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(Color.wbTeal)
                  }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  selectedID == profile.id ? Color.wbViolet.opacity(0.11) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .padding(20)
    .frame(maxHeight: platform == .macOS ? .infinity : nil, alignment: .top)
    .wbGlassPanel(cornerRadius: 20, shadowOpacity: 0.08)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 20) {
      if platform != .iOS {
        VStack(alignment: .leading, spacing: 4) {
          Text(selectedID == nil ? "添加模型" : "编辑模型")
            .font(.system(.title2, design: .serif, weight: .bold))
          Text("当前阶段支持 OpenAI-compatible Chat Completions 流式接口。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("当前阶段支持 OpenAI-compatible Chat Completions 流式接口。")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      formField("显示名称") {
        TextField("例如：我的 DeepSeek", text: $displayName)
          .wbFormField()
      }
      formField("Base URL") {
        TextField("https://api.example.com/v1", text: $baseURL)
          .wbFormField()
      }
      formField("模型 ID") {
        TextField("模型服务提供的 model ID", text: $modelID)
          .wbFormField()
      }
      formField("API Key") {
        SecureField(
          selectedID == nil ? "输入 API Key" : "留空则保留 Keychain 中的现有密钥",
          text: $apiKey
        )
        .wbFormField()
      }
      formField("工坊并发数") {
        VStack(alignment: .leading, spacing: 6) {
          Stepper(
            "同时分析 \(factoryConcurrency) 个批次",
            value: $factoryConcurrency,
            in: ProviderProfile.factoryConcurrencyRange
          )
          Text("默认 3。世界书工坊同时向模型服务发送的批次数；并发过高可能触发模型服务限流（429）。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      formField("模型上下文窗口（tokens）") {
        TextField("留空使用 32768", text: $contextWindow).wbFormField()
        Text("填写模型支持的窗口大小。应用会为回复预留空间，按预算选取完整设定与近期对话。")
          .font(.caption).foregroundStyle(.secondary)
      }
      formField("单回合输出上限（tokens）") {
        TextField("留空自动设置，通常为 4096", text: $maximumOutputTokens).wbFormField()
        Text("上限越高，可用于历史的空间越少。实际输出长度仍由模型决定。")
          .font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 6) {
        Toggle("允许模型回读过往章节卡", isOn: $chapterToolCalling)
        Text("首次需要时发送最多两次简短测试请求，不含书籍内容；检测通过后才启用。回读最多两轮，额外请求可能产生费用；不支持或预算不足时继续普通叙事。")
          .font(.caption).foregroundStyle(.secondary)
      }

      HStack {
        if let selectedID {
          Button("删除", role: .destructive) {
            pendingDeleteID = selectedID
          }
          .buttonStyle(.bordered)
        }
        Spacer()
        Button("保存配置") {
          Task {
            let windowText = contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputText = maximumOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (windowText.isEmpty || Int(windowText) != nil),
              (outputText.isEmpty || Int(outputText) != nil) else {
              model.errorMessage = "上下文窗口与输出上限请填写整数，或留空使用默认值。"
              return
            }
            if let saved = await model.save(
              id: selectedID,
              displayName: displayName,
              baseURL: baseURL,
              modelID: modelID,
              apiKey: apiKey,
              factoryConcurrency: factoryConcurrency == ProviderProfile.defaultFactoryConcurrency
                ? nil : factoryConcurrency,
              contextWindow: Int(windowText),
              maximumOutputTokens: Int(outputText),
              chapterToolCalling: chapterToolCalling
            ) {
              self.selectedID = saved.id
              apiKey = ""
              if platform == .iOS {
                isEditorPresented = false
              }
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isWorking)
      }
    }
    .padding(26)
    .wbGlassPanel(cornerRadius: 20, shadowOpacity: 0.08)
    .modify { view in
      if platform == .iOS {
        view.padding(.horizontal, 16).padding(.top, 12)
      } else {
        view
      }
    }
  }

  private func formField<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      content()
    }
  }

  private func loadForm(profileID: UUID?) {
    guard let profileID,
      let profile = model.profiles.first(where: { $0.id == profileID })
    else { return }
    displayName = profile.displayName
    baseURL = profile.baseURL?.absoluteString ?? ""
    modelID = profile.modelID
    apiKey = ""
    factoryConcurrency = profile.effectiveFactoryConcurrency
    contextWindow = profile.capabilities.contextWindow.map(String.init) ?? ""
    maximumOutputTokens = profile.maximumOutputTokens.map(String.init) ?? ""
    chapterToolCalling = profile.capabilities.toolCalling
  }

  private func clearForm() {
    displayName = ""
    baseURL = ""
    modelID = ""
    apiKey = ""
    factoryConcurrency = ProviderProfile.defaultFactoryConcurrency
    contextWindow = ""
    maximumOutputTokens = ""
    chapterToolCalling = false
  }
}

private extension View {
  /// 设置表单输入框：圆角浅底，与玻璃面板风格统一
  func wbFormField() -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        Color.primary.opacity(0.05),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
  }
}
