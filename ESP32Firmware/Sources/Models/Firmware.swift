import Foundation

struct Firmware: Identifiable, Equatable {
    let id: UUID
    let originalName: String  // 原始文件名（实际.bin文件名）
    var customName: String?   // 用户自定义名称
    let path: String
    let exportDate: Date
    let size: Int64

    var name: String {
        customName ?? originalName
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: exportDate)
    }

    init(originalName: String, customName: String? = nil, path: String, exportDate: Date, size: Int64) {
        self.id = UUID()
        self.originalName = originalName
        self.customName = customName
        self.path = path
        self.exportDate = exportDate
        self.size = size
    }
}
