import AVFoundation
import MediaCore
import Testing

@testable import SpeechProviderKit

@MainActor
struct SpeechProviderKitTests {
  @Test
  func systemPauseIsReflectedAndToggleResumesPlayback() async throws {
    let synthesizer = FakeSpeechSynthesizer()
    let player = AppleSpeechPlayer(synthesizer: synthesizer)
    let plan = testPlan()

    player.play(plan: plan)
    let utterance = try #require(synthesizer.lastUtterance)
    synthesizer.isSpeaking = false
    synthesizer.isPaused = true
    player.speechSynthesizer(AVSpeechSynthesizer(), didPause: utterance)
    await Task.yield()

    #expect(player.state == .paused)
    player.toggle(plan: plan)
    #expect(synthesizer.continueCallCount == 1)
    #expect(player.state == .playing)
  }

  @Test
  func stalePlayingStateReturnsToIdleWhenSynthesizerAlreadyEnded() {
    let synthesizer = FakeSpeechSynthesizer()
    let player = AppleSpeechPlayer(synthesizer: synthesizer)
    let plan = testPlan()

    player.play(plan: plan)
    synthesizer.isSpeaking = false
    synthesizer.isPaused = false
    player.toggle(plan: plan)

    #expect(player.state == .idle)
    #expect(player.currentPlanID == nil)
    #expect(synthesizer.pauseCallCount == 0)
  }

  private func testPlan() -> SpeechPlan {
    SpeechPlanBuilder.singleNarrator(
      kind: .publishedChapter,
      sourceID: "chapter-1",
      text: "这是一个不会真正发声的测试章节。"
    )
  }
}

@MainActor
private final class FakeSpeechSynthesizer: SpeechSynthesizing {
  var delegate: (any AVSpeechSynthesizerDelegate)?
  var isSpeaking = false
  var isPaused = false
  var lastUtterance: AVSpeechUtterance?
  var pauseCallCount = 0
  var continueCallCount = 0

  func speak(_ utterance: AVSpeechUtterance) {
    lastUtterance = utterance
    isSpeaking = true
    isPaused = false
  }

  func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
    isSpeaking = false
    isPaused = false
    return true
  }

  func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
    pauseCallCount += 1
    guard isSpeaking else { return false }
    isSpeaking = false
    isPaused = true
    return true
  }

  func continueSpeaking() -> Bool {
    continueCallCount += 1
    guard isPaused else { return false }
    isPaused = false
    isSpeaking = true
    return true
  }
}
