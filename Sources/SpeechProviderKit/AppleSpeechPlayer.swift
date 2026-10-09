import AVFoundation
import Combine
import Foundation
import MediaCore

#if os(iOS)
  import UIKit
#endif

public enum SpeechPlaybackState: Equatable, Sendable {
  case idle
  case playing
  case paused
}

@MainActor
protocol SpeechSynthesizing: AnyObject {
  var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
  var isSpeaking: Bool { get }
  var isPaused: Bool { get }
  func speak(_ utterance: AVSpeechUtterance)
  func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
  func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
  func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}

@MainActor
public final class AppleSpeechPlayer: NSObject, ObservableObject {
  @Published public private(set) var state: SpeechPlaybackState = .idle
  @Published public private(set) var currentPlanID: String?
  @Published public private(set) var location: SpeechPlaybackLocation?
  @Published public private(set) var errorMessage: String?

  private let synthesizer: any SpeechSynthesizing
  private var plan: SpeechPlan?
  private var currentUtterance: AVSpeechUtterance?

  public override init() {
    synthesizer = AVSpeechSynthesizer()
    super.init()
    synthesizer.delegate = self
  }

  init(synthesizer: any SpeechSynthesizing) {
    self.synthesizer = synthesizer
    super.init()
    synthesizer.delegate = self
  }

  public func toggle(plan newPlan: SpeechPlan, from saved: SpeechPlaybackLocation? = nil) {
    if currentPlanID == newPlan.id {
      if synthesizer.isPaused {
        state = .paused
        resume()
        return
      }
      switch state {
      case .playing:
        pause()
      case .paused:
        resume()
      case .idle:
        play(plan: newPlan, from: saved)
      }
    } else {
      play(plan: newPlan, from: saved)
    }
  }

  public func play(plan newPlan: SpeechPlan, from saved: SpeechPlaybackLocation? = nil) {
    stop()
    guard !newPlan.segments.isEmpty else { return }
    configureAudioSession()
    plan = newPlan
    currentPlanID = newPlan.id
    let startIndex: Int
    if let saved,
      saved.sourceID == newPlan.source.sourceID,
      saved.sourceContentHash == newPlan.source.contentHash
    {
      startIndex = min(max(saved.segmentIndex, 0), newPlan.segments.count - 1)
    } else {
      startIndex = 0
    }
    location = SpeechPlaybackLocation(
      sourceID: newPlan.source.sourceID,
      sourceContentHash: newPlan.source.contentHash,
      segmentIndex: startIndex
    )
    speakCurrentSegment()
  }

  public func pause() {
    if synthesizer.isPaused {
      state = .paused
      return
    }
    guard synthesizer.isSpeaking else {
      finishPlayback()
      return
    }
    if synthesizer.pauseSpeaking(at: .word) {
      state = .paused
    } else if !synthesizer.isSpeaking, !synthesizer.isPaused {
      finishPlayback()
    }
  }

  public func resume() {
    guard synthesizer.isPaused else {
      if synthesizer.isSpeaking {
        state = .playing
      } else {
        finishPlayback()
      }
      return
    }
    if synthesizer.continueSpeaking() {
      state = .playing
    }
  }

  public func stop() {
    currentUtterance = nil
    if synthesizer.isSpeaking || synthesizer.isPaused {
      _ = synthesizer.stopSpeaking(at: .immediate)
    }
    plan = nil
    state = .idle
    currentPlanID = nil
  }

  private func speakCurrentSegment() {
    guard let plan, let location,
      plan.segments.indices.contains(location.segmentIndex)
    else {
      finishPlayback()
      return
    }
    let segment = plan.segments[location.segmentIndex]
    let utterance = AVSpeechUtterance(
      string: applyingHints(plan.pronunciationHints, to: segment.text)
    )
    utterance.voice = AVSpeechSynthesisVoice(language: plan.language)
    utterance.rate = min(
      max(plan.rate, AVSpeechUtteranceMinimumSpeechRate),
      AVSpeechUtteranceMaximumSpeechRate
    )
    currentUtterance = utterance
    state = .playing
    synthesizer.speak(utterance)
  }

  private func applyingHints(_ hints: [String: String], to text: String) -> String {
    hints.sorted { $0.key.count > $1.key.count }.reduce(text) { result, item in
      result.replacingOccurrences(of: item.key, with: item.value)
    }
  }

  private func finishPlayback() {
    state = .idle
    plan = nil
    currentUtterance = nil
    currentPlanID = nil
  }

  private func configureAudioSession() {
    #if os(iOS)
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
      } catch {
        errorMessage = "无法启用后台朗读，请重试；锁屏或切换应用后朗读可能中断。"
      }
    #endif
  }
}

extension AppleSpeechPlayer: AVSpeechSynthesizerDelegate {
  nonisolated public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    Task { @MainActor [weak self] in
      guard let self, var location = self.location else { return }
      location.characterOffset = characterRange.location
      location.updatedAt = Date()
      self.location = location
    }
  }

  nonisolated public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.currentUtterance.map(ObjectIdentifier.init) == utteranceID,
        var location = self.location, let plan = self.plan
      else { return }
      location.segmentIndex += 1
      location.characterOffset = 0
      location.updatedAt = Date()
      self.location = location
      if location.segmentIndex < plan.segments.count {
        self.speakCurrentSegment()
      } else {
        self.finishPlayback()
      }
    }
  }

  nonisolated public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.currentUtterance.map(ObjectIdentifier.init) == utteranceID else {
        return
      }
      self.finishPlayback()
    }
  }

  nonisolated public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didPause utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.currentUtterance.map(ObjectIdentifier.init) == utteranceID else {
        return
      }
      self.state = .paused
    }
  }

  nonisolated public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didContinue utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.currentUtterance.map(ObjectIdentifier.init) == utteranceID else {
        return
      }
      self.state = .playing
    }
  }
}
