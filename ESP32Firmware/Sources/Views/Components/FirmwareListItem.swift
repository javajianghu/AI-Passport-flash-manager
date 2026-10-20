import SwiftUI

struct FirmwareListItem: View {
    let firmware: Firmware
    let isConnected: Bool
    let onImport: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // 文件图标
            Image(systemName: "doc.fill")
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40)

            // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                Text(firmware.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Text(firmware.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack {
                    Text(firmware.formattedDate)
                    Text("•")
                    Text(firmware.sizeDescription)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                // 如果有自定义名称，显示原始名称
                if let customName = firmware.customName {
                    Text("原始: \(firmware.originalName)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onRename) {
                    Label("重命名", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button(action: onImport) {
                    Label("导入", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected)

                Button(action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.vertical, 8)
    }
}
