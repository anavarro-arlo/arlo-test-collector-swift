@testable import Core
import XCTest

final class FileControllerTests: XCTestCase {
  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ndjson")
  }

  func testReadAllReturnsEmptyWhenFileDoesNotExist() {
    let controller = FileController(fileURL: self.temporaryFileURL())
    XCTAssertEqual(controller.readAll(), [])
  }

  func testAppendThenReadAllReturnsTracesInOrder() {
    let controller = FileController(fileURL: self.temporaryFileURL())

    controller.append(Trace(id: "1", history: .init(section: "stub")))
    controller.append(Trace(id: "2", history: .init(section: "stub")))
    controller.append(Trace(id: "3", history: .init(section: "stub")))

    XCTAssertEqual(controller.readAll().map(\.id), ["1", "2", "3"])
  }

  func testAppendPersistsAcrossSeparateFileControllerInstances() {
    let fileURL = self.temporaryFileURL()

    FileController(fileURL: fileURL).append(Trace(id: "1", history: .init(section: "stub")))
    // A fresh instance pointed at the same file, simulating a relaunched process.
    FileController(fileURL: fileURL).append(Trace(id: "2", history: .init(section: "stub")))

    XCTAssertEqual(FileController(fileURL: fileURL).readAll().map(\.id), ["1", "2"])
  }

  func testCountReturnsZeroWhenFileDoesNotExist() {
    let controller = FileController(fileURL: self.temporaryFileURL())
    XCTAssertEqual(controller.count(), 0)
  }

  func testCountReturnsNumberOfAppendedTraces() {
    let controller = FileController(fileURL: self.temporaryFileURL())
    controller.append(Trace(id: "1", history: .init(section: "stub")))
    controller.append(Trace(id: "2", history: .init(section: "stub")))
    XCTAssertEqual(controller.count(), 2)
  }

  func testRemoveDeletesOnlySpecifiedTraces() {
    let controller = FileController(fileURL: self.temporaryFileURL())
    let traces = (1...3).map { Trace(id: "\($0)", history: .init(section: "stub")) }
    traces.forEach(controller.append)

    controller.remove([traces[1]])

    XCTAssertEqual(controller.readAll().map(\.id), ["1", "3"])
  }

  func testRemovingEveryTraceDeletesTheFile() {
    let controller = FileController(fileURL: self.temporaryFileURL())
    let trace = Trace(id: "1", history: .init(section: "stub"))
    controller.append(trace)

    controller.remove([trace])

    XCTAssertEqual(controller.readAll(), [])
    XCTAssertEqual(controller.count(), 0)
  }

  func testRemoveWhenFileDoesNotExistDoesNotThrow() {
    let controller = FileController(fileURL: self.temporaryFileURL())
    controller.remove([Trace(id: "1", history: .init(section: "stub"))])
  }
}
