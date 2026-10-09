import LibraryCore
import NovelDocumentCore
import SwiftUI

// MARK: - 滚动进度测量

struct ReaderContentGeometry: Equatable {
  let minY: CGFloat
  let height: CGFloat
}

struct ReaderContentGeometryKey: PreferenceKey {
  static let defaultValue = ReaderContentGeometry(minY: 0, height: 0)

  static func reduce(value: inout ReaderContentGeometry, nextValue: () -> ReaderContentGeometry) {
    value = nextValue()
  }
}

@MainActor
private final class ReaderScrollProgressReporter {
  private var pendingTask: Task<Void, Never>?
  private var latestProgress: Double?

  func schedule(_ progress: Double, report: @escaping (Double) -> Void) {
    latestProgress = progress
    pendingTask?.cancel()
    pendingTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(140))
      guard !Task.isCancelled, let self, let latestProgress else { return }
      pendingTask = nil
      self.latestProgress = nil
      report(latestProgress)
    }
  }

  func flush(report: (Double) -> Void) {
    pendingTask?.cancel()
    pendingTask = nil
    guard let latestProgress else { return }
    self.latestProgress = nil
    report(latestProgress)
  }

  func cancel() {
    pendingTask?.cancel()
    pendingTask = nil
    latestProgress = nil
  }
}

// MARK: - 章节正文

struct ReaderChapterScrollView: View {
  let chapter: NovelChapter
  let initialProgress: Double
  let navigationToken: UUID
  let preferences: ReaderPreferences
  let theme: ReaderTheme
  let progressChanged: (Double) -> Void
  let topStateChanged: (Bool) -> Void
  @State private var progressTrackingChapterID: String?
  @State private var isContentVisible = false
  @State private var paragraphs: [String]?
  @State private var progressReporter = ReaderScrollProgressReporter()

  var body: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          Group {
            if let paragraphs {
              LazyVStack(alignment: .leading, spacing: 0) {
                chapterHeader
                  .padding(.bottom, 26)
                  .id(markerID(0))

                ForEach(paragraphs.indices, id: \.self) { index in
                  let paragraph = paragraphs[index]
                  if paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear
                      .frame(height: preferences.lineSpacing + 5)
                      .id(markerID(index + 1))
                  } else {
                    Text(paragraph)
                      .font(.system(size: preferences.fontSize, weight: .regular, design: .serif))
                      .lineSpacing(preferences.lineSpacing)
                      .padding(.bottom, max(preferences.lineSpacing * 0.55, 3))
                      .id(markerID(index + 1))
                  }
                }
              }
              // 整章共用一个选择域：逐段落挂 textSelection 会让每一行都成为
              // SwiftUI 焦点参与者，大书上点击正文会反复使 NSHostingView 焦点存储失效。
              .textSelection(.enabled)
            } else {
              ProgressView("正在排版…")
                .frame(maxWidth: .infinity, minHeight: viewport.size.height * 0.7)
            }
          }
          .opacity(paragraphs == nil || isContentVisible ? 1 : 0)
          .frame(maxWidth: preferences.contentWidth, alignment: .leading)
          .padding(.horizontal, 40)
          .padding(.vertical, 36)
          .frame(maxWidth: .infinity, alignment: .center)
          .background(
            GeometryReader { content in
              Color.clear.preference(
                key: ReaderContentGeometryKey.self,
                value: ReaderContentGeometry(
                  minY: content.frame(in: .named("reader-scroll")).minY,
                  height: content.size.height
                )
              )
            }
          )
        }
        .coordinateSpace(name: "reader-scroll")
        .onPreferenceChange(ReaderContentGeometryKey.self) { geometry in
          let isAtTop = geometry.minY >= -2
          topStateChanged(isAtTop)
          guard progressTrackingChapterID == chapter.id else { return }
          let scrollableHeight = max(geometry.height - viewport.size.height, 1)
          let progress = min(max(-geometry.minY / scrollableHeight, 0), 1)
          if isAtTop {
            // 下拉手势结束前把顶部位置同步为 0，避免书签拿到上一次滚动位置。
            progressReporter.cancel()
            progressChanged(0)
          } else {
            progressReporter.schedule(progress, report: progressChanged)
          }
        }
        .task(id: chapter.id) {
          progressReporter.cancel()
          progressTrackingChapterID = nil
          isContentVisible = false
          paragraphs = nil
          let content = chapter.content
          let parsed = await Task.detached(priority: .userInitiated) {
            content.components(separatedBy: "\n")
          }.value
          guard !Task.isCancelled else { return }
          paragraphs = parsed.isEmpty ? [content] : parsed
        }
        .task(id: "\(navigationToken.uuidString):\(paragraphs?.count ?? -1)") {
          guard let paragraphs else { return }
          progressReporter.cancel()
          progressTrackingChapterID = nil
          isContentVisible = false
          await Task.yield()
          let lastIndex = max(paragraphs.count, 1)
          let target = min(max(Int((initialProgress * Double(lastIndex)).rounded()), 0), lastIndex)
          proxy.scrollTo(markerID(target), anchor: .top)
          withAnimation(.easeOut(duration: 0.3)) {
            isContentVisible = true
          }
          try? await Task.sleep(for: .milliseconds(180))
          progressTrackingChapterID = chapter.id
        }
        .onDisappear {
          guard progressTrackingChapterID == chapter.id else {
            progressReporter.cancel()
            return
          }
          progressReporter.flush(report: progressChanged)
        }
      }
    }
  }

  /// 章节头：主题色短线 + 衬线标题 + 章节元信息
  private var chapterHeader: some View {
    VStack(alignment: .leading, spacing: 13) {
      Capsule()
        .fill(theme.accentColor)
        .frame(width: 34, height: 3.5)

      Text(chapter.title)
        .font(.system(.title2, design: .serif, weight: .semibold))

      if chapter.characterCount > 0 {
        Text("第 \(chapter.ordinal + 1) 章 · 共 \(chapter.characterCount) 字")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func markerID(_ index: Int) -> String {
    "\(chapter.id)-paragraph-\(index)"
  }
}
