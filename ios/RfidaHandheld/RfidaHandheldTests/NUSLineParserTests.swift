import XCTest
@testable import RfidaHandheld

final class NUSLineParserTests: XCTestCase {
    private func classify(_ chunks: [String]) -> [NUSLine] {
        var buffer = NUSLineBuffer()
        return chunks.flatMap { buffer.feed(Data($0.utf8)) }.map(NUSLine.classify)
    }

    func testControlLineFragmentedAcrossNotifications() {
        XCTAssertEqual(classify(["\n@STA", "TE:SCAN", "NING\n"]), [.state(.scanning)])
        XCTAssertEqual(classify(["@CFG2:4", "2:OK:2", "0:10", "\n"]),
                       [.settings(.ok(id: 42, settings: ReaderSettings(power: 20, idleSeconds: 10)))])
    }

    func testMultipleLinesInOneNotificationMixedWithEPC() {
        let lines = classify(["\n@STATE:READY\nE280689420005015E1A661E8\n@CFG2:43:ERR:BUSY\n"])
        XCTAssertEqual(lines, [
            .state(.ready),
            .tag(epc: "E280689420005015E1A661E8", rssi: nil),
            .settings(.error(id: 43, reason: "BUSY")),
        ])
    }

    func testBlankLinesIgnoredAndIncompleteTailRetained() {
        var buffer = NUSLineBuffer()
        XCTAssertEqual(buffer.feed(Data("\n\n\r\n  \n\t\n".utf8)), [])
        XCTAssertEqual(buffer.feed(Data("E2806894".utf8)), [])
        XCTAssertEqual(buffer.feed(Data("20005015".utf8)), [])
        XCTAssertEqual(buffer.feed(Data("E1A661E8\r\n".utf8)).map(NUSLine.classify),
                       [.tag(epc: "E280689420005015E1A661E8", rssi: nil)])
    }

    func testOverlongLineIsDiscardedAndBufferRecovers() {
        var buffer = NUSLineBuffer()
        let overlong = String(repeating: "A", count: NUSLineBuffer.maxLineBytes + 50)
        XCTAssertEqual(buffer.feed(Data(overlong.utf8)), [])
        XCTAssertEqual(buffer.feed(Data("BBBB\n@STATE:READY\n".utf8)).map(NUSLine.classify), [.state(.ready)])
    }

    func testResetDropsPartialLine() {
        var buffer = NUSLineBuffer()
        _ = buffer.feed(Data("@STATE:SCAN".utf8))
        buffer.reset()
        XCTAssertEqual(buffer.feed(Data("NING\n".utf8)).map(NUSLine.classify), [.ignored])
    }

    func testNonASCIIOrControlBytesRejectLine() {
        var buffer = NUSLineBuffer()
        var data = Data("E28068".utf8)
        data.append(contentsOf: [0xC3, 0xA9, 0x00])
        data.append(Data("94200050\n@STATE:READY\n".utf8))
        XCTAssertEqual(buffer.feed(data).map(NUSLine.classify), [.state(.ready)])
    }

    func testControlLinesAreNeverTags() {
        let lines = [
            "@CFG2:42:OK:20:10", "@CFG2:42:ERR:BUSY", "@STATE:FAULT", "@STATE:DEADBEEF",
            "@DEADBEEFDEADBEEF", "@CFG:42:OK:20:1500", "@CFG2:42:OK:20",
        ]
        for line in lines {
            if case .tag = NUSLine.classify(line) { XCTFail("\(line) was parsed as a tag") }
        }
    }

    func testUnknownAndMalformedControlLinesIgnored() {
        let malformed = [
            "@STATE:SLEEPING", "@STATE:", "@STATE:ready", "@CFG2:42:OK:20", "@CFG2:42:OK:20:10:5",
            "@CFG2:-1:OK:20:10", "@CFG2:42:OK:+20:10", "@CFG2:42:OK:2 0:10", "@CFG2:042:OK:20:10",
            "@CFG2:0:OK:20:10", "@CFG2:70000:OK:20:10", "@CFG2:42:ERR:", "@CFG2:42:ERR:busy",
            "@CFG2:42:MAYBE:20:10", "@CFG2:42:OK:20:10ms", "@CFG2::OK:20:10", "@CFG2:42:ERR:BUSY:1",
            "@CFG:42:OK:20:1500", "@UNKNOWN", "CFG2:GET:42", "CFG:1:OK:20:1500", "READY",
        ]
        for line in malformed {
            XCTAssertEqual(NUSLine.classify(line), .ignored, line)
        }
    }

    func testAllReaderStatesParse() {
        for state in ["UNKNOWN", "STOPPING", "READY", "STARTING", "SCANNING", "FAULT", "CONFIGURING"] {
            XCTAssertEqual(NUSLine.classify("@STATE:\(state)"), .state(ReaderState(rawValue: state)!))
        }
    }

    func testUnknownErrorReasonIsKeptForDiagnostics() {
        XCTAssertEqual(NUSLine.classify("@CFG2:9:ERR:SOMETHING_NEW_2"), .settings(.error(id: 9, reason: "SOMETHING_NEW_2")))
    }

    func testEPCParsingUnchanged() {
        XCTAssertEqual(NUSLine.classify("E280689420005015E1A661E8"), .tag(epc: "E280689420005015E1A661E8", rssi: nil))
        XCTAssertEqual(NUSLine.classify("e2801160600002042bb8a1c3"), .tag(epc: "E2801160600002042BB8A1C3", rssi: nil))
        XCTAssertEqual(NUSLine.classify("E2801160600002042BB8A1C3,-55"), .tag(epc: "E2801160600002042BB8A1C3", rssi: -55))
        XCTAssertEqual(NUSLine.classify("E28011606"), .ignored)   // 單數長度
        XCTAssertEqual(NUSLine.classify("E28011"), .ignored)      // 太短
        XCTAssertEqual(NUSLine.classify("E28011606000020G"), .ignored)
    }

    func testCommandLinesAndSizes() {
        XCTAssertEqual(ReaderCommand.mode(.register).data, Data("MODE:REGISTER\n".utf8))
        XCTAssertEqual(ReaderCommand.mode(.batch).data, Data("MODE:BATCH\n".utf8))
        XCTAssertEqual(ReaderCommand.mode(.idle).data, Data("MODE:IDLE\n".utf8))
        XCTAssertEqual(ReaderCommand.getSettings(id: 42).data, Data("CFG2:GET:42\n".utf8))
        let set = ReaderCommand.setSettings(id: 43, settings: ReaderSettings(power: 20, idleSeconds: 10))
        XCTAssertEqual(set.data, Data("CFG2:SET:43:20:10\n".utf8))

        let longest = ReaderCommand.setSettings(id: 999, settings: ReaderSettings(power: 26, idleSeconds: 60))
        XCTAssertEqual(longest.data.count, 19)
        XCTAssertLessThanOrEqual(longest.data.count, 20)
        XCTAssertEqual(longest.data.last, 0x0A)
        XCTAssertFalse(longest.data.contains(0x5C), "must contain a real LF, not a backslash")
    }
}
