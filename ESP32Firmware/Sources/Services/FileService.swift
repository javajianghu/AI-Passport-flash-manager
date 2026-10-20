import Foundation

class FileService {
    static let shared = FileService()

    private let namesFileName = ".firmware_names.json"

    private init() {}

    // MARK: - Firmware Loading

    func loadFirmwares(from directory: String) -> [Firmware] {
        let expandedPath = (directory as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: expandedPath) else {
            return []
        }

        // 加载自定义名称映射
        let customNames = loadCustomNames(from: expandedPath)

        do {
            let items = try fileManager.contentsOfDirectory(atPath: expandedPath)
            let binFiles = items.filter { $0.hasSuffix(".bin") }

            var firmwares: [Firmware] = []
            for fileName in binFiles {
                let filePath = (expandedPath as NSString).appendingPathComponent(fileName)
                let attrs = try fileManager.attributesOfItem(atPath: filePath)

                let size = attrs[.size] as? Int64 ?? 0
                let modDate = attrs[.modificationDate] as? Date ?? Date()

                firmwares.append(Firmware(
                    originalName: fileName,
                    customName: customNames[fileName],
                    path: filePath,
                    exportDate: modDate,
                    size: size
                ))
            }

            // 按日期降序排序
            return firmwares.sorted { $0.exportDate > $1.exportDate }
        } catch {
            print("Error loading firmwares: \(error)")
            return []
        }
    }

    // MARK: - Custom Names Persistence

    private func loadCustomNames(from directory: String) -> [String: String] {
        let namesFilePath = (directory as NSString).appendingPathComponent(namesFileName)

        guard FileManager.default.fileExists(atPath: namesFilePath),
              let data = FileManager.default.contents(atPath: namesFilePath),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        return names
    }

    private func saveCustomNames(_ names: [String: String], to directory: String) {
        let namesFilePath = (directory as NSString).appendingPathComponent(namesFileName)

        if let data = try? JSONEncoder().encode(names) {
            FileManager.default.createFile(atPath: namesFilePath, contents: data)
        }
    }

    func renameFirmware(_ firmware: Firmware, newName: String, in directory: String) throws {
        let expandedPath = (directory as NSString).expandingTildeInPath
        var customNames = loadCustomNames(from: expandedPath)

        if newName.isEmpty || newName == firmware.originalName {
            // 清除自定义名称
            customNames.removeValue(forKey: firmware.originalName)
        } else {
            customNames[firmware.originalName] = newName
        }

        saveCustomNames(customNames, to: expandedPath)
    }

    // MARK: - Firmware Operations

    func deleteFirmware(_ firmware: Firmware, from directory: String) throws {
        let expandedPath = (directory as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        // 删除固件文件
        try fileManager.removeItem(atPath: firmware.path)

        // 清理自定义名称
        var customNames = loadCustomNames(from: expandedPath)
        customNames.removeValue(forKey: firmware.originalName)
        saveCustomNames(customNames, to: expandedPath)
    }

    func ensureBackupDirectoryExists(_ path: String) throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: expandedPath) {
            try fileManager.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
        }
    }
}
