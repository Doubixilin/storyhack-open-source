#if os(macOS)
import AppKit
import LibraryCore
import SwiftUI
import Testing

@testable import WorldbookUI

@MainActor
struct AppearanceRenderingTests {
  @Test func nativeWindowRemovesDarkPreferenceWhenReturningToSystemReader() async throws {
    let application = NSApplication.shared
    let original = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    let controller = NSHostingController(rootView: NativeAppearancePreview(theme: nil))
    let window = NSWindow(contentViewController: controller)
    window.isReleasedWhenClosed = false
    window.setFrame(NSRect(x: -4000, y: -4000, width: 480, height: 240), display: false)
    window.orderFront(nil)
    defer { window.close() }
    // Exercise preference removal in both directions on the same presentation.
    for theme: ReaderTheme? in [nil, .light, .system, .dark, .sepia, .system, nil] {
      controller.rootView = NativeAppearancePreview(theme: theme)
      controller.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let expected: NSAppearance.Name
      switch theme {
      case .system: expected = try #require(original)
      case .light, .sepia: expected = .aqua
      case .dark, nil: expected = .darkAqua
      }
      #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
        "Native window theme: \(String(describing: theme))")
    }
  }

  // Render the actual modifiers, semantic foreground and backgrounds together.
  // Checking only the theme enum would miss dark application inheritance and
  // transparent reader backgrounds that make system-light text unreadable.
  @Test func readerAndApplicationRemainLegibleAcrossSystemAppearances() throws {
    for system in [ColorScheme.light, .dark] {
      for theme in ReaderTheme.allCases {
        let image = try render(
          HStack(spacing: 0) {
            AppearanceSwatch(background: .wbCanvas, foreground: .primary)
            AppearanceSwatch(background: theme.backgroundColor, foreground: theme.foregroundColor)
              .readerColorScheme(theme)
          }
          .modifier(WBApplicationAppearance(readerTheme: theme))
          .environment(\.colorScheme, system)
        )
        let appBackground = try luminance(image, x: 5, y: 40)
        let appText = try luminance(image, x: 40, y: 40)
        let readerBackground = try luminance(image, x: 85, y: 40)
        let readerText = try luminance(image, x: 120, y: 40)
        #expect(appBackground < 0.15)
        #expect(appText > 0.7)
        let darkReader = theme == .dark || (theme == .system && system == .dark)
        if darkReader {
          #expect(readerBackground < 0.2, "\(system) / \(theme)")
          #expect(readerText > 0.7, "\(system) / \(theme)")
        } else {
          #expect(readerBackground > 0.8, "\(system) / \(theme)")
          #expect(readerText < 0.3, "\(system) / \(theme)")
        }
      }
    }
  }

  @Test func applicationSurfacesAndAmbientSceneryRenderWithVisibleDepth() throws {
    let image = try render(HStack(spacing: 0) {
      Color.wbCanvas
      Color.wbPanel
      Color.wbPanelRaised
    }.frame(width: 240, height: 80).environment(\.colorScheme, .light))
    let canvas = try luminance(image, x: 40, y: 40)
    let panel = try luminance(image, x: 120, y: 40)
    let raised = try luminance(image, x: 200, y: 40)
    #expect(canvas < panel && panel < raised && raised < 0.2)

    let preview = try render(AppearancePreview().modifier(WBApplicationAppearance(readerTheme: nil)))
    let glow = try luminance(preview, x: 980, y: 15)
    let quiet = try luminance(preview, x: 400, y: 15)
    #expect(glow > quiet + 0.02)
    // Synthetic component preview only: no default stores or real books are opened.
    if let path = ProcessInfo.processInfo.environment["WORLDBOOK_APPEARANCE_PREVIEW"] {
      let png = try #require(preview.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path))
    }
  }

  /// Per-screen contrast pass: every readable token pair must clear WCAG AA
  /// normal-text contrast (4.5). Decorative strokes use the 3.0 UI threshold.
  @Test func themeTokensMeetTextContrastTargetsOnEveryApplicationSurface() throws {
    let surfaces: [(String, Color)] = [
      ("canvas", .wbCanvas), ("panel", .wbPanel), ("panelRaised", .wbPanelRaised),
    ]
    let readableText: [(String, Color)] = [
      ("ink", .wbInk), ("muted", .wbMuted), ("gold", .wbGold), ("teal", .wbTeal),
    ]
    for (surfaceName, surface) in surfaces {
      for (textName, text) in readableText {
        let ratio = try contrast(surface, text)
        #expect(ratio >= 4.5, "\(textName) on \(surfaceName): \(ratio)")
      }
      let stroke = try contrast(surface, .wbDeepGold)
      #expect(stroke >= 3.0, "wbDeepGold on \(surfaceName): \(stroke)")
    }
    // Gold and teal solid fills carry dark wbOnAccent labels, not white.
    for (name, fill) in [("wbGold", Color.wbGold), ("wbTeal", Color.wbTeal),
      ("wbIndigo", Color.wbIndigo), ("wbViolet", Color.wbViolet),
      ("wbWarmStart", LinearGradient.wbWarmStart), ("wbWarmEnd", LinearGradient.wbWarmEnd)] {
      let ratio = try contrast(fill, .wbOnAccent)
      #expect(ratio >= 4.5, "wbOnAccent on \(name): \(ratio)")
      let white = try contrast(fill, .white)
      #expect(white < 4.5, "\(name) should not carry white text (got \(white))")
    }
    let bubble = try contrast(.wbUserBubble, .wbUserBubbleText)
    #expect(bubble >= 4.5, "user bubble: \(bubble)")
    for (name, theme) in ReaderTheme.allCases.map({ ($0.title, $0) }) {
      let ratio = try contrast(theme.backgroundColor, theme.foregroundColor)
      #expect(ratio >= 4.5, "reader \(name): \(ratio)")
    }
  }

  /// A dark-first app must not flash the light launch background when the
  /// system is in light mode. The iOS asset catalog must resolve to wbCanvas
  /// for every appearance.
  @Test func iOSLaunchBackgroundStaysOnFixedDarkCanvasInEveryAppearance() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let catalog = root.appendingPathComponent(
      "Apps/iOS/Resources/Assets.xcassets/LaunchBackground.colorset/Contents.json")
    let set = try JSONDecoder().decode(LaunchColorSet.self, from: Data(contentsOf: catalog))
    #expect(set.colors.count >= 2, "launch colorset must cover any + dark appearance")
    let canvas = try srgb(.wbCanvas)
    for entry in set.colors {
      let components = entry.color.components
      let red = try #require(Double(components.red))
      let green = try #require(Double(components.green))
      let blue = try #require(Double(components.blue))
      let alpha = try #require(Double(components.alpha))
      #expect(abs(red - canvas.redComponent) < 0.01
        && abs(green - canvas.greenComponent) < 0.01
        && abs(blue - canvas.blueComponent) < 0.01
        && abs(alpha - 1) < 0.001,
        "launch entry \(entry.appearances?.first?.value ?? "any") is not wbCanvas")
    }
  }

  private func srgb(_ color: Color) throws -> NSColor {
    try #require(NSColor(color).usingColorSpace(.sRGB))
  }

  private func relativeLuminance(_ color: Color) throws -> CGFloat {
    func linear(_ value: CGFloat) -> CGFloat {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    let rgb = try srgb(color)
    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
      + 0.0722 * linear(rgb.blueComponent)
  }

  private func contrast(_ first: Color, _ second: Color) throws -> CGFloat {
    let a = try relativeLuminance(first)
    let b = try relativeLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  private func render(_ view: some View) throws -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
  }

  private func luminance(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
    let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    #expect(color.alphaComponent > 0.99)
    return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
  }
}

private struct AppearanceSwatch: View {
  let background: Color
  let foreground: Color

  var body: some View {
    Rectangle().fill(foreground).padding(20)
      .frame(width: 80, height: 80).background(background)
  }
}

private struct NativeAppearancePreview: View {
  let theme: ReaderTheme?

  var body: some View {
    HStack(spacing: 0) {
      AppearanceSwatch(background: .wbCanvas, foreground: .primary)
      if let theme {
        VStack {
          Text("合成阅读页")
          Button("阅读设置") {}
        }
        .frame(width: 240, height: 180)
        .background(theme.backgroundColor).foregroundStyle(theme.foregroundColor)
        .readerColorScheme(theme)
      }
    }
    .modifier(WBApplicationAppearance(readerTheme: theme))
  }
}

private struct AppearancePreview: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("世界书 · 书卷暖金").font(.largeTitle.bold())
      Text("应用深色画布 · 阅读器独立主题").foregroundStyle(.secondary)
      HStack(spacing: 16) {
        ForEach(["书架", "世界书工坊", "改编与逐章写作"], id: \.self) { title in
          VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("合成内容，仅供外观验证").foregroundStyle(.secondary)
            Text("继续阅读").foregroundStyle(Color.wbOnAccent)
              .padding(10).background(Color.wbGold, in: Capsule())
          }.frame(maxWidth: .infinity, alignment: .leading).padding(20).wbGlassPanel()
        }
      }
      HStack(spacing: 16) {
        ForEach(ReaderTheme.allCases, id: \.self) { theme in
          VStack(alignment: .leading, spacing: 12) {
            Text(theme.title).font(.headline)
            Text("灯火渐明，旅人翻开书页。\n故事从这里继续。")
              .font(.system(.body, design: .serif))
          }
          .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
          .padding(16).foregroundStyle(theme.foregroundColor)
          .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 12))
          .readerColorScheme(theme)
        }
      }
    }
    .padding(32).frame(width: 1000, height: 540)
    .background { WBAmbientScenery() }
  }
}

/// 仅解码启动屏 colorset 中本测试关心的字段。
private struct LaunchColorSet: Decodable {
  struct Entry: Decodable {
    struct Appearance: Decodable { let value: String }
    struct Color: Decodable {
      struct Components: Decodable {
        let red: String
        let green: String
        let blue: String
        let alpha: String
      }
      let components: Components
    }
    let appearances: [Appearance]?
    let color: Color
  }
  let colors: [Entry]
}
#endif
