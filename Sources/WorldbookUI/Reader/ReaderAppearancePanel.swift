import LibraryCore
import SwiftUI

// MARK: - 排版与主题面板

struct ReaderAppearancePanel: View {
  let record: NovelLibraryRecord
  @ObservedObject var model: LibraryViewModel
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var preferences: ReaderPreferences {
    record.readerState.preferences
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("排版与页面")
        .font(.system(.headline, design: .serif))

      VStack(alignment: .leading, spacing: 8) {
        Text("阅读方式")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Picker(
          "阅读方式",
          selection: Binding(
            get: { preferences.flow },
            set: { model.setReaderFlow($0, in: record.id) }
          )
        ) {
          ForEach(ReaderFlow.allCases, id: \.self) { flow in
            Text(flow.title).tag(flow)
          }
        }
        .pickerStyle(.segmented)
      }

      // 字号
      panelSection(title: "字号", value: "\(Int(preferences.fontSize))") {
        StepperControl(
          decrease: { model.adjustFontSize(by: -1, in: record.id) },
          increase: { model.adjustFontSize(by: 1, in: record.id) },
          decreaseSymbol: "textformat.size.smaller",
          increaseSymbol: "textformat.size.larger"
        )
      }

      // 行距
      panelSection(title: "行距", value: "\(Int(preferences.lineSpacing))") {
        StepperControl(
          decrease: { model.adjustLineSpacing(by: -1, in: record.id) },
          increase: { model.adjustLineSpacing(by: 1, in: record.id) },
          decreaseSymbol: "arrow.up.and.line.horizontal.and.arrow.down",
          increaseSymbol: "arrow.down.and.line.horizontal.and.arrow.up",
          decreaseLabel: "紧凑",
          increaseLabel: "宽松"
        )
      }

      // 正文宽度（仅宽屏有意义，手机屏宽恒小于最小宽度）
      if horizontalSizeClass != .compact {
        VStack(alignment: .leading, spacing: 9) {
          HStack {
            Text("正文宽度")
            Spacer()
            Text("\(Int(preferences.contentWidth)) px")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          .font(.caption.weight(.medium))

          Slider(
            value: Binding(
              get: { preferences.contentWidth },
              set: { model.setContentWidth($0, in: record.id) }
            ),
            in: 480...1_400,
            step: 20
          )

          HStack(spacing: 6) {
            widthPreset("窄", 640)
            widthPreset("标准", 920)
            widthPreset("宽", 1_100)
            widthPreset("铺开", 1_400)
          }
        }
      }

      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(height: 0.5)

      // 主题
      VStack(alignment: .leading, spacing: 10) {
        Text("阅读主题")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          ForEach(ReaderTheme.allCases, id: \.self) { theme in
            ThemeSwatch(
              theme: theme,
              isSelected: theme == preferences.theme
            ) {
              model.setTheme(theme, in: record.id)
            }
          }
        }
      }
    }
    .padding(20)
    .modify { view in
      if horizontalSizeClass == .compact {
        view.frame(maxWidth: .infinity, alignment: .leading)
      } else {
        view.frame(width: 336)
      }
    }
  }

  private func panelSection<Control: View>(
    title: String,
    value: String,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack {
      Text(title)
        .font(.caption.weight(.medium))
      Text(value)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Spacer()
      control()
    }
  }

  private func widthPreset(_ title: String, _ width: Double) -> some View {
    let isActive = abs(preferences.contentWidth - width) < 1
    return Button(title) {
      model.setContentWidth(width, in: record.id)
    }
    .buttonStyle(.plain)
    .font(.caption2.weight(.medium))
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background {
      Capsule()
        .fill(isActive ? preferences.theme.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
    }
    .foregroundStyle(isActive ? preferences.theme.accentColor : Color.secondary)
    .animation(WBMotion.snappy, value: isActive)
  }
}

// MARK: - 步进器

private struct StepperControl: View {
  let decrease: () -> Void
  let increase: () -> Void
  var decreaseSymbol: String
  var increaseSymbol: String
  var decreaseLabel: String?
  var increaseLabel: String?

  var body: some View {
    HStack(spacing: 0) {
      Button(action: decrease) {
        stepContent(symbol: decreaseSymbol, label: decreaseLabel)
      }
      .buttonStyle(WBChromeButtonStyle())
      Rectangle()
        .fill(Color.primary.opacity(0.10))
        .frame(width: 0.5, height: 16)
      Button(action: increase) {
        stepContent(symbol: increaseSymbol, label: increaseLabel)
      }
      .buttonStyle(WBChromeButtonStyle())
    }
    .background(Color.primary.opacity(0.05), in: Capsule())
  }

  @ViewBuilder
  private func stepContent(symbol: String, label: String?) -> some View {
    if let label {
      Text(label)
        .font(.caption2.weight(.medium))
        .frame(minWidth: 34)
    } else {
      Image(systemName: symbol)
        .font(.caption.weight(.medium))
        .frame(minWidth: 30)
    }
  }
}

// MARK: - 主题小样

private struct ThemeSwatch: View {
  let theme: ReaderTheme
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(spacing: 6) {
        ZStack(alignment: .topTrailing) {
          // 迷你书页
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(theme.swatchColor)
            .overlay {
              VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(theme.foregroundColor.opacity(0.55)).frame(width: 30, height: 3)
                Capsule().fill(theme.foregroundColor.opacity(0.32)).frame(width: 40, height: 3)
                Capsule().fill(theme.foregroundColor.opacity(0.18)).frame(width: 24, height: 3)
              }
              .padding(.horizontal, 8)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .overlay {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                  isSelected ? theme.accentColor : Color.primary.opacity(0.12),
                  lineWidth: isSelected ? 1.6 : 0.5
                )
            }
            .frame(width: 58, height: 44)

          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 15))
              .foregroundStyle(theme.accentColor, Color.wbCanvas)
              .offset(x: 5, y: -5)
              .transition(.scale(scale: 0.4).combined(with: .opacity))
          }
        }

        Text(theme.title)
          .font(.caption2)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(WBPressableButtonStyle(pressedScale: 0.93))
    .animation(WBMotion.bouncy, value: isSelected)
  }
}
