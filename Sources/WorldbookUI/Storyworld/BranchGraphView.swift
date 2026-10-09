import StoryworldCore
import SwiftUI

/// 分支图的画布部分：泳道布局 + 平移缩放 + 当前路径高亮。
/// 数据全部来自 `StoryBranchGraph`，交互通过回调交给上层。
struct BranchGraphView: View {
  let graph: StoryBranchGraph
  var onActivateBranch: (StoryBranchGraph.Node) -> Void
  var onRestoreSave: (StorySave) -> Void
  var onForkAtEvent: (StoryBranchGraph.Node, StoryBranchGraph.TurnMarker, String) -> Void
  var onSaveAtEvent: (StoryBranchGraph.Node, StoryBranchGraph.TurnMarker, String) -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var scale: CGFloat = 1
  @State private var lastScale: CGFloat = 1
  @State private var hasCustomZoom = false
  @State private var isMagnifying = false
  @State private var viewport: CGSize = .zero
  @State private var pendingSave: StorySave?
  @State private var selectedTurn: TurnSelection?
  @State private var actionKind: ActionKind?
  @State private var actionTitle = ""
  @State private var isPulsing = false
  @State private var selectedBeat: StoryBeat?

  private struct TurnSelection: Equatable {
    let node: StoryBranchGraph.Node
    let marker: StoryBranchGraph.TurnMarker
  }

  private enum ActionKind: String {
    case fork = "从这里切出分支"
    case save = "存为存档"
  }

  /// 左侧泳道标签栏宽：窄屏收紧，给小图留出更多适配空间
  private var gutter: CGFloat { horizontalSizeClass == .compact ? 108 : 148 }
  private let baseUnit: CGFloat = 46
  private let baseLaneHeight: CGFloat = 96
  private let topPadding: CGFloat = 56
  private let connectorDx: CGFloat = 30

  private var fontScale: CGFloat { min(max(scale, 0.9), 1.3) }

  private var beats: [StoryBeat] { graph.timeline?.beats ?? [] }
  private var hasTimeline: Bool { !beats.isEmpty }
  /// 原著线泳道占用的高度，无时为零
  private func railHeight(_ s: CGFloat) -> CGFloat { hasTimeline ? 76 * s : 0 }

  /// 原著系文字用的深金色，比 wbGold 在浅底上更清晰
  private var goldText: Color { Color(red: 0.55, green: 0.40, blue: 0.12) }

  // MARK: - 坐标换算（参数化缩放，便于计算适配比例）

  private func x(_ sequence: Int, scale s: CGFloat) -> CGFloat {
    gutter + CGFloat(sequence) * baseUnit * s
  }

  private func y(_ lane: Int, scale s: CGFloat) -> CGFloat {
    topPadding + railHeight(s) + CGFloat(lane) * baseLaneHeight * s
  }

  /// 节拍在原著线上的横坐标：与事件轴同宽均匀分布，但保证标题放得下
  private func beatX(_ index: Int, scale s: CGFloat) -> CGFloat {
    let usable = x(max(graph.maxAbsoluteSequence, 1), scale: s) - gutter + 60 * s
    let beatUnit = max(usable / CGFloat(beats.count + 1), 64 * s)
    return gutter + CGFloat(index + 1) * beatUnit
  }

  private func x(_ sequence: Int) -> CGFloat { x(sequence, scale: scale) }
  private func y(_ lane: Int) -> CGFloat { y(lane, scale: scale) }
  private func beatX(_ index: Int) -> CGFloat { beatX(index, scale: scale) }

  /// 低缩放/窄屏时抽稀标题，圆点仍全部保留；点圆点可查看完整标题与摘要。
  private var beatTitleStride: Int {
    guard beats.count > 1 else { return 1 }
    let spacing = max(beatX(1) - beatX(0), 1)
    let required = 96 * scale + 10
    return max(1, Int(ceil(required / spacing)))
  }

  private func laneStartX(_ node: StoryBranchGraph.Node) -> CGFloat {
    x(node.startAbsoluteSequence) + (node.parentBranchID == nil ? 0 : connectorDx * scale)
  }

  private func headX(_ node: StoryBranchGraph.Node) -> CGFloat {
    node.headEventSequence == 0 ? laneStartX(node) : x(node.endAbsoluteSequence)
  }

  private func canvasSize(scale s: CGFloat) -> CGSize {
    CGSize(
      width: max(
        x(graph.maxAbsoluteSequence, scale: s) + 140 * s,
        hasTimeline ? beatX(max(beats.count - 1, 0), scale: s) + 100 * s : 0
      ),
      height: y(max(graph.nodes.count - 1, 0), scale: s) + 110 * s
    )
  }

  private var canvasSize: CGSize { canvasSize(scale: scale) }

  /// 让整张图完整落入给定视口的缩放比。小图允许放大（上限 160%）填充视口，
  /// 避免分支少时内容缩在左上角、文字过小。
  /// 注意画布尺寸不是线性的：宽 = gutter + s·W′，高 = topPadding + s·H′，常数项不随缩放。
  private func fitScale(for size: CGSize) -> CGFloat {
    guard size.width > 0, size.height > 0 else { return 1 }
    let base = canvasSize(scale: 1)
    let wPrime = max(base.width - gutter, 1)
    let hPrime = max(base.height - topPadding, 1)
    let sW = (size.width - 12 - gutter) / wPrime
    let sH = (size.height - 12 - topPadding) / hPrime
    return min(max(min(sW, sH), 0.45), 1.6)
  }

  private var fitScale: CGFloat { fitScale(for: viewport) }

  /// 图内容变化时触发重新适配的签名
  private var graphSignature: String {
    "\(graph.nodes.count)-\(graph.maxAbsoluteSequence)-\(beats.count)"
  }

  var body: some View {
    GeometryReader { geo in
      ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical]) {
          canvas
            .frame(width: canvasSize.width, height: canvasSize.height)
            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
        }
        .scrollDisabled(isMagnifying)
        .simultaneousGesture(
          MagnifyGesture()
            .onChanged { value in
              isMagnifying = true
              hasCustomZoom = true
              scale = min(max(lastScale * value.magnification, 0.45), 2.2)
            }
            .onEnded { _ in
              lastScale = scale
              isMagnifying = false
            }
        )
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .topLeading) {
          if horizontalSizeClass != .compact { legend }
        }
        .overlay {
          if selectedTurn != nil {
            Color.black.opacity(0.001)
              .contentShape(Rectangle())
              .onTapGesture {
                withAnimation(WBMotion.snappy) { selectedTurn = nil }
              }
          }
        }
        .overlay(alignment: .bottom) {
          if let selection = selectedTurn {
            turnCard(selection)
          }
        }
        .onAppear {
          viewport = geo.size
          let fit = fitScale(for: geo.size)
          scale = fit
          lastScale = fit
          isPulsing = true
          // 只有适配后仍放不下的超大图，才需要滚动定位到活跃头
          let fitted = canvasSize(scale: fit)
          if fitted.width > geo.size.width || fitted.height > geo.size.height {
            scrollToActiveHead(proxy, animated: false)
          }
        }
        .onChange(of: geo.size) { _, newSize in
          viewport = newSize
          if !hasCustomZoom {
            scale = fitScale
            lastScale = scale
          }
        }
        .onChange(of: graphSignature) { _, _ in
          guard !hasCustomZoom else { return }
          withAnimation(WBMotion.gentle) {
            scale = fitScale
            lastScale = scale
          }
        }
        .onChange(of: graph.activeBranchID) { _, _ in
          // 已适配全图时无需滚动；仅在用户手动放大后跟随活跃头
          if hasCustomZoom {
            scrollToActiveHead(proxy, animated: true)
          }
        }
      }
    }
    .animation(WBMotion.snappy, value: selectedTurn)
    .alert(
      actionKind?.rawValue ?? "",
      isPresented: Binding(
        get: { actionKind != nil },
        set: { if !$0 { actionKind = nil } }
      )
    ) {
      TextField("名称", text: $actionTitle)
      Button("确定") {
        if let kind = actionKind, let selection = selectedTurn {
          switch kind {
          case .fork:
            onForkAtEvent(selection.node, selection.marker, actionTitle)
          case .save:
            onSaveAtEvent(selection.node, selection.marker, actionTitle)
          }
        }
        actionKind = nil
        actionTitle = ""
        selectedTurn = nil
      }
      Button("取消", role: .cancel) {
        actionKind = nil
        actionTitle = ""
      }
    }
    .confirmationDialog(
      "从存档建立分支",
      isPresented: Binding(
        get: { pendingSave != nil },
        set: { if !$0 { pendingSave = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let save = pendingSave {
        Button("从「\(save.title)」建立分支") {
          onRestoreSave(save)
          pendingSave = nil
        }
      }
      Button("取消", role: .cancel) { pendingSave = nil }
    } message: {
      if let save = pendingSave {
        Text("将从事件 \(save.eventSequence) 处切出一条新分支，现有进度不受影响。")
      }
    }
    .alert(
      selectedBeat?.title ?? "原著节拍",
      isPresented: Binding(
        get: { selectedBeat != nil },
        set: { if !$0 { selectedBeat = nil } }
      )
    ) {
      Button("好") { selectedBeat = nil }
    } message: {
      Text(selectedBeat?.summary ?? "")
    }
  }

  // MARK: - 画布

  private var canvas: some View {
    ZStack(alignment: .topLeading) {
      if hasTimeline { beatRail }
      gridLayer
      lineLayer
      ForEach(graph.nodes) { node in
        laneLabel(node)
        if node.parentBranchID == nil {
          startDot(node)
        }
        if node.parentBranchID != nil, let parent = graph.node(branchID: node.parentBranchID!) {
          forkDot(child: node, parent: parent)
        }
        ForEach(node.saves) { marker in
          saveMarker(marker, on: node)
        }
        ForEach(node.turns) { marker in
          turnDot(marker, on: node)
        }
        headNode(node)
      }
    }
  }

  /// 事件刻度：每 5 个事件一条竖向虚线；泳道之间一条细分隔线
  private var gridLayer: some View {
    let maxSeq = graph.maxAbsoluteSequence
    let ticks = stride(from: 0, through: max(maxSeq, 5), by: 5).map { $0 }
    let gridTop = topPadding + railHeight(scale) - 20 * scale
    let laneCount = max(graph.nodes.count, 1)
    return Canvas { context, _ in
      for tick in ticks {
        var line = Path()
        line.move(to: CGPoint(x: x(tick), y: gridTop))
        line.addLine(to: CGPoint(x: x(tick), y: canvasSize.height - 40 * scale))
        context.stroke(
          line,
          with: .color(.secondary.opacity(0.10)),
          style: StrokeStyle(lineWidth: 0.5, dash: [3, 5])
        )
      }
      for lane in 0..<laneCount {
        let sepY = y(lane) + baseLaneHeight * scale / 2
        var sep = Path()
        sep.move(to: CGPoint(x: 0, y: sepY))
        sep.addLine(to: CGPoint(x: canvasSize.width, y: sepY))
        context.stroke(
          sep,
          with: .color(.secondary.opacity(0.08)),
          style: StrokeStyle(lineWidth: 0.5)
        )
      }
    }
  }

  /// 原著线：一条浅金轨道横贯顶部，节拍按顺序排布；
  /// 当前路径到过的节拍实心高亮，下一个未到的节拍用描边环提示，其余压暗。
  private var beatRail: some View {
    let reached = graph.reachedBeatIDsOnActivePath
    let nextBeatID = beats.first { !reached.contains($0.id) }?.id
    let circleY = topPadding - 2 * scale
    let bandHeight = 58 * scale
    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
        .fill(Color.wbGold.opacity(0.08))
        .overlay {
          RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
            .strokeBorder(Color.wbGold.opacity(0.18), lineWidth: 1)
        }
        .frame(width: canvasSize.width - 16, height: bandHeight)
        .offset(x: 8, y: circleY - 20 * scale)
      Canvas { context, _ in
        var line = Path()
        for (index, _) in beats.enumerated() {
          let point = CGPoint(x: beatX(index), y: circleY)
          if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(
          line,
          with: .color(.wbGold.opacity(0.5)),
          style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
      }
      Text("原著线")
        .font(.system(size: 10.5 * fontScale, weight: .bold, design: .serif))
        .foregroundStyle(goldText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.wbGold.opacity(0.16)))
        .offset(x: 20, y: circleY - 7 * scale)
      ForEach(Array(beats.enumerated()), id: \.element.id) { index, beat in
        let isReached = reached.contains(beat.id)
        let isNext = beat.id == nextBeatID
        VStack(spacing: 2) {
          Circle()
            .fill(isReached ? Color.wbGold : Color.clear)
            .frame(width: 12 * scale, height: 12 * scale)
            .overlay {
              Circle()
                .strokeBorder(
                  isReached ? Color.white.opacity(0.7)
                    : isNext ? Color.wbGold
                    : Color.secondary.opacity(0.45),
                  lineWidth: isNext ? 2 : 1.2
                )
            }
            .shadow(color: isReached ? Color.wbGold.opacity(0.4) : .clear, radius: 4)
          if index % beatTitleStride == 0 || beats.count == 1 {
            Text(beat.title)
              .font(.system(size: 10 * fontScale, weight: isReached ? .semibold : .regular))
              .foregroundStyle(isReached ? .primary : .secondary)
              .lineLimit(2)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 88 * scale)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedBeat = beat }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("原著节拍：\(beat.title)")
        .accessibilityHint("点按查看完整摘要")
        .opacity(isReached || isNext ? 1 : 0.55)
        .position(x: beatX(index), y: circleY + 13 * scale)
        .help("\(beat.title)：\(beat.summary)")
      }
    }
  }

  /// 泳道主线 + 分叉肘线（水平—竖直—水平，转角小圆角）
  private var lineLayer: some View {
    Canvas { context, _ in
      for node in graph.nodes {
        let laneY = y(node.lane)
        let active = node.isOnActivePath
        let color: Color = active ? .wbIndigo : .secondary
        let startX = laneStartX(node)
        let endX = max(x(node.endAbsoluteSequence), startX)

        if let parentID = node.parentBranchID, let parent = graph.node(branchID: parentID) {
          let forkX = x(node.startAbsoluteSequence)
          let parentY = y(parent.lane)
          let corner = min(10 * scale, abs(laneY - parentY) / 2)
          let dir: CGFloat = laneY >= parentY ? 1 : -1
          let dropX = forkX + max(connectorDx * scale * 0.5, corner + 2)
          var connector = Path()
          connector.move(to: CGPoint(x: forkX, y: parentY))
          connector.addLine(to: CGPoint(x: dropX - corner, y: parentY))
          connector.addQuadCurve(
            to: CGPoint(x: dropX, y: parentY + dir * corner),
            control: CGPoint(x: dropX, y: parentY)
          )
          connector.addLine(to: CGPoint(x: dropX, y: laneY - dir * corner))
          connector.addQuadCurve(
            to: CGPoint(x: dropX + corner, y: laneY),
            control: CGPoint(x: dropX, y: laneY)
          )
          connector.addLine(to: CGPoint(x: startX, y: laneY))
          context.stroke(
            connector,
            with: .color(color.opacity(active ? 0.8 : 0.5)),
            style: StrokeStyle(lineWidth: active ? 2.2 : 1.8, lineCap: .round, lineJoin: .round)
          )
        }

        var lane = Path()
        lane.move(to: CGPoint(x: startX, y: laneY))
        lane.addLine(to: CGPoint(x: endX, y: laneY))
        if active {
          context.stroke(
            lane,
            with: .color(color.opacity(0.18)),
            style: StrokeStyle(lineWidth: 8, lineCap: .round)
          )
          context.stroke(
            lane,
            with: .color(color.opacity(0.95)),
            style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
          )
        } else {
          context.stroke(
            lane,
            with: .color(color.opacity(0.5)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
          )
        }
      }
    }
  }

  private func laneLabel(_ node: StoryBranchGraph.Node) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(node.title)
          .font(.system(size: 13 * fontScale, weight: .semibold, design: .serif))
          .lineLimit(1)
        if node.isActive {
          Text("当前")
            .font(.system(size: 10 * fontScale, weight: .bold))
            .foregroundStyle(Color.wbIndigo)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.wbIndigo.opacity(0.14), in: Capsule())
        }
      }
      Text("\(node.headEventSequence) 回合 · 始于事件 \(node.startAbsoluteSequence)")
        .font(.system(size: 10.5 * fontScale))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(width: gutter - 18, alignment: .leading)
    .offset(x: 10, y: y(node.lane) - 34 * scale)
    .opacity(node.isOnActivePath ? 1 : 0.75)
  }

  private func startDot(_ node: StoryBranchGraph.Node) -> some View {
    Circle()
      .fill(Color.wbGold)
      .frame(width: 9, height: 9)
      .overlay {
        Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
      }
      .position(x: x(0), y: y(node.lane))
      .help("起点")
  }

  /// 分叉点：与连线同色的实心小圆，不再用独立色块
  private func forkDot(child: StoryBranchGraph.Node, parent: StoryBranchGraph.Node) -> some View {
    Circle()
      .fill(child.isOnActivePath ? Color.wbIndigo : Color.secondary.opacity(0.7))
      .frame(width: 8 * scale, height: 8 * scale)
      .overlay {
        Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
      }
      .position(x: x(child.startAbsoluteSequence), y: y(parent.lane))
      .help("「\(child.title)」在此分叉")
  }

  private func saveMarker(_ marker: StoryBranchGraph.SaveMarker, on node: StoryBranchGraph.Node) -> some View {
    Button {
      pendingSave = marker.save
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "bookmark.fill")
          .font(.system(size: 9 * fontScale, weight: .semibold))
        Text(marker.save.title)
          .font(.system(size: 10.5 * fontScale, weight: .medium))
          .lineLimit(1)
      }
      .foregroundStyle(goldText)
      .padding(.horizontal, 8 * scale)
      .padding(.vertical, 4 * scale)
      .background {
        Capsule()
          .fill(Color.wbGold.opacity(0.14))
          .overlay {
            Capsule().strokeBorder(Color.wbGold.opacity(0.35), lineWidth: 0.5)
          }
          .shadow(color: Color.wbGold.opacity(0.25), radius: 3, y: 1)
      }
    }
    .buttonStyle(.plain)
    .position(x: x(marker.absoluteSequence), y: y(node.lane) + 18 * scale)
    .help("存档「\(marker.save.title)」，点按可从此建立分支")
  }

  private func headNode(_ node: StoryBranchGraph.Node) -> some View {
    let diameter: CGFloat = (node.isActive ? 20 : 15) * scale
    return Button {
      if node.isActive {
        // 活跃分支的头就是最后一回合，点按直接打开该回合的操作卡
        if let last = node.turns.last {
          withAnimation(WBMotion.snappy) {
            selectedTurn = TurnSelection(node: node, marker: last)
          }
        }
      } else {
        onActivateBranch(node)
      }
    } label: {
      ZStack {
        if node.isActive {
          Circle()
            .strokeBorder(Color.wbIndigo.opacity(0.5), lineWidth: 1.5)
            .scaleEffect(isPulsing ? 1.9 : 1)
            .opacity(isPulsing ? 0 : 0.8)
            .animation(
              // 不能用 repeatForever：无限动画会让 AttributeGraph 每帧都有新事务，
              // 在 macOS 26 上已知会把 SwiftUI 拖进布局失效死循环（主线程 99% 空转）。
              // 脉冲几次后自然停止，静止态即脉冲扩散后的透明环，视觉不变。
              .easeOut(duration: 1.6).repeatCount(3, autoreverses: false),
              value: isPulsing
            )
        }
        Circle()
          .fill(
            node.isActive
              ? LinearGradient(colors: [.wbIndigo, .wbViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
              : LinearGradient(colors: [.secondary.opacity(0.55), .secondary.opacity(0.35)], startPoint: .top, endPoint: .bottom)
          )
          .overlay {
            Circle().strokeBorder(Color.white.opacity(node.isActive ? 0.55 : 0.3), lineWidth: 1)
          }
          .shadow(
            color: node.isActive ? Color.wbIndigo.opacity(0.45) : .clear,
            radius: node.isActive ? 7 : 0,
            y: node.isActive ? 2 : 0
          )
      }
      .frame(width: diameter, height: diameter)
    }
    .buttonStyle(.plain)
    .position(x: headX(node), y: y(node.lane))
    .id("head-\(node.id.uuidString)")
    .help(node.isActive ? "当前位置，点按查看本回合操作" : "切换到「\(node.title)」")
  }

  /// 回合节点：点按弹出操作卡（预览 + 从此分叉/存档）；落在节拍上的回合带金环
  private func turnDot(_ marker: StoryBranchGraph.TurnMarker, on node: StoryBranchGraph.Node) -> some View {
    let isSelected = selectedTurn?.marker.id == marker.id
    let active = node.isOnActivePath
    let diameter: CGFloat = (isSelected ? 12 : active ? 9 : 7.5) * scale
    return Button {
      withAnimation(WBMotion.snappy) {
        selectedTurn = TurnSelection(node: node, marker: marker)
      }
    } label: {
      Circle()
        .fill(active ? Color.wbIndigo : Color.secondary.opacity(0.6))
        .frame(width: diameter, height: diameter)
        .overlay {
          Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
        }
        .overlay {
          if marker.beatID != nil {
            Circle()
              .strokeBorder(Color.wbGold, lineWidth: 1.8)
              .frame(width: diameter + 5 * scale, height: diameter + 5 * scale)
          }
        }
        .shadow(
          color: active ? Color.wbIndigo.opacity(0.35) : .clear,
          radius: isSelected ? 5 : 2
        )
    }
    .buttonStyle(.plain)
    .position(x: x(marker.absoluteSequence), y: y(node.lane))
    .help("事件 \(marker.absoluteSequence)：\(marker.preview)")
  }

  /// 回合操作卡：预览该回合，可从任意历史事件切分支或存档
  private func turnCard(_ selection: TurnSelection) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text("事件 \(selection.marker.absoluteSequence) · \(selection.node.title)")
            .font(.system(.subheadline, design: .serif, weight: .semibold))
          Text(selection.marker.preview.isEmpty ? "（这一回合没有文字预览）" : selection.marker.preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 8)
        Button {
          withAnimation(WBMotion.snappy) { selectedTurn = nil }
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(WBChromeButtonStyle())
      }
      HStack(spacing: 9) {
        Button("从这里切出分支") {
          actionKind = .fork
          actionTitle = "从事件 \(selection.marker.absoluteSequence) 继续"
        }
        .buttonStyle(WBChipButtonStyle(isActive: true))
        Button("存为存档") {
          actionKind = .save
          actionTitle = "事件 \(selection.marker.absoluteSequence) 存档"
        }
        .buttonStyle(WBChipButtonStyle())
      }
    }
    .padding(14)
    .frame(maxWidth: 340)
    .wbGlassPanel(cornerRadius: 16, shadowOpacity: 0.12)
    .padding(.horizontal, 16)
    .padding(.bottom, 18)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  // MARK: - 浮层

  private var zoomControls: some View {
    HStack(spacing: 2) {
      Button {
        zoom(to: scale - 0.2)
      } label: {
        Image(systemName: "minus")
      }
      .buttonStyle(WBChromeButtonStyle())
      Button {
        zoom(to: scale + 0.2)
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(WBChromeButtonStyle())
      Button {
        hasCustomZoom = false
        withAnimation(WBMotion.snappy) {
          scale = fitScale
          lastScale = scale
        }
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
      }
      .buttonStyle(WBChromeButtonStyle())
    }
    .padding(4)
    .wbGlassPanel(cornerRadius: 12, shadowOpacity: 0.06)
    .padding(12)
    .opacity(0.92)
  }

  private func zoom(to newValue: CGFloat) {
    hasCustomZoom = true
    withAnimation(WBMotion.snappy) {
      scale = min(max(newValue, 0.45), 2.2)
      lastScale = scale
    }
  }

  private var legend: some View {
    HStack(spacing: 14) {
      legendItem(symbol: "circle.fill", color: .wbIndigo, text: "分支头")
      legendItem(symbol: "circle.fill", color: .secondary, text: "分叉点")
      legendItem(symbol: "bookmark.fill", color: .wbGold, text: "存档")
      if hasTimeline {
        legendItem(symbol: "circlebadge.fill", color: .wbGold, text: "已到节拍")
      }
      Text("高亮泳道 = 当前路径")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .wbGlassPanel(cornerRadius: 10, shadowOpacity: 0.05)
    .padding(12)
  }

  private func legendItem(symbol: String, color: Color, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol)
        .font(.system(size: 8))
        .foregroundStyle(color)
      Text(text)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func scrollToActiveHead(_ proxy: ScrollViewProxy, animated: Bool) {
    guard let activeID = graph.activeBranchID else { return }
    let target = "head-\(activeID.uuidString)"
    if animated {
      withAnimation(WBMotion.gentle) { proxy.scrollTo(target, anchor: .center) }
    } else {
      proxy.scrollTo(target, anchor: .center)
    }
  }
}

/// 分支图页面容器：处理空态并负责在出现时刷新图数据。
struct BranchGraphContainerView: View {
  @ObservedObject var model: StorySessionViewModel

  var body: some View {
    ZStack {
      WBAmbientScenery()
      if model.snapshot == nil {
        WBEmptyStateView(
          title: "还没有正在使用的游玩线",
          symbol: "point.3.connected.trianglepath.dotted",
          message: "先从“会话”进入一个 Storyworld，开始游玩后即可查看分支图。",
          gradient: LinearGradient(
            colors: [.wbTeal, .wbIndigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
      } else if let graph = model.branchGraph, !graph.nodes.isEmpty {
        BranchGraphView(
          graph: graph,
          onActivateBranch: { node in
            Task { await model.activateBranch(node.id) }
          },
          onRestoreSave: { save in
            Task { await model.restoreSaveFromGraph(save) }
          },
          onForkAtEvent: { node, marker, title in
            Task { await model.forkBranchAtEvent(node: node, sequence: marker.sequence, title: title) }
          },
          onSaveAtEvent: { node, marker, title in
            Task { await model.createSaveAtEvent(node: node, sequence: marker.sequence, title: title) }
          }
        )
      } else {
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { await model.refreshBranchGraph() }
    .alert(
      "操作未完成",
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
