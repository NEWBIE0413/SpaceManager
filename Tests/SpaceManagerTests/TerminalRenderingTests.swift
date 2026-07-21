import XCTest
@testable import SpaceManager

final class TerminalRenderingTests: XCTestCase {
    func testSmallIdleEchoFlushesImmediately() {
        XCTAssertTrue(TerminalOutputBatchPolicy.shouldFlushImmediately(
            Data("a".utf8),
            elapsedSinceLastFlush: 1
        ))
        XCTAssertTrue(TerminalOutputBatchPolicy.shouldFlushImmediately(
            Data("한".utf8),
            elapsedSinceLastFlush: 1
        ))
    }

    func testOutputInsideActiveBurstIsCoalesced() {
        XCTAssertFalse(TerminalOutputBatchPolicy.shouldFlushImmediately(
            Data("echo".utf8),
            elapsedSinceLastFlush: TerminalOutputBatchPolicy.coalesceInterval / 2
        ))
    }

    func testIncompleteCursorHiddenRedrawIsCoalesced() {
        let clearThenPartialPaint = Data("\u{1B}[?25l\u{1B}[H\u{1B}[2Jfirst rows".utf8)
        XCTAssertFalse(TerminalOutputBatchPolicy.shouldFlushImmediately(
            clearThenPartialPaint,
            elapsedSinceLastFlush: 1
        ))
        XCTAssertTrue(TerminalOutputBatchPolicy.shouldHoldCursorSpan(
            clearThenPartialPaint,
            heldFor: TerminalOutputBatchPolicy.maximumCursorSpanHold - 0.001
        ))
        XCTAssertFalse(TerminalOutputBatchPolicy.shouldHoldCursorSpan(
            clearThenPartialPaint,
            heldFor: TerminalOutputBatchPolicy.maximumCursorSpanHold
        ))
    }

    func testEraseOnlyRedrawIsCoalesced() {
        for sequence in ["\u{1B}[J", "\u{1B}[2J", "\u{1B}[K", "\u{1B}[2K"] {
            XCTAssertFalse(TerminalOutputBatchPolicy.shouldFlushImmediately(
                Data(sequence.utf8),
                elapsedSinceLastFlush: 1
            ))
        }
    }

    func testCompleteRedrawCanFlushImmediately() {
        let complete = Data("\u{1B}[?25l\u{1B}[H\u{1B}[2Jpaint\u{1B}[?25h".utf8)
        XCTAssertTrue(TerminalOutputBatchPolicy.shouldFlushImmediately(
            complete,
            elapsedSinceLastFlush: 1
        ))
        XCTAssertFalse(TerminalOutputBatchPolicy.shouldHoldCursorSpan(complete, heldFor: 0))
    }

    func testCursorVisibilitySequenceSplitAcrossReadsIsHeldThenCompleted() {
        var pending = Data("paint\u{1B}[?2".utf8)
        XCTAssertTrue(TerminalOutputBatchPolicy.endsWithCursorVisibilityPrefix(pending))
        XCTAssertTrue(TerminalOutputBatchPolicy.shouldHoldCursorSpan(pending, heldFor: 0))

        pending.append(Data("5lmore paint\u{1B}[?25h".utf8))
        XCTAssertFalse(TerminalOutputBatchPolicy.endsWithCursorVisibilityPrefix(pending))
        XCTAssertFalse(TerminalOutputBatchPolicy.hasUnclosedCursorHide(pending))
        XCTAssertFalse(TerminalOutputBatchPolicy.shouldHoldCursorSpan(pending, heldFor: 0))
    }

    func testLargeIdleChunkIsCoalesced() {
        let large = Data(repeating: Character("x").asciiValue!,
                         count: TerminalOutputBatchPolicy.immediateByteLimit + 1)
        XCTAssertFalse(TerminalOutputBatchPolicy.shouldFlushImmediately(
            large,
            elapsedSinceLastFlush: 1
        ))
    }
}
