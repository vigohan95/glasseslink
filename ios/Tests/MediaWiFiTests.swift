import Foundation
import XCTest
@testable import GlassesLink

final class MediaWiFiTests: XCTestCase {
    func testCreateRequestUsesATCSoftAPFields() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00112233-4455-4677-8899-AABBCCDDEEFF"))
        let encoded = try MediaWiFiProtocol.makeRequest(countryCode: "us", id: id,
                                                          ssid: "Test", password: "12345678")
        XCTAssertEqual(encoded.hex,
            "18012006320255533a1000112233445546778899aabbccddeeff42100a0454657374120831323334353637384801")
        XCTAssertThrowsError(try MediaWiFiProtocol.makeRequest(countryCode: "", id: id,
                                                                ssid: "Test", password: "12345678"))
    }

    func testParsesReportedHotspotWithNumericAddressAndPort() throws {
        let address = PB.string(3, "192.168.4.1/24")
        let credentials = PB.string(1, "Test Hotspot") + PB.string(2, "test-only-123")
        let reply = PB.uint(1, 1) + PB.bytes(2, address) + PB.bytes(3, credentials) + PB.uint(4, 21000)

        let endpoint = try MediaWiFiProtocol.parseInfo(reply, requestedSSID: "Requested", requestedPassword: "requested-only")

        XCTAssertEqual(endpoint.address, "192.168.4.1")
        XCTAssertEqual(endpoint.port, 21000)
        XCTAssertEqual(endpoint.ssid, "Test Hotspot")
        XCTAssertEqual(endpoint.password, "test-only-123")
        XCTAssertEqual(String(reflecting: endpoint), "MediaWiFiEndpoint")
    }

    func testUsesRequestedCredentialsAndListenerWhenSuccessfulReplyOmitsThem() throws {
        let reply = PB.uint(1, 1) + PB.bytes(2, PB.string(3, "192.168.4.1"))
        let endpoint = try MediaWiFiProtocol.parseInfo(reply, requestedSSID: "Requested", requestedPassword: "requested-only")

        XCTAssertEqual(endpoint.port, 20203)
        XCTAssertEqual(endpoint.ssid, "Requested")
        XCTAssertEqual(endpoint.password, "requested-only")
    }

    func testRejectsFailureOrUnusableEndpoint() throws {
        let validity = PB.uint(1, 1)
        let address = PB.bytes(2, PB.string(3, "192.168.4.1"))
        let invalidReplies = [PB.uint(1, 3) + address, validity, validity + address + PB.uint(4, 65_536)]

        for reply in invalidReplies {
            XCTAssertThrowsError(try MediaWiFiProtocol.parseInfo(reply, requestedSSID: "Requested",
                                                                 requestedPassword: "requested-only"))
        }
    }
}
