import XCTest
@testable import Milk

final class ChatQualityTests: XCTestCase {
    func testFollowHysteresisToleratesSmallWheelsAndReentersWithinOneLine() {
        var state = ChatFollowTailState(); state.userScrolling = true
        state.update(.init(offset: 600, contentHeight: 1000, viewportHeight: 400))
        for offset in [588.0, 576, 564] {
            state.update(.init(offset: offset, contentHeight: 1000, viewportHeight: 400))
            XCTAssertTrue(state.followsTail)
        }
        state.update(.init(offset: 550, contentHeight: 1000, viewportHeight: 400))
        XCTAssertFalse(state.followsTail)
        state.update(.init(offset: 575, contentHeight: 1000, viewportHeight: 400))
        XCTAssertFalse(state.followsTail, "25 points stays outside the enter band")
        state.update(.init(offset: 576, contentHeight: 1000, viewportHeight: 400))
        XCTAssertTrue(state.followsTail)
    }
    func testReadingDoesNotRearmFromLayoutGrowthOrClamp() {
        var state = ChatFollowTailState(); state.followsTail = false
        state.update(.init(offset: 550, contentHeight: 1000, viewportHeight: 400))
        state.update(.init(offset: 776, contentHeight: 1200, viewportHeight: 400))
        XCTAssertFalse(state.followsTail)
        state.userScrolling = true
        state.update(.init(offset: 600, contentHeight: 1000, viewportHeight: 400))
        XCTAssertFalse(state.followsTail)
    }
    func testFragmentedLargeRPCRecordIsScannedOnceAndKeepsFraming() throws {
        let line = Data(("{\"type\":\"response\",\"value\":\"" + String(repeating: "x", count: 1_000_000) + "\"}\r\n").utf8)
        var framer = PiJSONLFramer(), records: [Data] = []
        for start in stride(from: 0, to: line.count, by: 113) {
            records += try framer.append(line.subdata(in: start..<min(line.count, start + 113)))
        }
        XCTAssertEqual(records, [Data(line.dropLast(2))])
        XCTAssertEqual(framer.scannedByteCount, line.count, "Previously every pipe read rescanned the unfinished prefix")
        XCTAssertFalse(framer.hasPartialRecord)
    }
    func testWorkerDecoderPreservesOrderSplitUnicodeAndPreFailureRecords() {
        let bytes = Data("{\"type\":\"message\",\"text\":\"ž🥛\u{2028}\"}\n{\"type\":\"response\",\"id\":\"1\"}\nnot-json\n{\"type\":\"discarded\"}\n".utf8)
        var decoder = PiRPCRecordDecoder(), output: [JSONValue] = []
        var failure: String?
        for byte in bytes {
            let batch = decoder.append(Data([byte]))
            output += batch.records
            if let error = batch.failure { failure = error; break }
        }
        XCTAssertEqual(output.map { $0["type"].string }, ["message", "response"])
        XCTAssertEqual(output.first?["text"].string, "ž🥛\u{2028}")
        XCTAssertTrue(failure?.contains("malformed") == true)
        var sameRead = PiRPCRecordDecoder()
        let batch = sameRead.append(bytes)
        XCTAssertEqual(batch.records, output, "Moving decoding off-main must not drop valid records before malformed input")
        XCTAssertNotNil(batch.failure)
    }
    func testFramerStillBoundsUnfinishedAndFinishedRecords() {
        var unfinished = PiJSONLFramer()
        XCTAssertThrowsError(try unfinished.append(Data(repeating: 65, count: PiJSONLFramer.maximumRecordBytes + 1)))
        var finished = PiJSONLFramer()
        var data = Data(repeating: 65, count: PiJSONLFramer.maximumRecordBytes + 1); data.append(10)
        XCTAssertThrowsError(try finished.append(data))
    }
    func testReadingAnchorsUseLogicalOrderAndFreezeAcrossReflow() {
        let memory = ChatScrollMemory()
        let first = ChatReadingAnchor(id: "first", ownerID: "turn", order: [3, 1, 10])
        let second = ChatReadingAnchor(id: "second", ownerID: "turn", order: [3, 1, 11])
        memory.setVisible(second, visible: true); memory.setVisible(first, visible: true)
        XCTAssertEqual(memory.readingAnchor, first)
        memory.pendingResizeAnchor = first
        memory.removeVisible("first"); memory.setVisible(.init(id: "unrelated", ownerID: "other", order: [0]), visible: true)
        XCTAssertEqual(memory.readingAnchor, first, "Intermediate resized layout must not overwrite the reading target")
        memory.pendingResizeAnchor = nil
        XCTAssertEqual(memory.readingAnchor?.id, "unrelated")
        let oldGeneration = memory.userScrollGeneration
        memory.pendingResizeAnchor = first
        memory.beginUserScroll()
        XCTAssertGreaterThan(memory.userScrollGeneration, oldGeneration, "A gesture must invalidate deferred restoration even after it ends")
        XCTAssertNil(memory.pendingResizeAnchor)
        memory.follow.userScrolling = false
        XCTAssertNotEqual(memory.userScrollGeneration, oldGeneration)
    }
    func testReturningNearTailDoesNotPullReaderAcrossLastLines() {
        var state = ChatFollowTailState(); state.followsTail = false; state.userScrolling = true
        state.update(.init(offset: 500, contentHeight: 1000, viewportHeight: 400))
        state.update(.init(offset: 560, contentHeight: 1000, viewportHeight: 400))
        XCTAssertFalse(state.followsTail)
        state.update(.init(offset: 575, contentHeight: 1000, viewportHeight: 400))
        XCTAssertFalse(state.followsTail)
        state.update(.init(offset: 600, contentHeight: 1000, viewportHeight: 400))
        XCTAssertTrue(state.followsTail)
    }
}
