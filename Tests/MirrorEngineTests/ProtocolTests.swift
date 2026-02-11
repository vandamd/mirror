import XCTest
@testable import MirrorEngine

final class ProtocolTests: XCTestCase {

    // MARK: - Magic bytes

    func testMagicFrameBytes() {
        XCTAssertEqual(MAGIC_FRAME, [0xDA, 0x7E])
    }

    func testMagicCmdBytes() {
        XCTAssertEqual(MAGIC_CMD, [0xDA, 0x7F])
    }

    func testMagicFrameAndCmdDiffer() {
        XCTAssertNotEqual(MAGIC_FRAME, MAGIC_CMD,
                          "Frame and command magic must be distinguishable")
    }

    // MARK: - Flags

    func testFlagKeyframe() {
        XCTAssertEqual(FLAG_KEYFRAME, 0x01)
    }

    // MARK: - Command IDs

    func testCmdBrightness() {
        XCTAssertEqual(CMD_BRIGHTNESS, 0x01)
    }

    func testCmdWarmth() {
        XCTAssertEqual(CMD_WARMTH, 0x02)
    }

    func testCmdBacklightToggle() {
        XCTAssertEqual(CMD_BACKLIGHT_TOGGLE, 0x03)
    }

    func testCmdResolution() {
        XCTAssertEqual(CMD_RESOLUTION, 0x04)
    }

    func testCommandIDsAreUnique() {
        let ids: [UInt8] = [CMD_BRIGHTNESS, CMD_WARMTH, CMD_BACKLIGHT_TOGGLE, CMD_RESOLUTION]
        XCTAssertEqual(ids.count, Set(ids).count, "All command IDs must be unique")
    }

    // MARK: - Frame header layout

    func testFrameHeaderIs11Bytes() {
        var header = Data(capacity: FRAME_HEADER_SIZE)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(FLAG_KEYFRAME)
        var seq = UInt32(0).littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(1024).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header.count, FRAME_HEADER_SIZE)
    }

    func testFrameHeaderMagicPrefix() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(0x00)
        var seq = UInt32(0).littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(0).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[0], 0xDA)
        XCTAssertEqual(header[1], 0x7E)
    }

    func testFrameHeaderFlagsPosition() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(FLAG_KEYFRAME)
        var seq = UInt32(0).littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(0).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[2], FLAG_KEYFRAME, "Flags byte is at offset 2")
    }

    func testFrameHeaderSequencePosition() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(0x00)
        let seqValue: UInt32 = 0x01020304
        var seq = seqValue.littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(0).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[3], 0x04)
        XCTAssertEqual(header[4], 0x03)
        XCTAssertEqual(header[5], 0x02)
        XCTAssertEqual(header[6], 0x01)
    }

    func testFrameHeaderLengthIsLittleEndian() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(0x00)
        var seq = UInt32(0).littleEndian
        header.append(Data(bytes: &seq, count: 4))
        let payloadSize: UInt32 = 0x01020304
        var len = payloadSize.littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[7], 0x04)
        XCTAssertEqual(header[8], 0x03)
        XCTAssertEqual(header[9], 0x02)
        XCTAssertEqual(header[10], 0x01)
    }

    func testNonKeyframeHasFlagZero() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(0)
        var seq = UInt32(0).littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(100).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[2], 0x00)
    }

    func testAckMagicBytes() {
        XCTAssertEqual(MAGIC_ACK, [0xDA, 0x7A])
    }

    func testAllMagicBytesAreUnique() {
        XCTAssertNotEqual(MAGIC_FRAME, MAGIC_CMD)
        XCTAssertNotEqual(MAGIC_FRAME, MAGIC_ACK)
        XCTAssertNotEqual(MAGIC_CMD, MAGIC_ACK)
    }

    // MARK: - Command packet layout

    func testCommandPacketIs4Bytes() {
        // Build a command packet the same way TCPServer.sendCommand does:
        // [magic:2][cmd:1][value:1]
        var packet = Data(capacity: 4)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_BRIGHTNESS)
        packet.append(128)

        XCTAssertEqual(packet.count, 4)
    }

    func testCommandPacketMagicPrefix() {
        var packet = Data()
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_WARMTH)
        packet.append(64)

        XCTAssertEqual(packet[0], 0xDA)
        XCTAssertEqual(packet[1], 0x7F)
    }

    func testCommandPacketCmdPosition() {
        var packet = Data()
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_BRIGHTNESS)
        packet.append(200)

        XCTAssertEqual(packet[2], CMD_BRIGHTNESS, "Command byte is at offset 2")
    }

    func testCommandPacketValuePosition() {
        var packet = Data()
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_WARMTH)
        packet.append(42)

        XCTAssertEqual(packet[3], 42, "Value byte is at offset 3")
    }

    // MARK: - Step constants

    func testBrightnessStepIsPositive() {
        XCTAssertGreaterThan(BRIGHTNESS_STEP, 0)
    }

    func testWarmthStepIsPositive() {
        XCTAssertGreaterThan(WARMTH_STEP, 0)
    }
}
