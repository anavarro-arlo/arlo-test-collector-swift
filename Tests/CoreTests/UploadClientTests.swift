@testable import Core
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class UploadClientTests: XCTestCase {
  func testWaitSynchronouslyForUploads() throws {
    let uploadCompleted = self.expectation(description: "upload completed")
    let uploadClient = UploadClient.live(
      api: .fulfill(uploadCompleted, after: 0.5),
      runEnvironment: EnvironmentValues().runEnvironment(),
      fileController: .temporary()
    )

    uploadClient.record(trace: .mock())
    uploadClient.waitForUploads()

    self.wait(for: [uploadCompleted], timeout: 0)
  }

  func testWaitShouldTimeout() throws {
    let uploadCompleted = self.expectation(description: "upload completed")
    uploadCompleted.isInverted = true
    let uploadClient = UploadClient.live(
      api: .fulfill(uploadCompleted, after: 0.5),
      runEnvironment: EnvironmentValues().runEnvironment(),
      fileController: .temporary()
    )

    uploadClient.record(trace: .mock())
    uploadClient.waitForUploads(timeout: 0.1)

    self.wait(for: [uploadCompleted], timeout: 0)
  }

  func testFailureResponseLogsError() throws {
    let errorMessage = LockIsolated("")
    let logger = Logger(logLevel: .error) { errorMessage.setValue($0) }

    let data = try JSONEncoder().encode(UploadFailureResponse(message: "Something went wrong"))
    let api = ApiClient { _ in (data, .stub(status: 500)) }

    let uploadClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      logger: logger,
      fileController: .temporary()
    )

    uploadClient.record(trace: .mock())

    uploadClient.waitForUploads()
    logger.waitForLogs()

    // this varies e.g. macOS “internal server error” vs linux “Internal Server Error”
    let statusName = HTTPURLResponse.localizedString(forStatusCode: 500)
    XCTAssertEqual(errorMessage.value, "[BuildkiteTestCollector] error: Unexpected HTTP 500 \(statusName), Something went wrong")
  }

  func testNoUploadIsAttemptedWhenNoTracesWereRecorded() throws {
    let testResults = LockIsolated([TestResults]())

    let api = ApiClient { route in
      if case let .upload(results) = route {
        testResults.withValue { $0.append(results) }
      }
      return (Data(), .stub())
    }

    let uploadClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      fileController: .temporary()
    )

    uploadClient.waitForUploads()

    XCTAssertEqual(testResults.count, 0)
  }

  func testRecordingManyTracesUploadsThemAllInOneRequestAtTheEndOfTheRun() throws {
    let testResults = LockIsolated([TestResults]())

    let api = ApiClient { route in
      if case let .upload(results) = route {
        testResults.withValue { $0.append(results) }
      }
      return (Data(), .stub())
    }

    let uploadTasks = DispatchGroup()

    let uploadClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      group: uploadTasks,
      fileController: .temporary()
    )

    for id in 1...300 {
      uploadClient.record(trace: .mock(id: "\(id)"))
    }

    // Nothing should be uploaded until waitForUploads() runs, no matter how many traces were recorded.
    XCTAssertEqual(uploadTasks.wait(timeout: 0.1), .success)
    XCTAssertEqual(testResults.count, 0)

    uploadClient.waitForUploads()

    XCTAssertEqual(testResults.count, 1)
    XCTAssertEqual(testResults[0].data.map(\.id), (1...300).map { "\($0)" })
  }

  func testATornDownProcessDoesNotLosePreviouslyRecordedTraces() throws {
    let testResults = LockIsolated([TestResults]())

    let api = ApiClient { route in
      if case let .upload(results) = route {
        testResults.withValue { $0.append(results) }
      }
      return (Data(), .stub())
    }

    // The same file a relaunched process would use to pick up where a crashed one left off.
    let fileController = FileController.temporary()

    // Simulates the process that recorded some traces and then was torn down before waitForUploads()
    // ran - e.g. xcodebuild relaunching the Runner mid-suite.
    let crashedProcessClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      fileController: fileController
    )
    crashedProcessClient.record(trace: .mock(id: "before-crash-1"))
    crashedProcessClient.record(trace: .mock(id: "before-crash-2"))
    // No waitForUploads() call - the process is torn down here.

    // Simulates the relaunched process picking up the same file.
    let relaunchedProcessClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      fileController: fileController
    )
    relaunchedProcessClient.record(trace: .mock(id: "after-relaunch"))
    relaunchedProcessClient.waitForUploads()

    XCTAssertEqual(testResults.count, 1)
    XCTAssertEqual(testResults[0].data.map(\.id), ["before-crash-1", "before-crash-2", "after-relaunch"])
  }

  func testSuccessfulUploadDeletesTheLocalFile() throws {
    let api = ApiClient { _ in (Data(), .stub(status: 202)) }
    let fileController = FileController.temporary()

    let uploadClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      fileController: fileController
    )

    uploadClient.record(trace: .mock())
    uploadClient.waitForUploads()

    XCTAssertEqual(fileController.readAll(), [])
  }

  func testFailedUploadLeavesTheLocalFileInPlace() throws {
    let api = ApiClient { _ in (Data(), .stub(status: 500)) }
    let fileController = FileController.temporary()

    let uploadClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      logger: Logger(logLevel: .error) { _ in },
      fileController: fileController
    )

    uploadClient.record(trace: .mock(id: "not-lost"))
    uploadClient.waitForUploads()

    XCTAssertEqual(fileController.readAll().map(\.id), ["not-lost"])
  }

  func testUploadIncludesTags() throws {
    let testResults = LockIsolated([TestResults]())

    let api = ApiClient { route in
      if case let .upload(results) = route {
        testResults.withValue { $0.append(results) }
      }
      return (Data(), .stub())
    }

    let uploadClient = UploadClient.live(
      api: api,
      runEnvironment: EnvironmentValues().runEnvironment(),
      tags: ["host.arch": "arm64", "cloud.region": "us-east-1"],
      fileController: .temporary()
    )

    uploadClient.record(trace: .mock())
    uploadClient.waitForUploads()

    XCTAssertEqual(testResults.count, 1)
    XCTAssertEqual(testResults[0].tags, ["host.arch": "arm64", "cloud.region": "us-east-1"])
  }
}

extension Trace {
  fileprivate static func mock(id: String = "id") -> Self {
    Trace(id: id, history: .init(section: "stub"))
  }
}

extension FileController {
  /// A file controller pointed at a unique temporary file, so tests don't collide with each other or
  /// with the shared default path a real run would use.
  fileprivate static func temporary() -> FileController {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ndjson")
    return FileController(fileURL: url)
  }
}
