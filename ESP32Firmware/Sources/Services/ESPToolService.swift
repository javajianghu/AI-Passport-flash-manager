import Foundation
import Combine

enum ESPToolError: LocalizedError {
    case toolNotFound
    case deviceNotConnected
    case commandFailed(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "esptool.py 未安装。请运行: pip3 install esptool"
        case .deviceNotConnected:
            return "设备未连接"
        case .commandFailed(let message):
            return "命令执行失败: \(message)"
        case .timeout:
            return "操作超时"
        case .cancelled:
            return "操作已取消"
        }
    }
}

@MainActor
class ESPToolService: ObservableObject {
    static let shared = ESPToolService()

    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var progressMessage = ""

    private var currentProcess: Process?
    private let flashSize: Int64 = 0x800000  // 8MB

    private init() {}

    func checkToolInstalled() -> Bool {
        // 检查 Bundle 内是否包含 esptool.py
        if let resourcePath = Bundle.main.resourcePath {
            let esptoolPath = "\(resourcePath)/esptool_deps/esptool.py"
            return FileManager.default.fileExists(atPath: esptoolPath)
        }
        return false
    }

    func findConnectedDevice() -> String? {
        let fileManager = FileManager.default
        let devPath = "/dev"

        do {
            let items = try fileManager.contentsOfDirectory(atPath: devPath)
            let devices = items.filter { $0.hasPrefix("cu.usbmodem") }
            if let device = devices.sorted().first {
                return "\(devPath)/\(device)"
            }
        } catch {
            print("Error scanning /dev: \(error)")
        }
        return nil
    }

    func readDeviceInfo(port: String) async throws -> DeviceInfo {
        let result = try await runCommand([
            "--port", port,
            "flash_id"
        ])

        guard result.exitCode == 0 else {
            throw ESPToolError.commandFailed(result.stderr)
        }

        // 解析输出
        let lines = result.stdout.components(separatedBy: "\n")
        var chipType = "Unknown"
        var flashSize = "Unknown"
        var manufacturer = "Unknown"

        for line in lines {
            if line.contains("Chip type:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    chipType = parts[1].trimmingCharacters(in: .whitespaces)
                    // 提取芯片型号，如 "ESP32-C3 (revision v1.1)"
                    if let parenIdx = chipType.firstIndex(of: "(") {
                        chipType = String(chipType[..<parenIdx]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            if line.contains("Flash size:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    let fullLine = parts[1].trimmingCharacters(in: .whitespaces)
                    // 提取大小，如 "8MB"
                    let words = fullLine.components(separatedBy: " ")
                    if let size = words.first {
                        flashSize = size
                    }
                    // 提取厂商
                    if fullLine.contains("XMC") {
                        manufacturer = "XMC"
                    } else if fullLine.contains("GigaDevice") {
                        manufacturer = "GigaDevice"
                    }
                }
            }
        }

        // 获取 MAC 地址
        let macResult = try await runCommand([
            "--port", port,
            "read_mac"
        ])

        var macAddress = "Unknown"
        if macResult.exitCode == 0 {
            for line in macResult.stdout.components(separatedBy: "\n") {
                if line.contains("MAC:") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count > 1 {
                        macAddress = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        return DeviceInfo(
            port: port,
            chipType: chipType,
            chipRevision: "v1.x",
            macAddress: macAddress,
            flashSize: flashSize,
            flashManufacturer: manufacturer,
            crystalFrequency: "40MHz",
            firmwareVersion: nil,
            firmwareSize: flashSizeBytes(from: flashSize)
        )
    }

    private func flashSizeBytes(from sizeString: String) -> Int64? {
        let size = sizeString.replacingOccurrences(of: "MB", with: "").trimmingCharacters(in: .whitespaces)
        guard let mbSize = Int64(size) else { return nil }
        return mbSize * 1024 * 1024
    }

    func exportFirmware(port: String, macAddress: String, outputDirectory: String) async throws -> Firmware {
        isRunning = true
        progress = 0
        progressMessage = "准备导出固件..."

        defer {
            isRunning = false
            progress = 0
            progressMessage = ""
        }

        // 生成文件名
        let timestamp = formatTimestamp(Date())
        let macNoColon = macAddress.replacingOccurrences(of: ":", with: "").lowercased()
        let fileName = "\(macNoColon)_\(timestamp).bin"

        // 确保目录存在
        let fileManager = FileManager.default
        let expandedPath = (outputDirectory as NSString).expandingTildeInPath
        if !fileManager.fileExists(atPath: expandedPath) {
            try fileManager.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
        }

        let outputPath = (expandedPath as NSString).appendingPathComponent(fileName)
        progressMessage = "正在读取固件..."

        // 使用 esptool 读取固件
        let result = try await runCommandWithProgress(
            [
                "--port", port,
                "read_flash",
                "0x0",
                "0x800000",
                outputPath
            ],
            totalBytes: flashSize
        )

        guard result.exitCode == 0 else {
            // 清理可能生成的不完整文件
            try? fileManager.removeItem(atPath: outputPath)
            throw ESPToolError.commandFailed(result.stderr)
        }

        // 获取文件信息
        let attrs = try fileManager.attributesOfItem(atPath: outputPath)
        let size = attrs[.size] as? Int64 ?? 0

        return Firmware(
            originalName: fileName,
            path: outputPath,
            exportDate: Date(),
            size: size
        )
    }

    func importFirmware(port: String, firmwarePath: String) async throws {
        isRunning = true
        progress = 0
        progressMessage = "准备导入固件..."

        defer {
            isRunning = false
            progress = 0
            progressMessage = ""
        }

        progressMessage = "正在写入固件..."

        let result = try await runCommandWithProgress(
            [
                "--port", port,
                "write_flash",
                "0x0",
                firmwarePath
            ],
            totalBytes: flashSize
        )

        guard result.exitCode == 0 else {
            throw ESPToolError.commandFailed(result.stderr)
        }

        progressMessage = "固件写入完成"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    private func runCommand(_ arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            // 使用 Bundle 内的 esptool.py
            let esptoolPath = Bundle.main.resourcePath.map { "\($0)/esptool_deps/esptool.py" } ?? ""
            process.executableURL = URL(fileURLWithPath: esptoolPath)
            process.arguments = arguments

            // 设置 PYTHONPATH 以找到同目录下的 pyserial
            if let resourcePath = Bundle.main.resourcePath {
                process.environment = [
                    "PYTHONPATH": "\(resourcePath)/esptool_deps",
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
                ]
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                continuation.resume(returning: (stdout, stderr, process.terminationStatus))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runCommandWithProgress(_ arguments: [String], totalBytes: Int64) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            // 使用 Bundle 内的 esptool.py
            let esptoolPath = Bundle.main.resourcePath.map { "\($0)/esptool_deps/esptool.py" } ?? ""
            process.executableURL = URL(fileURLWithPath: esptoolPath)
            process.arguments = arguments

            // 设置 PYTHONPATH 以找到同目录下的 pyserial
            if let resourcePath = Bundle.main.resourcePath {
                process.environment = [
                    "PYTHONPATH": "\(resourcePath)/esptool_deps",
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
                ]
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            currentProcess = process

            // 监听输出以更新进度
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                if let output = String(data: data, encoding: .utf8) {
                    Task { @MainActor in
                        self?.parseProgress(from: output, totalBytes: totalBytes)
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()

                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                currentProcess = nil
                continuation.resume(returning: (stdout, stderr, process.terminationStatus))
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                currentProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func parseProgress(from output: String, totalBytes: Int64) {
        // 查找百分比
        guard let regex = try? NSRegularExpression(pattern: "(\\d+\\.?\\d*)%"),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return
        }

        let percentString = String(output[range])
        if let percent = Double(percentString) {
            progress = percent / 100.0
        }
    }

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
        progress = 0
        progressMessage = "已取消"
    }
}
