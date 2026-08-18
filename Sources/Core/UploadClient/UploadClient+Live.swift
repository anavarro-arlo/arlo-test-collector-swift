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
    let client = LiveClient(
      api: api,
      logger: logger,
      runEnvironment: runEnvironment,
      tags: tags,
      taskGroup: group,
      fileController: fileController
    )

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

    func record(trace: Trace) {
      // Persisted immediately so at most the currently in-flight test's result is lost if the process
      // is torn down before waitForUploads() runs. A process relaunched mid-suite (e.g. by xcodebuild)
      // appends to this same file rather than starting from an empty in-memory buffer.
      self.fileController.append(trace)
    }

    private func upload(traces: [Trace]) {
      // NB: Uploads must enter the task group synchronously to ensure they are waited for
      self.taskGroup.enter()
      Task {
        defer { self.taskGroup.leave() }
        let testData = TestResults.json(runEnv: runEnvironment, tags: tags, data: traces)
        do {
          try await self.upload(testData: testData)
          // Only clear the durable log once the upload actually succeeds, so a failed upload doesn't
          // lose data - the file is left in place rather than silently discarded.
          self.fileController.deleteFile()
        } catch {
          // Already logged inside upload(testData:).
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
      // Reads every trace recorded to the file, including any appended by a process that was torn down
      // and relaunched earlier in this same run - not just the ones this process instance recorded.
      let traces = self.fileController.readAll()
      if !traces.isEmpty {
        self.upload(traces: traces)
      }
      let result = self.taskGroup.wait(timeout: timeout)
      if result == .timedOut {
        self.logger?.error("Upload client timed out before completing all uploads")
      }
    }
  }
}
