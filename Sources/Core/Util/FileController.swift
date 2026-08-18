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
    self.lock.withValue { _ in
      guard let data = try? Data(contentsOf: self.fileURL) else { return [] }
      let decoder = JSONDecoder()
      return data
        .split(separator: 0x0A)
        .compactMap { try? decoder.decode(Trace.self, from: Data($0)) }
    }
  }

  /// Deletes the file. Called once its contents have been successfully uploaded.
  func deleteFile() {
    self.lock.withValue { _ in
      try? self.fileManager.removeItem(at: self.fileURL)
    }
  }
}

extension FileController {
  /// A file path stable across a test process being relaunched mid-run (e.g. by `xcodebuild` after a
  /// crash), so the relaunched process appends to the same log instead of starting a new one.
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
