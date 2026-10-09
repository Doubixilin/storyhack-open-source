import Foundation
import LLMProviderKit
import StoryworldCore

public enum EndingReportWorkflowError: Error, LocalizedError, Equatable {
  case providerUnavailable

  public var errorDescription: String? {
    switch self {
    case .providerUnavailable: "请先添加并选择模型，再生成终局判词。"
    }
  }
}

public enum EndingReportWorkflowEvent: Equatable, Sendable {
  case statistics(EndingReportStatistics, lines: [String])
  case resetVerdict
  case textDelta(String)
  case completed(StoryEndingReport, reusedExisting: Bool)
}

public struct EndingReportWorkflow: Sendable {
  private let orator: EndingOrator

  public init(orator: EndingOrator = EndingOrator()) {
    self.orator = orator
  }

  /// 旧报告优先返回且不触发 provider；明确 regenerate 才重新请求，单次失败后最多再试一次。
  public func open(
    provider: (any LLMProvider)?,
    runtime: StoryworldRuntimeStore,
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot,
    branchGraph: StoryBranchGraph,
    regenerate: Bool = false
  ) -> AsyncThrowingStream<EndingReportWorkflowEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          if !regenerate,
            let existing = try await runtime.loadEndingReport(address: snapshot.context.address)
          {
            continuation.yield(
              .statistics(existing.statistics, lines: existing.statisticLines)
            )
            continuation.yield(.completed(existing, reusedExisting: true))
            continuation.finish()
            return
          }

          let allSaves = branchGraph.nodes.flatMap { $0.saves.map(\.save) }
          let statistics = EndingReportBuilder.build(
            effectiveTurns: snapshot.effectiveTurns,
            branchGraph: branchGraph,
            saves: allSaves
          )
          let lines = await EndingReportBuilder.renderedStatisticLines(statistics: statistics)
          continuation.yield(.statistics(statistics, lines: lines))
          guard let provider else { throw EndingReportWorkflowError.providerUnavailable }

          var lastError: (any Error)?
          for attempt in 0..<2 {
            do {
              continuation.yield(.resetVerdict)
              var verdict = ""
              for try await event in orator.streamVerdict(
                provider: provider,
                storyworld: storyworld,
                snapshot: snapshot
              ) {
                switch event {
                case .textDelta(let delta):
                  verdict += delta
                  continuation.yield(.textDelta(delta))
                case .completed(let completed):
                  verdict = completed
                }
              }
              let report = StoryEndingReport(
                statistics: statistics,
                statisticLines: lines,
                verdict: verdict,
                generatedAtEffectiveTurnCount: snapshot.effectiveTurns.count
              )
              try await runtime.saveEndingReport(report, address: snapshot.context.address)
              continuation.yield(.completed(report, reusedExisting: false))
              continuation.finish()
              return
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              lastError = error
              if attempt == 0 { continue }
            }
          }
          throw lastError ?? EndingOratorError.emptyVerdict
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
