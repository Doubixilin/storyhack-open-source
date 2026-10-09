import LibraryCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

// MARK: - 品牌色板 · Ink & Gold · 书卷暖金
//
// 深色书卷暖金主题：暖棕近黑底 + 米白正文 + 哑光金点缀。
// 令牌名保持兼容（避免牵动全仓调用点）：wbAccent 现在是主金 #d8b173；
// wbIndigo / wbViolet 保留原名称，但色值已换成暖金系（亮金 / 深金），
// 原靛蓝紫不再出现。wbTeal 是"成功/完成"语义色，维持不变。

/// 按深浅色返回不同色值的动态颜色
private func wbDynamicColor(
  light: (r: Double, g: Double, b: Double, a: Double),
  dark: (r: Double, g: Double, b: Double, a: Double)
) -> Color {
  #if os(macOS)
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let c = isDark ? dark : light
      return NSColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }))
  #else
    Color(uiColor: UIColor { traits in
      let c = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    })
  #endif
}

extension Color {
  /// 主品牌色（原靛蓝位）：亮金 #e1bf86，用于激活态、阴影、渐变起点
  static let wbIndigo = Color(red: 0.882, green: 0.749, blue: 0.525)
  /// 辅助品牌色（原星云紫位）：深金 #b88a50
  static let wbViolet = Color(red: 0.722, green: 0.541, blue: 0.314)
  /// 点缀色：哑光暖金 #d8b173（主强调色）
  static let wbGold = Color(red: 0.847, green: 0.694, blue: 0.451)
  /// 深金 #9b7441：选中描边等需要更低明度的金色
  static let wbDeepGold = Color(red: 0.608, green: 0.455, blue: 0.255)
  /// 点缀色：青瓷（语义"成功/完成"色）
  static let wbTeal = Color(red: 0.16, green: 0.60, blue: 0.58)

  /// App 级强调色：哑光暖金
  static var wbAccent: Color { wbGold }

  /// 金底上的文字/图标色：深棕 #1b150f
  static let wbOnAccent = Color(red: 0.106, green: 0.082, blue: 0.059)

  /// 应用固定深色画布 #12100e；阅读器使用独立的 ReaderTheme。
  static let wbCanvas = Color(red: 0.0706, green: 0.0627, blue: 0.0549)

  /// 面板比画布略亮，保持暖棕层次 #1b1815。
  static let wbPanel = Color(red: 0.106, green: 0.094, blue: 0.082)

  /// 抬升面板 #25201c。
  static let wbPanelRaised = Color(red: 0.145, green: 0.125, blue: 0.110)

  /// 发丝描边色：米白 238,222,196（配合低透明度使用）
  static let wbHairline = Color(red: 0.933, green: 0.871, blue: 0.769)

  /// 面板/卡片描边：米白 12%。
  static let wbStroke = wbHairline.opacity(0.12)

  /// 应用正文米白 #f2e9dc。
  static let wbInk = Color(red: 0.949, green: 0.914, blue: 0.863)

  /// 应用次要文字 #a99d8c。
  static let wbMuted = Color(red: 0.663, green: 0.616, blue: 0.549)

  /// 用户气泡底：暖深棕 #372d24（两态通用）
  static let wbUserBubble = Color(red: 0.216, green: 0.176, blue: 0.141)

  /// 用户气泡文字：米白 #eadfce（两态通用，气泡始终为深棕底）
  static let wbUserBubbleText = Color(red: 0.918, green: 0.875, blue: 0.808)
}

extension LinearGradient {
  /// 品牌主渐变：亮金 #e1bf86 → 深金 #b88a50
  static let wbBrand = LinearGradient(
    colors: [.wbIndigo, .wbViolet],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
  /// 暖色渐变端点：独立成 token 供对比度回归检查（金色底一律配 wbOnAccent）。
  static let wbWarmStart = Color(red: 0.90, green: 0.70, blue: 0.36)
  static let wbWarmEnd = Color(red: 0.78, green: 0.52, blue: 0.24)
  /// 暖色渐变：暖金 → 浅金
  static let wbWarm = LinearGradient(
    colors: [wbWarmStart, wbWarmEnd],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
}

// MARK: - 动效令牌

enum WBMotion {
  /// 按钮、悬停等即时反馈
  static let snappy = Animation.spring(duration: 0.3, bounce: 0.15)
  /// 面板展开、布局迁移
  static let gentle = Animation.spring(duration: 0.45, bounce: 0)
  /// 强调性出现
  static let bouncy = Animation.spring(duration: 0.55, bounce: 0.3)
}

// MARK: - 玻璃材质面板

struct WBGlassPanel: ViewModifier {
  var cornerRadius: CGFloat = 14
  var tint: Color = .clear
  var shadowOpacity: Double = 0.10

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(Color.wbPanel)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(tint)
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(Color.wbStroke, lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(shadowOpacity), radius: 14, y: 6)
  }
}

extension View {
  /// 以闭包变换视图，用于 #available 等需要返回不同视图的场景
  func modify<Transformed: View>(@ViewBuilder _ transform: (Self) -> Transformed) -> some View {
    transform(self)
  }

  /// 暖色书卷面板：面板色打底 + 主题色罩层 + 米白发丝描边 + 柔和投影
  func wbGlassPanel(cornerRadius: CGFloat = 14, tint: Color = .clear, shadowOpacity: Double = 0.10) -> some View {
    modifier(WBGlassPanel(cornerRadius: cornerRadius, tint: tint, shadowOpacity: shadowOpacity))
  }
}

// MARK: - 按钮样式

/// 按压时轻微回弹的卡片按钮
struct WBPressableButtonStyle: ButtonStyle {
  var pressedScale: CGFloat = 0.97

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? pressedScale : 1)
      .opacity(configuration.isPressed ? 0.92 : 1)
      .animation(WBMotion.snappy, value: configuration.isPressed)
  }
}

/// 阅读器玻璃工具条上的图标按钮：悬停浮现胶囊底、按压回弹
struct WBChromeButtonStyle: ButtonStyle {
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
      }
      .scaleEffect(configuration.isPressed ? 0.9 : 1)
      .animation(WBMotion.snappy, value: isHovering)
      .animation(WBMotion.snappy, value: configuration.isPressed)
      .onHover { isHovering = $0 }
  }
}

// MARK: - 胶囊芯片按钮

/// 会话快捷操作等场景的小胶囊：默认透明底 + 米白描边；选中态深金描边 + 金底 8%
struct WBChipButtonStyle: ButtonStyle {
  var isActive: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption.weight(.medium))
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background {
        Capsule()
          .fill(isActive ? Color.wbGold.opacity(0.08) : Color.clear)
      }
      .overlay {
        Capsule()
          .strokeBorder(
            isActive ? Color.wbDeepGold : Color.wbStroke,
            lineWidth: 1
          )
      }
      .foregroundStyle(isActive ? Color.wbGold : Color.wbMuted)
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(WBMotion.snappy, value: configuration.isPressed)
      .animation(WBMotion.snappy, value: isActive)
  }
}

// MARK: - 渐变圆形按钮

/// 品牌金渐变实心圆钮：发送、确认等主操作（金底 + 深棕图标）
struct WBGradientCircleButtonStyle: ButtonStyle {
  var diameter: CGFloat = 36
  var isEnabled: Bool = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: diameter * 0.42, weight: .semibold))
      .foregroundStyle(Color.wbOnAccent)
      .frame(width: diameter, height: diameter)
      .background {
        Circle()
          .fill(LinearGradient.wbBrand)
          .shadow(color: Color.wbGold.opacity(0.35), radius: 6, y: 3)
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.35)
      .scaleEffect(configuration.isPressed ? 0.88 : 1)
      .animation(WBMotion.snappy, value: configuration.isPressed)
      .animation(WBMotion.snappy, value: isEnabled)
  }
}

// MARK: - 氛围背景

/// 书架等场景的底色：暖调画布色 + 两团低透明度的暖金光晕
struct WBAmbientScenery: View {
  var body: some View {
    Color.wbCanvas
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(Color.wbViolet.opacity(0.24))
          .frame(width: 460, height: 460)
          .blur(radius: 140)
          .offset(x: 120, y: -160)
      }
      .overlay(alignment: .bottomLeading) {
        Circle()
          .fill(Color.wbGold.opacity(0.16))
          .frame(width: 380, height: 380)
          .blur(radius: 130)
          .offset(x: -100, y: 140)
      }
      .allowsHitTesting(false)
      .ignoresSafeArea()
  }
}

// MARK: - 品牌空状态

/// 统一的占位视图：玻璃圆盘中的渐变符号 + 衬线标题
struct WBEmptyStateView: View {
  let title: String
  let symbol: String
  let message: String
  var gradient: LinearGradient = .wbBrand

  var body: some View {
    VStack(spacing: 18) {
      ZStack {
        Circle()
          .fill(.regularMaterial)
          .overlay {
            Circle().fill(gradient.opacity(0.14))
          }
          .overlay {
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
          }
          .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        Image(systemName: symbol)
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(gradient)
          .symbolRenderingMode(.hierarchical)
      }
      .frame(width: 88, height: 88)

      VStack(spacing: 7) {
        Text(title)
          .font(.system(.title2, design: .serif, weight: .semibold))
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - 阅读主题（配色精调版）

extension ReaderTheme {
  var title: String {
    switch self {
    case .system: "跟随系统"
    case .light: "纸白"
    case .sepia: "米黄"
    case .dark: "深夜"
    }
  }

  var backgroundColor: Color {
    switch self {
    case .system:
      wbDynamicColor(
        light: (0.988, 0.980, 0.963, 1),
        dark: (0.104, 0.100, 0.096, 1)
      )
    case .light: Color(red: 0.988, green: 0.980, blue: 0.963)
    case .sepia: Color(red: 0.949, green: 0.914, blue: 0.835)
    case .dark: Color(red: 0.104, green: 0.100, blue: 0.096)
    }
  }

  var foregroundColor: Color {
    switch self {
    case .system: Color.primary
    case .light: Color(red: 0.125, green: 0.118, blue: 0.106)
    case .sepia: Color(red: 0.212, green: 0.165, blue: 0.102)
    case .dark: Color(red: 0.835, green: 0.812, blue: 0.773)
    }
  }

  var chromeColor: Color {
    switch self {
    case .system: Color.primary.opacity(0.025)
    case .light: Color(red: 0.960, green: 0.951, blue: 0.933)
    case .sepia: Color(red: 0.906, green: 0.855, blue: 0.745)
    case .dark: Color(red: 0.145, green: 0.140, blue: 0.134)
    }
  }

  var sidebarColor: Color {
    switch self {
    case .system: Color.primary.opacity(0.035)
    case .light: Color(red: 0.969, green: 0.961, blue: 0.943)
    case .sepia: Color(red: 0.925, green: 0.878, blue: 0.780)
    case .dark: Color(red: 0.126, green: 0.122, blue: 0.117)
    }
  }

  var fieldColor: Color {
    switch self {
    case .system: Color.primary.opacity(0.055)
    case .light: Color.black.opacity(0.045)
    case .sepia: Color(red: 0.30, green: 0.22, blue: 0.12).opacity(0.08)
    case .dark: Color.white.opacity(0.07)
    }
  }

  var separatorColor: Color {
    switch self {
    case .system: Color.primary.opacity(0.10)
    case .light: Color.black.opacity(0.08)
    case .sepia: Color(red: 0.30, green: 0.22, blue: 0.12).opacity(0.14)
    case .dark: Color.white.opacity(0.10)
    }
  }

  var accentColor: Color {
    switch self {
    case .system:
      wbDynamicColor(
        light: (0.52, 0.36, 0.18, 1),
        dark: (0.847, 0.694, 0.451, 1)
      )
    case .light: Color(red: 0.38, green: 0.34, blue: 0.76)
    case .sepia: Color(red: 0.52, green: 0.33, blue: 0.15)
    case .dark: Color(red: 0.86, green: 0.67, blue: 0.41)
    }
  }

  var selectionColor: Color {
    accentColor.opacity(self == .dark ? 0.22 : 0.14)
  }

  var swatchColor: Color {
    switch self {
    case .system: backgroundColor
    case .light: backgroundColor
    case .sepia: backgroundColor
    case .dark: Color(red: 0.145, green: 0.140, blue: 0.134)
    }
  }

  var usesDarkInterface: Bool {
    self == .dark
  }
}

// Keep the presentation's system appearance before the application overrides its
// subtree. A system-themed reader must not inherit the application's fixed dark.
private struct WBReaderSystemSchemeKey: EnvironmentKey {
  static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
  var wbReaderSystemScheme: ColorScheme? {
    get { self[WBReaderSystemSchemeKey.self] }
    set { self[WBReaderSystemSchemeKey.self] = newValue }
  }
}

extension ReaderTheme {
  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light, .sepia: .light
    case .dark: .dark
    }
  }
}

struct WBApplicationAppearance: ViewModifier {
  var readerTheme: ReaderTheme?
  @Environment(\.colorScheme) private var systemScheme

  private var presentationScheme: ColorScheme? {
    if let readerTheme { return readerTheme.preferredColorScheme }
    return .dark
  }

  func body(content: Content) -> some View {
    content
      .environment(\.wbReaderSystemScheme, systemScheme)
      .environment(\.colorScheme, .dark)
      .tint(Color.wbAccent)
      // Also style native presentation chrome. Returning nil for the system
      // reader removes the preference so its parent again follows the OS.
      .preferredColorScheme(presentationScheme)
  }
}

private struct WBReaderAppearance: ViewModifier {
  let theme: ReaderTheme
  @Environment(\.colorScheme) private var inheritedScheme
  @Environment(\.wbReaderSystemScheme) private var systemScheme

  func body(content: Content) -> some View {
    content.environment(\.colorScheme, theme.preferredColorScheme ?? systemScheme ?? inheritedScheme)
  }
}

extension View {
  func readerColorScheme(_ theme: ReaderTheme) -> some View {
    modifier(WBReaderAppearance(theme: theme))
  }
}
