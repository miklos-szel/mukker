import Foundation
import IOKit
import IOKit.usb

/// Reads a wireless Razer mouse's battery over USB — the one part of the Razer
/// driver protocol the app needs, ported from librazermacos.
///
/// Every request is a 90-byte HID feature report sent as a plain USB control
/// transfer on the device's default pipe (`DeviceRequest`), exactly as that
/// library does. That needs neither `USBDeviceOpen` nor a TCC grant — opening the
/// mouse's HID interface instead could put the app behind Input Monitoring.
///
/// Everything here is `nonisolated`; `readStatus()` blocks (~60 ms per request)
/// and must only be called off the main thread, by `MouseBatteryService`.
enum RazerBattery {
    static let vendorID = 0x1532

    struct Model: Equatable {
        let productID: Int
        let name: String
    }

    /// Wireless Vipers only — a wired-only Viper has no battery. Both the
    /// mouse's own ID (on the cable) and its receiver's are listed.
    nonisolated static let supportedModels: [Model] = [
        Model(productID: 0x007A, name: "Razer Viper Ultimate"),
        Model(productID: 0x007B, name: "Razer Viper Ultimate"),
        Model(productID: 0x009E, name: "Razer Viper Mini SE"),
        Model(productID: 0x009F, name: "Razer Viper Mini SE"),
        Model(productID: 0x00A5, name: "Razer Viper V2 Pro"),
        Model(productID: 0x00A6, name: "Razer Viper V2 Pro"),
        Model(productID: 0x00C0, name: "Razer Viper V3 Pro"),
        Model(productID: 0x00C1, name: "Razer Viper V3 Pro")
    ]

    nonisolated static func model(for productID: Int) -> Model? {
        supportedModels.first { $0.productID == productID }
    }

    // MARK: - Report (pure)

    static let reportLength = 90
    static let batteryCommand: (cls: UInt8, id: UInt8) = (0x07, 0x80)
    static let chargingCommand: (cls: UInt8, id: UInt8) = (0x07, 0x84)
    /// librazermacos leaves the Viper Ultimate on the default `0xFF`; openrazer
    /// uses `0x1F` for the newer Vipers. Both are tried, the one that answered
    /// is remembered per product.
    static let transactionIDs: [UInt8] = [0x1F, 0xFF]

    enum ReportError: Error, Equatable {
        case badLength
        case mismatch
        /// The device's status byte: 1 busy, 3 failure, 4 timeout (the mouse is
        /// asleep or out of range), 5 not supported.
        case status(UInt8)
    }

    /// `status, transaction_id, remaining_packets(2), protocol_type, data_size,
    /// command_class, command_id, args[80], crc, reserved`.
    nonisolated static func makeReport(commandClass: UInt8, commandID: UInt8, transactionID: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[1] = transactionID
        report[5] = 0x02                 // data_size
        report[6] = commandClass
        report[7] = commandID
        report[88] = crc(report)
        return report
    }

    /// XOR of bytes 2..<88.
    nonisolated static func crc(_ report: [UInt8]) -> UInt8 {
        report[2..<88].reduce(0, ^)
    }

    /// `args[1]` of a response that echoes the request and reports success.
    nonisolated static func parse(response: [UInt8], request: [UInt8]) -> Result<UInt8, ReportError> {
        guard response.count == reportLength, request.count == reportLength else { return .failure(.badLength) }
        guard response[6] == request[6], response[7] == request[7] else { return .failure(.mismatch) }
        guard response[0] == 0x02 else { return .failure(.status(response[0])) }
        return .success(response[9])
    }

    /// The device reports 0–255.
    nonisolated static func percent(fromRaw raw: UInt8) -> Int {
        Int((Double(raw) * 100 / 255).rounded())
    }

    // MARK: - USB

    struct Status {
        let model: Model
        /// nil when the device is attached but did not answer (mouse asleep or off).
        let percent: Int?
        let isCharging: Bool
    }

    /// Transaction ID that last worked, per product. Only touched from the
    /// service's serial queue.
    nonisolated(unsafe) private static var workingTransactionID: [Int: UInt8] = [:]

    /// The first supported Razer device that answers, or — if one is attached but
    /// none answers — that device with a nil percent. nil when none is attached.
    nonisolated static func readStatus() -> Status? {
        var fallback: Status?
        for (service, model) in attachedDevices() {
            defer { IOObjectRelease(service) }
            guard let device = DeviceInterface(service: service) else {
                Log.mouse.error("No USB interface for \(String(format: "0x%04X", model.productID), privacy: .public)")
                fallback = fallback ?? Status(model: model, percent: nil, isCharging: false)
                continue
            }
            if let raw = query(device, command: batteryCommand, productID: model.productID) {
                let charging = query(device, command: chargingCommand, productID: model.productID).map { $0 == 1 } ?? false
                return Status(model: model, percent: percent(fromRaw: raw), isCharging: charging)
            }
            fallback = fallback ?? Status(model: model, percent: nil, isCharging: false)
        }
        return fallback
    }

    private nonisolated static func attachedDevices() -> [(io_service_t, Model)] {
        var result: [(io_service_t, Model)] = []
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            // Every device of the class, filtered here: an `idVendor` key in the
            // matching dictionary matched nothing on macOS 27 (verified with a
            // Viper Ultimate dongle attached), so the vendor is checked by hand.
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
                    == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                func number(_ key: String) -> Int? {
                    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? NSNumber)?.intValue
                }
                if number("idVendor") == vendorID, let pid = number("idProduct"), let model = model(for: pid) {
                    result.append((service, model))
                } else {
                    IOObjectRelease(service)
                }
            }
            if !result.isEmpty { break }
        }
        return result
    }

    private nonisolated static func query(_ device: DeviceInterface, command: (cls: UInt8, id: UInt8),
                                          productID: Int) -> UInt8? {
        let pidText = String(format: "0x%04X", productID)
        var ids = transactionIDs
        if let known = workingTransactionID[productID] {
            ids.removeAll { $0 == known }
            ids.insert(known, at: 0)
        }
        for tid in ids {
            let request = makeReport(commandClass: command.cls, commandID: command.id, transactionID: tid)
            let sent = device.controlRequest(requestType: 0x21, request: 0x09, data: request)
            guard sent.status == kIOReturnSuccess else {
                Log.mouse.info("\(pidText, privacy: .public) SET_REPORT failed: \(sent.status, privacy: .public)")
                return nil
            }
            usleep(60_000)
            let received = device.controlRequest(requestType: 0xA1, request: 0x01,
                                                 data: [UInt8](repeating: 0, count: reportLength))
            guard received.status == kIOReturnSuccess else {
                Log.mouse.info("\(pidText, privacy: .public) GET_REPORT failed: \(received.status, privacy: .public)")
                return nil
            }
            switch parse(response: received.data, request: request) {
            case .success(let value):
                workingTransactionID[productID] = tid
                Log.mouse.info("\(pidText, privacy: .public) cmd \(command.id, privacy: .public) tid \(tid, privacy: .public) → \(value, privacy: .public)")
                return value
            case .failure(let error):
                Log.mouse.info("\(pidText, privacy: .public) cmd \(command.id, privacy: .public) tid \(tid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }
}

// MARK: - IOUSBDeviceInterface plumbing

/// The CFPlugIn dance for a USB device interface. The UUIDs are macros in the C
/// headers, which Swift does not import, so they are spelled out here.
private final class DeviceInterface {
    private static let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4, 0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let deviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4, 0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    private let device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>

    init?(service: io_service_t) {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = IOCreatePlugInInterfaceForService(service, Self.userClientTypeID, Self.plugInInterfaceID,
                                                        &plugIn, &score)
        guard created == kIOReturnSuccess, let plugIn, let plugInVtable = plugIn.pointee?.pointee else {
            return nil
        }
        defer { _ = plugInVtable.Release(plugIn) }

        var device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
        let queried = withUnsafeMutablePointer(to: &device) { pointer in
            pointer.withMemoryRebound(to: LPVOID?.self, capacity: 1) {
                plugInVtable.QueryInterface(plugIn, CFUUIDGetUUIDBytes(Self.deviceInterfaceID), $0)
            }
        }
        guard queried == S_OK, let device else { return nil }
        self.device = device
    }

    deinit {
        _ = device.pointee?.pointee.Release(device)
    }

    /// One control transfer on the default pipe: `wValue 0x0300` (feature
    /// report, ID 0), `wIndex 0`. Returns the buffer as the device left it.
    func controlRequest(requestType: UInt8, request: UInt8, data: [UInt8]) -> (status: IOReturn, data: [UInt8]) {
        guard let vtable = device.pointee?.pointee else { return (kIOReturnError, data) }
        var buffer = data
        let status: IOReturn = buffer.withUnsafeMutableBytes { bytes in
            var req = IOUSBDevRequest(bmRequestType: requestType, bRequest: request,
                                      wValue: 0x0300, wIndex: 0, wLength: UInt16(bytes.count),
                                      pData: bytes.baseAddress, wLenDone: 0)
            return vtable.DeviceRequest(device, &req)
        }
        return (status, buffer)
    }
}
