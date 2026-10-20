import Foundation

struct DeviceInfo: Identifiable, Equatable {
    let id = UUID()
    let port: String
    let chipType: String
    let chipRevision: String
    let macAddress: String
    let flashSize: String
    let flashManufacturer: String
    let crystalFrequency: String
    let firmwareVersion: String?
    let firmwareSize: Int64?

    var isConnected: Bool {
        !port.isEmpty
    }

    var macAddressNoColon: String {
        macAddress.replacingOccurrences(of: ":", with: "")
    }

    var flashSizeBytes: Int64 {
        let sizeStr = flashSize.replacingOccurrences(of: "MB", with: "").trimmingCharacters(in: .whitespaces)
        guard let size = Int64(sizeStr) else { return 0 }
        return size * 1024 * 1024
    }

    static let disconnected = DeviceInfo(
        port: "",
        chipType: "",
        chipRevision: "",
        macAddress: "",
        flashSize: "",
        flashManufacturer: "",
        crystalFrequency: "",
        firmwareVersion: nil,
        firmwareSize: nil
    )
}
