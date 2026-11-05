import Foundation

struct MemoryProgress: Codable, Equatable {
  let runID: String
  let kind: String
  let stepMiB: Int
  let limitMiB: Int
  let delayMS: Int
  let timeoutSeconds: Int
  let touchPages: Bool
  let successfulMiB: Int
  let attemptedMiB: Int
  var status: String

  var isValid: Bool {
    let configurationValid =
      UUID(uuidString: runID) != nil && ["typed-array", "wasm"].contains(kind)
      && (1...512).contains(stepMiB) && (1...8192).contains(limitMiB)
      && (50...5000).contains(delayMS) && (1...600).contains(timeoutSeconds)
      && (0...limitMiB).contains(successfulMiB)
      && (successfulMiB...limitMiB).contains(attemptedMiB)
      && attemptedMiB - successfulMiB <= stepMiB
    guard configurationValid else { return false }
    switch status {
    case "started": return successfulMiB == 0 && attemptedMiB == 0
    case "allocating":
      return attemptedMiB == min(successfulMiB + stepMiB, limitMiB)
        && attemptedMiB > successfulMiB
    case "success": return successfulMiB > 0 && attemptedMiB == successfulMiB
    case "limit": return successfulMiB == limitMiB && attemptedMiB == limitMiB
    case "stopped", "timeout", "allocation-failed": return true
    default: return false
    }
  }
}

struct MemoryRecord: Codable {
  let timestamp: Date
  let event: String
  let availableBytes: UInt64
  let progress: MemoryProgress?
}

@MainActor
final class MemoryLabStore {
  private let url: URL
  private(set) var records: [MemoryRecord]
  private(set) var runs: [MemoryRecord]
  private(set) var note: String
  private(set) var persistenceError: String?
  private struct Archive: Codable {
    var records: [MemoryRecord]
    var runs: [MemoryRecord]
    var note: String
  }

  init(url: URL? = nil) {
    self.url =
      url
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("memory-lab.json")
    if let data = try? Data(contentsOf: self.url),
      let archive = try? JSONDecoder().decode(Archive.self, from: data)
    {
      records = Array(archive.records.suffix(500))
      runs = Array(archive.runs.suffix(20))
      note = Self.validatedNote(archive.note) ?? ""
    } else {
      records = []
      runs = []
      note = ""
    }
  }

  func append(event: String, availableBytes: UInt64, progress: MemoryProgress? = nil) throws {
    let updated = Array(
      (records + [
        MemoryRecord(
          timestamp: Date(), event: event,
          availableBytes: availableBytes, progress: progress)
      ]).suffix(500))
    var updatedRuns = runs
    if let progress, let record = updated.last {
      updatedRuns.removeAll { $0.progress?.runID == progress.runID }
      updatedRuns.append(record)
      updatedRuns = Array(updatedRuns.suffix(20))
    }
    try save(records: updated, runs: updatedRuns, note: note)
    records = updated
    runs = updatedRuns
  }

  // Accept only meter values, never arbitrary owner-entered text or credentials.
  static func validatedNote(_ value: String) -> String? {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.isEmpty { return "" }
    let number = #"[0-9]{1,6}(?:\.[0-9]{1,2})?"#
    let size = number + #" (?:MiB|GiB|MB|GB)"#
    let pattern = "^(?:" + number + "%|" + size + "|" + number + "% / " + size + ")$"
    guard clean.count <= 64, clean.range(of: pattern, options: .regularExpression) != nil
    else { return nil }
    return clean
  }

  func setNote(_ value: String) throws {
    guard let clean = Self.validatedNote(value) else { throw CocoaError(.coderInvalidValue) }
    try save(records: records, runs: runs, note: clean)
    note = clean
  }

  func interrupt(status: String, availableBytes: UInt64) throws {
    guard var progress = runs.last?.progress,
      ["started", "allocating", "success"].contains(progress.status)
    else { return }
    progress.status = status
    try append(event: status, availableBytes: availableBytes, progress: progress)
  }

  private func save(records: [MemoryRecord], runs: [MemoryRecord], note: String) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(Archive(records: records, runs: runs, note: note))
      try data.write(to: url, options: .atomic)
      persistenceError = nil
    } catch {
      persistenceError = "Memory report could not be saved"
      throw error
    }
  }

  var report: String {
    let formatter = ISO8601DateFormatter()
    var lines = [
      "Native memory history (latest 500, persisted)",
      "os_proc_available_memory: Folio process allowance, NOT WebContent memory",
      "Figma memory meter (owner note): \(note.isEmpty ? "not recorded" : note)",
    ]
    if let persistenceError { lines.append(persistenceError) }
    lines.append("Run summaries (latest 20, retained independently of samples):")
    for record in runs {
      lines.append(describe(record, formatter: formatter))
    }
    lines.append("Event history (latest 500):")
    for record in records {
      lines.append(describe(record, formatter: formatter))
    }
    return lines.joined(separator: "\n")
  }

  private func describe(_ record: MemoryRecord, formatter: ISO8601DateFormatter) -> String {
    var line =
      "\(formatter.string(from: record.timestamp)) \(record.event); Folio available=\(record.availableBytes) bytes"
    if let p = record.progress {
      line +=
        "; run=\(p.runID) \(p.kind) largest successful=\(p.successfulMiB) MiB attempted=\(p.attemptedMiB) MiB status=\(p.status) step=\(p.stepMiB) limit=\(p.limitMiB) delay=\(p.delayMS)ms timeout=\(p.timeoutSeconds)s touch=\(p.touchPages)"
    }
    return line
  }
}
