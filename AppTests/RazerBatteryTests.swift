import XCTest
@testable import AppCore

final class RazerBatteryTests: XCTestCase {
    func testBatteryReportLayoutAndCRC() {
        let report = RazerBattery.makeReport(commandClass: 0x07, commandID: 0x80, transactionID: 0x1F)
        XCTAssertEqual(report.count, 90)
        XCTAssertEqual(report[0], 0x00)          // status
        XCTAssertEqual(report[1], 0x1F)          // transaction id
        XCTAssertEqual(report[5], 0x02)          // data size
        XCTAssertEqual(report[6], 0x07)
        XCTAssertEqual(report[7], 0x80)
        // XOR of bytes 2..<88: 0x02 ^ 0x07 ^ 0x80. The transaction id is outside it.
        XCTAssertEqual(report[88], 0x85)
        XCTAssertEqual(report[89], 0x00)
        XCTAssertEqual(RazerBattery.makeReport(commandClass: 0x07, commandID: 0x80, transactionID: 0xFF)[88], 0x85)
        XCTAssertEqual(RazerBattery.makeReport(commandClass: 0x07, commandID: 0x84, transactionID: 0x1F)[88], 0x81)
    }

    private func response(to request: [UInt8], status: UInt8, value: UInt8) -> [UInt8] {
        var bytes = request
        bytes[0] = status
        bytes[9] = value
        return bytes
    }

    func testParseAcceptsMatchingSuccess() {
        let request = RazerBattery.makeReport(commandClass: 0x07, commandID: 0x80, transactionID: 0x1F)
        XCTAssertEqual(RazerBattery.parse(response: response(to: request, status: 0x02, value: 200), request: request),
                       .success(200))
    }

    func testParseRejectsBusyTimeoutMismatchAndLength() {
        let request = RazerBattery.makeReport(commandClass: 0x07, commandID: 0x80, transactionID: 0x1F)
        XCTAssertEqual(RazerBattery.parse(response: response(to: request, status: 0x01, value: 9), request: request),
                       .failure(.status(0x01)))
        XCTAssertEqual(RazerBattery.parse(response: response(to: request, status: 0x04, value: 9), request: request),
                       .failure(.status(0x04)))
        var other = response(to: request, status: 0x02, value: 9)
        other[7] = 0x84
        XCTAssertEqual(RazerBattery.parse(response: other, request: request), .failure(.mismatch))
        XCTAssertEqual(RazerBattery.parse(response: [0x02], request: request), .failure(.badLength))
    }

    func testPercentScale() {
        XCTAssertEqual(RazerBattery.percent(fromRaw: 255), 100)
        XCTAssertEqual(RazerBattery.percent(fromRaw: 0), 0)
        XCTAssertEqual(RazerBattery.percent(fromRaw: 38), 15)
        XCTAssertEqual(RazerBattery.percent(fromRaw: 128), 50)
    }

    func testBands() {
        XCTAssertEqual(MouseBatteryService.band(for: 14), .low)
        XCTAssertEqual(MouseBatteryService.band(for: 15), .medium)
        XCTAssertEqual(MouseBatteryService.band(for: 49), .medium)
        XCTAssertEqual(MouseBatteryService.band(for: 50), .ok)
    }

    func testLowWarningSkipsChargingAndUnknown() {
        var reading = MouseBatteryReading(modelName: "Viper", percent: 12, isCharging: false,
                                          updated: Date(), isAsleep: false)
        XCTAssertTrue(reading.isLow)
        reading.isCharging = true
        XCTAssertFalse(reading.isLow)
        reading = MouseBatteryReading(modelName: "Viper", percent: nil, isCharging: false, updated: nil, isAsleep: true)
        XCTAssertFalse(reading.isLow)
        reading.percent = 15
        XCTAssertFalse(reading.isLow)
    }

    func testSupportedModelsAreUniqueWirelessVipers() {
        let ids = RazerBattery.supportedModels.map(\.productID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(RazerBattery.model(for: 0x007B)?.name, "Razer Viper Ultimate")
        XCTAssertNil(RazerBattery.model(for: 0x0078))   // wired-only Viper: no battery
    }
}
