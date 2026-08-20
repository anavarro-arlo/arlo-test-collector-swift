import Dispatch
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension UploadClient {
  /// Constructs a "live" upload client that uploads traces using an API client.
  ///
  /// - Parameters:
  ///   - api: An API client.
  ///   - logger: A logger.
  ///   - runEnvironment: The run environment to accompany uploaded traces.
  ///   - group: A dispatch group to associate with upload tasks.
  ///   - fileController: Persists traces locally so they survive the test process being torn down before
  ///     `waitForUploads()` runs.
  /// - Returns: A upload client that uses an api client.
  static func live(
    api: ApiClient,
    runEnvironment: RunEnvironment,
    tags: [String: String]? = nil,
    logger: Logger? = nil,
    group: DispatchGroup = DispatchGroup(),
    fileController: FileController = FileController()
  ) -> UploadClient {
    // Recomputed from the file rather than starting at zero, so a process relaunched after a crash
    // resumes counting from what's actually on disk instead of losing track of the last upload
    // threshold crossing.
    let pendingCount = LockIsolated(fileController.count())

    let client = LiveClient(
      api: api,
      logger: logger,
      runEnvironment: runEnvironment,
      tags: tags,
      taskGroup: group,
      fileController: fileController,
      pendingCount: pendingCount
    )

    // A previous process may have already reached a full batch but crashed (or failed to upload) before
    // it could be removed from the file. Flush it now rather than waiting for the next threshold
    // crossing, which a short remaining run might never reach.
    if pendingCount.value >= maximumBatchSize {
      client.flushPending()
    }

    return UploadClient(
      record: { client.record(trace: $0) },
      waitForUploads: { client.waitForUploads(timeout: $0) }
    )
  }

  private struct LiveClient {
    let api: ApiClient
    let logger: Logger?
    let runEnvironment: RunEnvironment
    let tags: [String: String]?
    let taskGroup: DispatchGroup
    let fileController: FileController
    let pendingCount: LockIsolated<Int>

    func record(trace: Trace) {
      // Persisted immediately so at most the currently in-flight test's result is lost if the process
      // is torn down before waitForUploads() runs. A process relaunched mid-suite (e.g. by xcodebuild)
      // appends to this same file rather than starting from an empty in-memory buffer.
      self.fileController.append(trace)

      // Upload as soon as a full batch has accumulated, rather than waiting for the run to finish, so
      // suites much larger than one upload's limit (see maximumBatchSize below) don't hold everything
      // in the local file until the very end. Checked as "is this an exact multiple", not "has this
      // been reached", so a batch that's already stuck (failed to upload) doesn't retrigger a flush
      // attempt on every single subsequent test - only every time another full batch accumulates.
      let crossedThreshold = self.pendingCount.withValue { count -> Bool in
        count += 1
        return count % maximumBatchSize == 0
      }
      if crossedThreshold {
        self.flushPending()
      }
    }

    /// Uploads everything currently in the file, in chunks no larger than the API's per-upload limit,
    /// so runs of any size - not just ones comfortably under that limit - upload successfully.
    func flushPending() {
      let traces = self.fileController.readAll()
      for batch in traces.chunked(into: maximumBatchSize) {
        self.upload(traces: batch)
      }
    }

    private func upload(traces: [Trace]) {
      // NB: Uploads must enter the task group synchronously to ensure they are waited for
      self.taskGroup.enter()
      Task {
        defer { self.taskGroup.leave() }
        let testData = TestResults.json(runEnv: runEnvironment, tags: tags, data: traces)
        do {
          try await self.upload(testData: testData)
          // Only clear the durable log - and the count tracking it - once the upload actually
          // succeeds, so a failed upload doesn't lose data or silently reset the flush threshold.
          self.fileController.remove(traces)
          self.pendingCount.withValue { $0 -= traces.count }
        } catch {
          // Already logged inside upload(testData:). Left in the file and still counted as pending,
          // so it's picked up by the next threshold crossing, the next process's startup flush, or
          // waitForUploads() at the latest.
        }
      }
    }

    private func upload(testData: TestResults) async throws {
      self.logger?.debug("Uploading \(testData)")

      var data: Data
      var response: HTTPURLResponse
      do {
        (data, response) = try await self.api.data(for: .upload(testData))
      } catch {
        self.logger?.error("Error uploading: \(error.localizedDescription)")
        throw error
      }

      // Ideally “HTTP 200 OK” etc, but maybe actually “HTTP 200 no error” etc.
      let statusString = "HTTP \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"

      // Currently this should get HTTP 202 Accepted, but let's be a bit permissive to future changes.
      guard (201...204).contains(response.statusCode) else {
        if let body = try? self.api.decode(data, as: UploadFailureResponse.self) {
          self.logger?.error("Unexpected \(statusString), \(body.message)")
        } else {
          self.logger?.error("Unexpected \(statusString), (no message)")
        }
        throw URLError(.badServerResponse, userInfo: [ NSLocalizedDescriptionKey: "Unexpected \(statusString)" ])
      }

      do {
        let result = try self.api.decode(data, as: UploadResponse.self)
        let uploadID = result.uploadID ?? "(missing)"
        let uploadURL = result.uploadURL ?? "(missing)"
        self.logger?.debug("\(statusString), ID: \(uploadID), URL: \(uploadURL)")
      } catch let decodingError as DecodingError {
        self.logger?.error("Warning: error decoding body of \(statusString): \(decodingError)")
        // proceed anyway, since we got an HTTP 2xx, and decoding the response isn't critical
      }
    }

    func waitForUploads(timeout: TimeInterval) {
      // Flushes everything still recorded in the file, including anything appended by a process that
      // was torn down and relaunched earlier in this same run - not just what this instance recorded.
      self.flushPending()
      let result = self.taskGroup.wait(timeout: timeout)
      if result == .timedOut {
        self.logger?.error("Upload client timed out before completing all uploads")
      }
    }
  }
}

// The maximum number of traces that can be sent per upload
private let maximumBatchSize = 5000

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    guard !self.isEmpty else { return [] }
    return stride(from: 0, to: self.count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, self.count)])
    }
  }
}
