import CoreText
import LibraryCore
import NovelDocumentCore
import SwiftUI

private struct ReaderTextPage: Identifiable, Equatable, Sendable {
  let id: Int
  let text: String
  let range: ReaderPageRange
}

private enum ReaderTextPaginator {
  static func paginate(
    _ text: String,
    width: CGFloat,
    height: CGFloat,
    fontSize: CGFloat,
    lineSpacing: CGFloat
  ) -> [ReaderTextPage] {
    let source = text as NSString
    guard source.length > 0 else {
      return [ReaderTextPage(id: 0, text: "", range: .init(location: 0, length: 0))]
    }

    let font = CTFontCreateWithName("NewYork-Regular" as CFString, fontSize, nil)
    var spacing = lineSpacing
    let paragraphStyle: CTParagraphStyle = withUnsafePointer(to: &spacing) { pointer in
      var setting = CTParagraphStyleSetting(
        spec: .lineSpacingAdjustment,
        valueSize: MemoryLayout<CGFloat>.size,
        value: pointer
      )
      return CTParagraphStyleCreate(&setting, 1)
    }
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
      ]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(
      rect: CGRect(
        x: 0,
        y: 0,
        width: max(width, 120),
        height: max(height - 14, 120)
      ),
      transform: nil
    )

    var pages: [ReaderTextPage] = []
    var location = 0
    while location < source.length {
      let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: location, length: 0),
        path,
        nil
      )
      let visible = CTFrameGetVisibleStringRange(frame)
      let length = min(max(visible.length, 1), source.length - location)
      let range = NSRange(location: location, length: length)
      pages.append(
        ReaderTextPage(
          id: pages.count,
          text: source.substring(with: range),
          range: ReaderPageRange(location: location, length: length)
        )
      )
      location += length
    }
    return pages
  }
}

enum ReaderPageTapTarget: Equatable {
  case previous
  case chrome
  case next

  static func resolve(x: CGFloat, width: CGFloat) -> Self {
    guard width > 0 else { return .chrome }
    if x < width / 3 { return .previous }
    if x > width * 2 / 3 { return .next }
    return .chrome
  }
}

struct ReaderPaginatedView: View {
  let chapter: NovelChapter
  let initialProgress: Double
  let navigationToken: UUID
  let preferences: ReaderPreferences
  let theme: ReaderTheme
  let isCompact: Bool
  let hasPreviousChapter: Bool
  let hasNextChapter: Bool
  let progressChanged: (Double) -> Void
  let moveToPreviousChapter: () -> Void
  let moveToNextChapter: () -> Void
  let centerTapped: () -> Void

  @State private var pages: [ReaderTextPage] = []
  @State private var currentPage = 0
  @State private var turnDirection = 1
  @GestureState private var dragOffset: CGFloat = 0

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        pageSurface(size: geometry.size)
          .contentShape(Rectangle())
          .offset(x: resistedDragOffset)
          .simultaneousGesture(pageDragGesture)
          .simultaneousGesture(pageTapGesture(width: geometry.size.width))

        #if os(macOS)
          HStack {
            pageButton(direction: -1, symbol: "chevron.left", label: "上一页")
            Spacer()
            pageButton(direction: 1, symbol: "chevron.right", label: "下一页")
          }
          .padding(.horizontal, 12)
        #endif
      }
      .accessibilityAction(named: "上一页") { turnPage(-1) }
      .accessibilityAction(named: "下一页") { turnPage(1) }
      .task(id: layoutID(for: geometry.size)) {
        let width = pageWidth(in: geometry.size)
        let height = max(geometry.size.height - (isCompact ? 104 : 118), 180)
        let content = chapter.content
        let fontSize = preferences.fontSize
        let lineSpacing = preferences.lineSpacing
        let generated = await Task.detached(priority: .userInitiated) {
          ReaderTextPaginator.paginate(
            content,
            width: width,
            height: height,
            fontSize: fontSize,
            lineSpacing: lineSpacing
          )
        }.value
        guard !Task.isCancelled else { return }
        pages = generated
        currentPage = ReaderPageNavigation.pageIndex(
          for: initialProgress,
          ranges: generated.map(\.range),
          totalUTF16Length: (content as NSString).length
        )
        reportProgress()
      }
    }
  }

  private var pageDragGesture: some Gesture {
    DragGesture(minimumDistance: 24)
      .updating($dragOffset) { value, offset, _ in
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        offset = value.translation.width
      }
      .onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height) * 1.6,
          abs(value.translation.width) >= 72
        else { return }
        turnPage(value.translation.width < 0 ? 1 : -1)
      }
  }

  private func pageTapGesture(width: CGFloat) -> some Gesture {
    // 单击即时翻页；快速连点按多次单击处理。
    SpatialTapGesture(count: 1)
      .onEnded { tap in
        switch ReaderPageTapTarget.resolve(x: tap.location.x, width: width) {
        case .previous:
          turnPage(-1)
        case .chrome:
          centerTapped()
        case .next:
          turnPage(1)
        }
      }
  }

  private var resistedDragOffset: CGFloat {
    guard dragOffset != 0 else { return 0 }
    let direction = dragOffset < 0 ? 1 : -1
    return canTurn(direction) ? dragOffset : dragOffset * 0.18
  }

  @ViewBuilder
  private func pageSurface(size: CGSize) -> some View {
    if pages.isEmpty {
      ProgressView("正在分页…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let page = pages[min(max(currentPage, 0), pages.count - 1)]
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(chapter.title)
            .font(.system(.headline, design: .serif, weight: .semibold))
            .lineLimit(1)
          Spacer()
          Text("第 \(currentPage + 1) / \(pages.count) 页")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Rectangle()
          .fill(theme.separatorColor)
          .frame(height: 0.5)

        Text(page.text)
          .font(.system(size: preferences.fontSize, weight: .regular, design: .serif))
          .lineSpacing(preferences.lineSpacing)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .clipped()
          .id("\(chapter.id)-\(page.id)-\(turnDirection)")
          .transition(
            .asymmetric(
              insertion: .move(edge: turnDirection > 0 ? .trailing : .leading).combined(with: .opacity),
              removal: .move(edge: turnDirection > 0 ? .leading : .trailing).combined(with: .opacity)
            )
          )
      }
      .padding(.horizontal, isCompact ? 24 : 72)
      .padding(.vertical, isCompact ? 18 : 26)
      .frame(width: min(size.width, pageWidth(in: size) + (isCompact ? 48 : 144)))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  #if os(macOS)
    private func pageButton(direction: Int, symbol: String, label: String) -> some View {
      Button {
        turnPage(direction)
      } label: {
        Image(systemName: symbol)
          .font(.headline.weight(.semibold))
          .frame(width: 34, height: 54)
          .background(.ultraThinMaterial, in: Capsule())
      }
      .buttonStyle(.plain)
      .disabled(!canTurn(direction))
      .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: [])
      .help(label)
      .accessibilityLabel(label)
    }
  #endif

  private func pageWidth(in size: CGSize) -> CGFloat {
    min(CGFloat(preferences.contentWidth), max(size.width - (isCompact ? 48 : 176), 260))
  }

  private func layoutID(for size: CGSize) -> String {
    [
      chapter.id,
      navigationToken.uuidString,
      String(Int(size.width.rounded())),
      String(Int(size.height.rounded())),
      String(Int(preferences.fontSize.rounded())),
      String(Int(preferences.lineSpacing.rounded())),
      String(Int(preferences.contentWidth.rounded())),
    ].joined(separator: ":")
  }

  private func canTurn(_ direction: Int) -> Bool {
    switch ReaderPageNavigation.turn(
      from: currentPage,
      pageCount: pages.count,
      direction: direction,
      hasPreviousChapter: hasPreviousChapter,
      hasNextChapter: hasNextChapter
    ) {
    case .unavailable: false
    default: true
    }
  }

  private func turnPage(_ direction: Int) {
    switch ReaderPageNavigation.turn(
      from: currentPage,
      pageCount: pages.count,
      direction: direction,
      hasPreviousChapter: hasPreviousChapter,
      hasNextChapter: hasNextChapter
    ) {
    case .page(let index):
      withAnimation(.easeOut(duration: 0.2)) {
        turnDirection = direction
        currentPage = index
      }
      reportProgress()
    case .previousChapter:
      turnDirection = direction
      moveToPreviousChapter()
    case .nextChapter:
      turnDirection = direction
      moveToNextChapter()
    case .unavailable:
      break
    }
  }

  private func reportProgress() {
    guard pages.indices.contains(currentPage) else { return }
    progressChanged(
      ReaderPageNavigation.progression(
        for: pages[currentPage].range,
        totalUTF16Length: (chapter.content as NSString).length
      )
    )
  }
}
