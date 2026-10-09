import CryptoKit
import Foundation
import NovelDocumentCore
import StoryworldCore

enum FactoryCandidateFingerprint {
  /// Bump when the compiler changes output semantics. Resolution timestamps
  /// are audit metadata, not generation inputs: accepting the same answer
  /// again must not invalidate a candidate.
  static let compilerVersion = 3

  static func compiled(source: String, bake: FactoryBakeReport) throws -> String {
    try FactoryBakeHash.value([source, bake.fingerprint()])
  }

  static func make(
    job: FactoryJob, document: NovelDocument, analysis: FactoryAnalysis,
    decisions: [FactoryDecision], playerTaste: PlayerTasteProfile = .standard
  ) throws
    -> String
  {
    struct Input: Encodable {
      let compilerVersion: Int
      let jobID: UUID
      let document: FactoryInputManifest
      let analysis: FactoryAnalysis
      let playerTaste: String?
    }
    let normalized = decisions.map {
      FactoryDecision(
        id: $0.id, jobID: $0.jobID, question: $0.question,
        recommendation: $0.recommendation, rationale: $0.rationale, impact: $0.impact,
        evidence: $0.evidence, resolution: $0.resolution, answer: $0.answer, resolvedAt: nil)
    }
    let effectiveAnalysis = FactoryAnalysis(
      sourceContentHash: analysis.sourceContentHash,
      coveredChapterIDs: analysis.coveredChapterIDs, proposals: analysis.proposals,
      decisions: normalized, warnings: analysis.warnings,
      chapterSummaries: analysis.chapterSummaries)
    let data = try StoryworldCoding.makeEncoder().encode(
      Input(
        compilerVersion: compilerVersion,
        jobID: job.id, document: FactoryInputManifest(document: document),
        analysis: effectiveAnalysis, playerTaste: try playerTaste.fingerprintKey()))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
