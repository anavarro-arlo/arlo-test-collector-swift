import Foundation

/// Persists traces to a local, append-only file so they survive the test process being torn down before
/// `waitForUploads()` runs, and reads them back for upload once the run finishes.
///
/// Traces are stored as newline-delimited JSON rather than a single JSON array so each one can be
/// appended without rewriting the whole file, and so a process that starts after a crash can keep
/// appending to the same file rather than starting from an empty log.
final class FileController {
  private let fileManager: FileManager
  private let fileURL: URL
  private let lock = LockIsolated(())

  init(fileManager: FileManager = .default, fileURL: URL = FileController.defaultFileURL) {
    self.fileManager = fileManager
    self.fileURL = fileURL
  }

  /// Appends a single trace to the file.
  func append(_ trace: Trace) {
    self.lock.withValue { _ in
      guard var data = try? JSONEncoder().encode(trace) else { return }
      data.append(0x0A) // "\n"

      if let handle = try? FileHandle(forWritingTo: self.fileURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
      } else {
        try? data.write(to: self.fileURL, options: .atomic)
      }
    }
  }

  /// Reads every trace currently recorded in the file, in the order they were appended.
  func readAll() -> [Trace] {
    self.lock.withValue { _ in self.decodedLines() }
  }

  /// The number of traces currently recorded in the file.
  ///
  /// Used to recompute a process's in-memory "traces since last upload" count from what's actually on
  /// disk, rather than assuming zero - so a process relaunched after a crash resumes counting from the
  /// correct point instead of losing track of the last upload threshold crossing.
  func count() -> Int {
    self.lock.withValue { _ in self.decodedLines().count }
  }

  /// Removes the given traces from the file by id, leaving any others in place.
  ///
  /// Called once a batch has been successfully uploaded, so a failed upload isn't mistaken for a
  /// completed one and its traces aren't lost.
  func remove(_ traces: [Trace]) {
    self.lock.withValue { _ in
      let idsToRemove = Set(traces.map(\.id))
      let remaining = self.decodedLines().filter { !idsToRemove.contains($0.id) }

      guard !remaining.isEmpty else {
        try? self.fileManager.removeItem(at: self.fileURL)
        return
      }

      var newData = Data()
      for trace in remaining {
        guard var data = try? JSONEncoder().encode(trace) else { continue }
        data.append(0x0A)
        newData.append(data)
      }
      try? newData.write(to: self.fileURL, options: .atomic)
    }
  }

  /// Must only be called while holding `lock`.
  private func decodedLines() -> [Trace] {
    guard let data = try? Data(contentsOf: self.fileURL) else { return [] }
    let decoder = JSONDecoder()
    return data
      .split(separator: 0x0A)
      .compactMap { try? decoder.decode(Trace.self, from: Data($0)) }
  }
}

extension FileController {
  /// A file path stable across a test process being relaunched mid-run (e.g. by `xcodebuild` after a
  /// crash), so the relaunched process appends to the same log instead of starting a new one.
  ///
  /// This relies on the app's container (and so its temporary directory) surviving that relaunch rather
  /// than being wiped, as it would be by a fresh install. Verified directly: killing (SIGKILL) and
  /// relaunching an installed simulator app leaves its container path and `tmp` contents unchanged - see
  /// https://developer.apple.com/forums/thread/709474, where an Apple Developer Tools engineer states
  /// XCTest only (re)installs an app at the start of a test suite/plan, not between test runs within it.
  ///
  /// Namespaced by a CI job identifier where available, so concurrent jobs sharing a host's temporary
  /// directory don't write to the same file.
  static var defaultFileURL: URL {
    let jobIdentifier = ProcessInfo.processInfo.environment["BUILDKITE_JOB_ID"]
      ?? ProcessInfo.processInfo.environment["GITHUB_RUN_ID"]
      ?? ProcessInfo.processInfo.environment["CI_BUILD_ID"]
    let fileName = jobIdentifier.map { "buildkite-test-collector-pending-\($0).ndjson" }
      ?? "buildkite-test-collector-pending.ndjson"
    return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
  }
}
