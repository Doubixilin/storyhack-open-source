import StoryworldCore
import SwiftUI
#if os(iOS)
  import Photos
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

struct EndingReportView: View {
  @ObservedObject var model: StorySessionViewModel
  let dismiss: () -> Void

  @State private var shareURL: URL?
  @State private var exportMessage: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          titleBlock
          statisticsBlock
          verdictBlock
          actionBlock
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity)
      }
      .background { WBAmbientScenery() }
      .navigationTitle("结局报告")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成", action: dismiss)
        }
      }
    }
    .task {
      if model.endingReport == nil, !model.isGeneratingEndingReport {
        model.openEndingReport()
      }
    }
    .task(id: model.endingReport?.verdict) {
      guard let report = model.endingReport else {
        shareURL = nil
        return
      }
      shareURL = try? renderCard(report: report).writeTemporaryPNG()
    }
    .onDisappear { model.cancelEndingReportGeneration() }
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(model.storyworld?.manifest.title ?? "故事世界")
        .font(.system(.largeTitle, design: .serif, weight: .bold))
      if let count = model.endingReport?.generatedAtEffectiveTurnCount {
        Text("已生成于第 \(count) 回 · 此后仍可继续游玩")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        Text("为此刻走过的一生留一纸记述")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var statisticsBlock: some View {
    GroupBox("此生行迹") {
      VStack(alignment: .leading, spacing: 10) {
        if model.endingStatisticLines.isEmpty {
          ProgressView("正在清点行迹…")
        } else {
          ForEach(Array(model.endingStatisticLines.enumerated()), id: \.offset) { _, line in
            Label(line, systemImage: "seal")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.vertical, 6)
    }
  }

  private var verdictBlock: some View {
    GroupBox("终局判词") {
      VStack(alignment: .leading, spacing: 12) {
        if let verdict = model.endingReport?.verdict {
          Text(verdict)
            .font(.system(.body, design: .serif))
            .lineSpacing(7)
            .textSelection(.enabled)
        } else if !model.streamingEndingVerdict.isEmpty {
          Text(model.streamingEndingVerdict)
            .font(.system(.body, design: .serif))
            .lineSpacing(7)
          ProgressView()
            .controlSize(.small)
        } else if model.isGeneratingEndingReport {
          ProgressView("正在写下判词…")
        } else if let error = model.endingReportError {
          ContentUnavailableView(
            "判词未生成",
            systemImage: "exclamationmark.bubble",
            description: Text(error)
          )
          Button("重试") { model.openEndingReport(regenerate: true) }
            .buttonStyle(.borderedProminent)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
    }
  }

  @ViewBuilder
  private var actionBlock: some View {
    if let report = model.endingReport {
      VStack(alignment: .leading, spacing: 12) {
        Text("纪念卡")
          .font(.headline)
        EndingMemorialCardView(
          worldTitle: model.storyworld?.manifest.title ?? "故事世界",
          report: report
        )
        .aspectRatio(3 / 4, contentMode: .fit)
        .frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)

        HStack(spacing: 12) {
          #if os(iOS)
            Button {
              saveToPhotos(report: report)
            } label: {
              Label("保存到相册", systemImage: "photo.badge.arrow.down")
            }
            .buttonStyle(.borderedProminent)
          #endif

          if let shareURL {
            ShareLink(item: shareURL) {
              Label("分享图片", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
          } else {
            ProgressView("准备图片…")
          }

          Spacer()

          Button("重新生成") {
            shareURL = nil
            model.openEndingReport(regenerate: true)
          }
          .disabled(model.isGeneratingEndingReport)
        }

        if let exportMessage {
          Text(exportMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @MainActor
  private func renderCard(report: StoryEndingReport) throws -> RenderedEndingCard {
    let card = EndingMemorialCardView(
      worldTitle: model.storyworld?.manifest.title ?? "故事世界",
      report: report
    )
    .frame(width: 720, height: 960)
    let renderer = ImageRenderer(content: card)
    renderer.scale = 1.5
    #if os(iOS)
      guard let image = renderer.uiImage else { throw EndingCardExportError.renderFailed }
      return RenderedEndingCard(image: image)
    #elseif os(macOS)
      guard let image = renderer.nsImage else { throw EndingCardExportError.renderFailed }
      return RenderedEndingCard(image: image)
    #endif
  }

  #if os(iOS)
    private func saveToPhotos(report: StoryEndingReport) {
      Task { @MainActor in
        do {
          let card = try renderCard(report: report)
          let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
          guard status == .authorized || status == .limited else {
            throw EndingCardExportError.photoAccessDenied
          }
          try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: card.image)
          }
          exportMessage = "纪念卡已保存到相册。"
        } catch {
          exportMessage = "保存失败：\(error.localizedDescription)"
        }
      }
    }
  #endif
}

private struct EndingMemorialCardView: View {
  let worldTitle: String
  let report: StoryEndingReport

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.09, green: 0.07, blue: 0.16), Color(red: 0.25, green: 0.16, blue: 0.38)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 8) {
          Text("一生判词")
            .font(.system(size: 46, weight: .bold, design: .serif))
          Text(worldTitle)
            .font(.system(size: 24, weight: .medium, design: .serif))
            .foregroundStyle(.white.opacity(0.76))
        }
        Rectangle()
          .fill(Color.white.opacity(0.24))
          .frame(height: 1)
        VStack(alignment: .leading, spacing: 9) {
          ForEach(Array(report.statisticLines.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(size: 18, weight: .medium, design: .serif))
          }
        }
        Text(report.verdict)
          .font(.system(size: 25, weight: .regular, design: .serif))
          .lineSpacing(9)
          .minimumScaleFactor(0.72)
        Spacer(minLength: 10)
        HStack {
          Text("Storyhack")
            .font(.system(size: 20, weight: .semibold, design: .rounded))
          Spacer()
          Text("第 \(report.generatedAtEffectiveTurnCount) 回留存")
            .font(.system(size: 16, weight: .medium, design: .serif))
            .foregroundStyle(.white.opacity(0.68))
        }
      }
      .foregroundStyle(.white)
      .padding(58)
    }
  }
}

private enum EndingCardExportError: Error, LocalizedError {
  case renderFailed
  case encodingFailed
  case photoAccessDenied

  var errorDescription: String? {
    switch self {
    case .renderFailed: "无法渲染纪念卡。"
    case .encodingFailed: "无法编码纪念卡图片。"
    case .photoAccessDenied: "没有添加照片的权限。"
    }
  }
}

#if os(iOS)
  private struct RenderedEndingCard {
    let image: UIImage

    func writeTemporaryPNG() throws -> URL {
      guard let data = image.pngData() else { throw EndingCardExportError.encodingFailed }
      return try write(data)
    }
  }
#elseif os(macOS)
  private struct RenderedEndingCard {
    let image: NSImage

    func writeTemporaryPNG() throws -> URL {
      guard let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
      else { throw EndingCardExportError.encodingFailed }
      return try write(data)
    }
  }
#endif

private func write(_ data: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("storyhack-ending-\(UUID().uuidString).png")
  try data.write(to: url, options: .atomic)
  return url
}
