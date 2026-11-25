import Foundation
import XCTest
@testable import GlassesLink

final class LogStoreTests: XCTestCase {
    func testFlushPreservesBufferedHistoryAfterClearingView() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LogStore()
        store.append("before writer is ready")
        store.start(fileURL: url)
        store.append("second line")
        XCTAssertTrue(store.snapshot().last?.hasSuffix("second line") == true)
        store.clear()
        store.append("third line")
        store.flushToDisk()
        store.flushToDisk()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.map { String($0.dropFirst(9)) }, ["before writer is ready", "second line", "third line"])
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testPendingBurstIsBoundedAndReported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LogStore()
        for index in 0..<1100 { store.append("line \(index)") }
        XCTAssertEqual(store.snapshot().count, 400)
        XCTAssertTrue(store.snapshot().first?.hasSuffix("line 700") == true)

        store.start(fileURL: url)
        store.flushToDisk()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1025)
        XCTAssertTrue(lines.first?.hasSuffix("76 lines were not written") == true)
        XCTAssertTrue(lines.last?.hasSuffix("line 1099") == true)
    }
}
