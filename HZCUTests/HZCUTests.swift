//
//  HZCUTests.swift
//  HZCUTests
//
//  Created by DataNeko.IO on 2026/05/31.
//

import Testing
@testable import HZCU

struct HZCUTests {

    @Test func packFrameAndVerify() async throws {
        let payload = Data([0x01, 0x02, 0x03])
        let frame = FrameCodec.pack(commandID: 0x000D, seq: 0x0001, payload: payload)

        #expect(FrameCodec.verify(frame))
        let cmd = try FrameCodec.commandID(from: frame)
        #expect(cmd == 0x000D)
    }

    @Test func crc16RegressionWithKnownData() async throws {
        let data = Data([0xaa, 0x11, 0x77, 0xdd, 0x00, 0x04, 0x00, 0x01, 0x00, 0x01])
        let crc = FrameCodec.crc16(data)

        // Expected from Android JS implementation.
        #expect(crc == 0xC4A8)
    }

    @Test func tokenFrameExtraction() async throws {
        let status = Data([0x00, 0x00])
        let token = Data(Array(repeating: 0xAB, count: 16))
        let payload = status + token
        let frame = FrameCodec.pack(commandID: 0xF001, seq: 0x0002, payload: payload)

        let extracted = try FrameCodec.token(fromF001: frame)
        #expect(extracted == token)
    }

}
