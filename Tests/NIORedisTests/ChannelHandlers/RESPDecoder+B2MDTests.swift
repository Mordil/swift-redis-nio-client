import NIO
@testable import NIORedis
import XCTest

final class RESPDecoderByteToMessageDecoderTests: XCTestCase {
    private let decoder = RESPDecoder()
    private let allocator = ByteBufferAllocator()

    func testDecoding_partial_needsMoreData() throws {
        XCTAssertEqual(try decodeTest("+OK\r"), .needMoreData)
        XCTAssertEqual(try decodeTest("$2\r\n"), .needMoreData)
        XCTAssertEqual(try decodeTest("*2\r\n:1\r\n"), .needMoreData)
        XCTAssertEqual(try decodeTest("*2\r\n*1\r\n"), .needMoreData)
        XCTAssertEqual(try decodeTest("-ERR test\r"), .needMoreData)
        XCTAssertEqual(try decodeTest(":2"), .needMoreData)
    }

    func testDecoding_badMessage_throws() {
        do {
            _ = try decodeTest("&3\r\n").0
            XCTFail("Failed to properly throw error")
        } catch { XCTAssertTrue(error is RESPDecoder.Error) }
    }

    private static let completeMessages = [
        "+OK\r\n",
        "$2\r\naa\r\n",
        "*2\r\n:1\r\n:2\r\n",
        "*2\r\n*1\r\n:1\r\n:2\r\n",
        "-ERR test\r\n",
        ":2\r\n"
    ]

    func testDecoding_complete_continues() throws {
        for message in RESPDecoderByteToMessageDecoderTests.completeMessages {
            XCTAssertEqual(try decodeTest(message), .continue)
        }
    }

    func testDecoding_complete_movesReaderIndex() throws {
        for message in RESPDecoderByteToMessageDecoderTests.completeMessages {
            XCTAssertEqual(try decodeTest(message).1, message.bytes.count)
        }
    }

    private func decodeTest(_ input: String) throws -> DecodingState {
        var buffer = allocator.buffer(capacity: 256)
        return try decodeTest(input, buffer: &buffer)
    }

    private func decodeTest(_ input: String) throws -> (DecodingState, Int) {
        var buffer = allocator.buffer(capacity: 256)
        return (try decodeTest(input, buffer: &buffer), buffer.readerIndex)
    }

    private func decodeTest(_ input: String, buffer: inout ByteBuffer) throws -> DecodingState {
        let embeddedChannel = EmbeddedChannel()
        defer { _ = try? embeddedChannel.finish() }
        let handler = ByteToMessageHandler(decoder)
        try embeddedChannel.pipeline.addHandler(handler).wait()
        let context = try embeddedChannel.pipeline.context(handler: handler).wait()
        
        buffer.writeString(input)

        return try decoder.decode(context: context, buffer: &buffer)
    }
}

extension RESPDecoderByteToMessageDecoderTests {
    static var allTests = [
        ("testDecoding_partial_needsMoreData", testDecoding_partial_needsMoreData),
        ("testDecoding_badMessage_throws", testDecoding_badMessage_throws),
        ("testDecoding_complete_continues", testDecoding_complete_continues),
        ("testDecoding_complete_movesReaderIndex", testDecoding_complete_movesReaderIndex),
    ]
}
