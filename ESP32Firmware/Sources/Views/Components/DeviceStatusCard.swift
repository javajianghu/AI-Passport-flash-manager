import SwiftUI

struct DeviceStatusCard: View {
    let deviceInfo: DeviceInfo
    let isChecking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: deviceInfo.isConnected ? "cable.connector" : "cable.connector.slash")
                    .font(.title2)
                    .foregroundColor(deviceInfo.isConnected ? .green : .secondary)

                Text(deviceInfo.isConnected ? "ESP32-C3 已连接" : "设备未连接")
                    .font(.headline)
            }

            if deviceInfo.isConnected {
                Divider()

                Group {
                    InfoRow(label: "MAC 地址", value: deviceInfo.macAddress)
                    InfoRow(label: "Flash 大小", value: "\(deviceInfo.flashSize) (\(deviceInfo.flashManufacturer))")
                    InfoRow(label: "芯片型号", value: deviceInfo.chipType)
                    InfoRow(label: "晶振频率", value: deviceInfo.crystalFrequency)

                    if let version = deviceInfo.firmwareVersion {
                        InfoRow(label: "固件版本", value: version)
                    }

                    if let size = deviceInfo.firmwareSize {
                        InfoRow(label: "固件大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
            } else {
                Text("请使用 USB 连接 ESP32-C3 设备")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if isChecking {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("检测设备中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}
