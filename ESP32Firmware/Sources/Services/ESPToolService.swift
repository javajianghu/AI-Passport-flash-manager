import Foundation
import Combine
import Darwin

enum ESPToolError: LocalizedError {
    case toolNotFound
    case deviceNotConnected
    case commandFailed(String)
    case timeout
    case cancelled
    /// 串口正被其它操作占用。
    case deviceBusy

    var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "未找到可用的 Python 解释器，无法运行内置 esptool"
        case .deviceNotConnected:
            return "设备未连接"
        case .commandFailed(let message):
            return "命令执行失败: \(message)"
        case .timeout:
            return "操作超时"
        case .cancelled:
            return "操作已取消"
        case .deviceBusy:
            return "设备正忙，请等待当前操作完成后再试"
        }
    }
}

/// 导入前备份当前固件所需的参数。
struct FirmwareBackup {
    /// 设备 MAC 地址，用于生成备份文件名。
    let macAddress: String
    /// 备份文件的存放目录。
    let outputDirectory: String
}

/// esptool 子进程的执行结果。
private struct ESPToolResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

@MainActor
class ESPToolService: ObservableObject {
    static let shared = ESPToolService()

    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var progressMessage = ""

    private var currentProcess: Process?
    private let flashSize: Int64 = 0x800000  // 8MB

    /// 进程内设备独占标志。
    ///
    /// 防止 App 自身重入（轮询撞上导出/导入）。跨进程互斥靠文件锁实现。
    private var hasDeviceLock = false

    /// 当前持有的设备文件锁描述符，释放时关闭。
    ///
    /// 静态存储：加锁/解锁都发生在 static 方法中。
    private static var deviceLockHandle: Int32 = -1

    /// 读取设备信息（flash-id / read-mac）的超时时间。
    /// 连接握手与 flash ID 查询在设备异常时可能长时间挂起。
    private let infoTimeout: TimeInterval = 15
    /// 读写整个 8MB flash 的超时时间。
    private let flashOperationTimeout: TimeInterval = 300

    private init() {}

    // MARK: - 设备独占

    /// 设备独占锁目录。
    ///
    /// 与 `esp32_firmware_cli.py` 使用同一路径，两侧才能共用一把跨进程锁。
    /// 放在 ~/Library/Caches 下，系统会自行清理。
    private static let lockDirectory: String = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let caches else {
            return NSHomeDirectory() + "/Library/Caches/cn.folotoy.ESP32Firmware/locks"
        }
        return caches.appendingPathComponent("cn.folotoy.ESP32Firmware/locks").path
    }()

    /// 按端口生成锁文件路径。
    ///
    /// 取端口名（去掉目录部分）作为文件名，不同端口之间不互相阻塞。
    private static func lockPath(forPort port: String) -> String {
        let deviceName = (port as NSString).lastPathComponent
        return (lockDirectory as NSString).appendingPathComponent("\(deviceName).lock")
    }

    /// 尝试占用设备。已被占用时返回 false。
    ///
    /// 同时持有两层锁：
    /// 1. 进程内标志 `hasDeviceLock` —— 防止 App 自身重入；
    /// 2. 跨进程文件锁（flock）—— 与命令行工具互斥。
    ///
    /// 跨进程锁很关键：ESP32 串口同一时刻只能被一个 esptool 进程独占，
    /// 两个进程同时打开会报 "[Errno 35] Resource temporarily unavailable"。
    private func acquireDeviceLock(port: String) -> Bool {
        guard !hasDeviceLock else { return false }

        guard Self.acquireFileLock(port: port) else { return false }

        hasDeviceLock = true
        isRunning = true
        return true
    }

    /// 释放设备占用。
    ///
    /// 必须在 esptool 子进程真正退出之后调用，否则轮询可能在旧进程
    /// 还没退干净时重新打开端口，再次撞上 Errno 35。
    private func releaseDeviceLock() {
        hasDeviceLock = false
        isRunning = false
        Self.releaseFileLock()
    }

    /// 尝试获取跨进程文件锁（非阻塞）。
    ///
    /// 返回 false 表示锁已被其它进程（另一个 CLI，或 App 的另一个实例）持有。
    private static func acquireFileLock(port: String) -> Bool {
        let fileManager = FileManager.default
        guard (try? fileManager.createDirectory(
            atPath: lockDirectory,
            withIntermediateDirectories: true
        )) != nil else {
            // 锁目录建不出来时不能静默放行——否则互斥失效，
            // 但也不能因此阻塞用户操作，退化为进程内互斥。
            return true
        }

        let path = lockPath(forPort: port)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }

        // LOCK_EX | LOCK_NB：拿不到立刻返回，而不是阻塞等待。
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        // 记录占用者信息，便于排查是谁占着设备
        ftruncate(fd, 0)
        let info = "pid=\(getpid())\n"
        _ = info.withCString { write(fd, $0, strlen($0)) }

        deviceLockHandle = fd
        return true
    }

    /// 释放跨进程文件锁。
    private static func releaseFileLock() {
        guard deviceLockHandle >= 0 else { return }
        _ = flock(deviceLockHandle, LOCK_UN)
        close(deviceLockHandle)
        deviceLockHandle = -1
    }

    // MARK: - 运行环境

    /// Bundle 内 esptool 依赖所在目录。
    private var esptoolDependenciesPath: String? {
        Bundle.main.resourcePath.map { "\($0)/esptool_deps" }
    }

    /// 挑选可用的 Python 解释器。
    ///
    /// 优先使用 macOS 自带的 `/usr/bin/python3`：它是系统保证存在的解释器，
    /// 且 vendored 依赖已针对其版本（当前为 3.9）打过兼容补丁。
    /// 其次尝试用户自行安装的 python3。
    private func resolvePythonPath() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        ]

        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// 校验内置 esptool 是否完整可用。
    ///
    /// 必需同时存在 esptool 包与 pyserial；缺一不可。
    func checkToolInstalled() -> Bool {
        guard let depsPath = esptoolDependenciesPath else { return false }
        let fileManager = FileManager.default

        let esptoolPackage = (depsPath as NSString).appendingPathComponent("esptool/__init__.py")
        let serialPackage = (depsPath as NSString).appendingPathComponent("serial/__init__.py")

        return fileManager.fileExists(atPath: esptoolPackage)
            && fileManager.fileExists(atPath: serialPackage)
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

    // MARK: - 设备信息

    func readDeviceInfo(port: String) async throws -> DeviceInfo {
        // 设备信息读取同样要独占端口：flash-id 会让 ESP32 复位，
        // 与并发的读写操作抢同一个串口会直接失败。
        guard acquireDeviceLock(port: port) else {
            throw ESPToolError.deviceBusy
        }
        defer { releaseDeviceLock() }

        let result = try await runCommand(
            ["--port", port, "flash-id"],
            timeout: infoTimeout
        )

        guard result.exitCode == 0 else {
            throw ESPToolError.commandFailed(result.stderr)
        }

        // 解析 esptool 输出。
        // esptool 5.x 的实际格式（冒号后用空格补齐对齐）：
        //   "Chip type:          ESP32-C3"
        //   "Detected flash size: 8MB"
        //   "Manufacturer:       c2"
        var chipType = "Unknown"
        var flashSize = "Unknown"
        var manufacturer = "Unknown"

        for line in result.stdout.components(separatedBy: "\n") {
            if let value = valueAfterColon(in: line, label: "Chip type") {
                // 形如 "ESP32-C3 (revision v1.1)"，只保留芯片型号
                chipType = value
                    .split(separator: "(")
                    .first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? value
            } else if let value = valueAfterColon(in: line, label: "Detected flash size") {
                flashSize = value
            } else if let value = valueAfterColon(in: line, label: "Manufacturer") {
                manufacturer = Self.mapManufacturer(value)
            }
        }

        // 读取 MAC 地址
        let macResult = try await runCommand(
            ["--port", port, "read-mac"],
            timeout: infoTimeout
        )

        var macAddress = "Unknown"
        if macResult.exitCode == 0 {
            for line in macResult.stdout.components(separatedBy: "\n") {
                // read-mac 会输出 MAC / BASE MAC / MAC_EXT 三行，取第一行 MAC。
                // 必须要求 "MAC:" 出现在行首，否则 "BASE MAC:" 会误匹配。
                if let value = valueAfterColon(in: line, label: "MAC", requiresLineStart: true),
                   value.contains(":") {
                    macAddress = value
                    break
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

    /// 从 "Label:    value" 中取出冒号后的值并去除首尾空白。
    ///
    /// esptool 用 `{'Chip type:':<20}` 形式对齐输出，因此冒号后可能跟多个空格。
    /// label 传 "Chip type"（不带冒号），由本方法补冒号。
    ///
    /// requiresLineStart 为 true 时要求 label 出现在行首，
    /// 用于避免 "BASE MAC:" 被 "MAC:" 误匹配。
    private func valueAfterColon(
        in line: String,
        label: String,
        requiresLineStart: Bool = false
    ) -> String? {
        let prefix = "\(label):"

        let valueStart: String.Index
        if requiresLineStart {
            guard line.hasPrefix(prefix) else { return nil }
            valueStart = line.index(line.startIndex, offsetBy: prefix.count)
        } else {
            guard let range = line.range(of: prefix) else { return nil }
            valueStart = range.upperBound
        }

        // 直接取冒号之后的整段文本：MAC 值本身含冒号（如 4c:11:ae:...），
        // 若在此处再按冒号切分会把地址拆坏。
        let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// esptool 只输出厂商 ID（十六进制），这里翻译成常见厂商名。
    ///
    /// 取值来自 esptool 源码中的厂商常量：
    ///   ADESTO_VENDOR_ID = 0x1F、XMC_VENDOR_ID = 0x20
    /// 其余为 SPI flash 常见厂商 ID。
    private static func mapManufacturer(_ rawValue: String) -> String {
        let known: [String: String] = [
            "c2": "GigaDevice",
            "ef": "Winbond",
            "20": "XMC",
            "1f": "Adesto",
            "68": "Boya",
            "85": "Puya",
            "5e": "Zhongtai",
            "01": "Samsung",
        ]
        return known[rawValue.lowercased()] ?? rawValue
    }

    private func flashSizeBytes(from sizeString: String) -> Int64? {
        let size = sizeString.replacingOccurrences(of: "MB", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let mbSize = Int64(size) else { return nil }
        return mbSize * 1024 * 1024
    }

    // MARK: - 固件读写

    func exportFirmware(port: String, macAddress: String, outputDirectory: String) async throws -> Firmware {
        guard acquireDeviceLock(port: port) else {
            throw ESPToolError.deviceBusy
        }
        defer { releaseDeviceLock() }

        return try await performExport(
            port: port,
            macAddress: macAddress,
            outputDirectory: outputDirectory
        )
    }

    /// 导入固件到设备；`backup` 非 nil 时先备份当前固件。
    ///
    /// 备份与写入必须在同一次设备独占内完成。若拆成两次调用，
    /// 中间会释放设备锁，后台轮询可能插进来执行 flash-id，
    /// 而 flash-id 会触发 ESP32 复位，从而打断随后的写入。
    func importFirmware(
        port: String,
        firmwarePath: String,
        backup: FirmwareBackup? = nil
    ) async throws {
        guard acquireDeviceLock(port: port) else {
            throw ESPToolError.deviceBusy
        }
        defer { releaseDeviceLock() }

        if let backup {
            _ = try await performExport(
                port: port,
                macAddress: backup.macAddress,
                outputDirectory: backup.outputDirectory
            )
        }

        try await performImport(port: port, firmwarePath: firmwarePath)
    }

    /// 读取固件到文件。调用方必须已持有设备独占。
    private func performExport(
        port: String,
        macAddress: String,
        outputDirectory: String
    ) async throws -> Firmware {
        progress = 0
        progressMessage = "准备导出固件..."

        defer {
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
                "read-flash",
                "0x0",
                "0x800000",
                outputPath
            ],
            totalBytes: flashSize,
            timeout: flashOperationTimeout
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

    /// 写入固件。调用方必须已持有设备独占。
    private func performImport(port: String, firmwarePath: String) async throws {
        progress = 0
        progressMessage = "正在写入固件..."

        defer {
            progress = 0
            progressMessage = ""
        }

        let result = try await runCommandWithProgress(
            [
                "--port", port,
                "write-flash",
                "0x0",
                firmwarePath
            ],
            totalBytes: flashSize,
            timeout: flashOperationTimeout
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

    // MARK: - 进程执行

    /// 组装子进程：使用 vendored esptool，以 `-m esptool` 方式调用。
    ///
    /// 不直接执行 `esptool.py` 脚本，因为该脚本的 shebang 指向某台开发机的
    /// 绝对路径，换机器即失效；`-m` 形式只依赖 PYTHONPATH 与解释器本身。
    private func makeProcess(arguments: [String]) throws -> Process {
        guard let pythonPath = resolvePythonPath() else {
            throw ESPToolError.toolNotFound
        }
        guard let depsPath = esptoolDependenciesPath else {
            throw ESPToolError.toolNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-m", "esptool"] + arguments

        var environment = ProcessInfo.processInfo.environment
        // PYTHONPATH 让解释器找到 vendored 的 esptool / serial 等依赖
        environment["PYTHONPATH"] = depsPath
        // 抑制 ANSI 控制字符，便于解析百分比进度
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment

        return process
    }

    /// 执行 esptool 命令并等待结束。
    ///
    /// 进程等待在后台线程完成，不阻塞主线程；超时后主动结束子进程。
    private func runCommand(
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> ESPToolResult {
        try await execute(arguments: arguments, timeout: timeout, progressHandler: nil)
    }

    /// 执行 esptool 命令并实时解析进度。
    private func runCommandWithProgress(
        _ arguments: [String],
        totalBytes: Int64,
        timeout: TimeInterval
    ) async throws -> ESPToolResult {
        try await execute(
            arguments: arguments,
            timeout: timeout,
            progressHandler: { [weak self] output in
                Task { @MainActor in
                    self?.parseProgress(from: output, totalBytes: totalBytes)
                }
            }
        )
    }

    /// 实际的进程执行逻辑。
    ///
    /// 关键点：
    /// - stdout / stderr 都在后台线程持续读取，避免管道缓冲区写满导致子进程阻塞；
    /// - 通过 `terminationHandler` 异步感知进程结束，不在主线程 `waitUntilExit()`；
    /// - 超时守护与正常结束通过 `ContinuationGuard` 竞争，保证 continuation 只恢复一次。
    private func execute(
        arguments: [String],
        timeout: TimeInterval,
        progressHandler: ((String) -> Void)?
    ) async throws -> ESPToolResult {
        let process = try makeProcess(arguments: arguments)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let guardState = ContinuationGuard()
            let stdoutBuffer = OutputBuffer()
            let stderrBuffer = OutputBuffer()
            let drainGroup = DispatchGroup()

            // stderr 单独在后台线程读取，避免缓冲区写满阻塞子进程
            drainGroup.enter()
            DispatchQueue.global().async {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                stderrBuffer.append(data)
                drainGroup.leave()
            }

            // stdout 通过 readabilityHandler 持续消费，同时累积完整输出
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                stdoutBuffer.append(data)
                if let output = String(data: data, encoding: .utf8) {
                    progressHandler?(output)
                }
            }

            process.terminationHandler = { finished in
                // 只有赢得竞争的一方负责恢复 continuation
                guard guardState.claim() else { return }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                // 读取 stdout 尾部剩余数据
                stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                // 等待 stderr 读完
                drainGroup.wait()

                continuation.resume(returning: ESPToolResult(
                    stdout: stdoutBuffer.string,
                    stderr: stderrBuffer.string,
                    exitCode: finished.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            currentProcess = process

            // 超时守护：到期后结束子进程
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard guardState.claim() else { return }
                guard process.isRunning else { return }

                process.terminate()
                // 给 SIGTERM 一点时间，未退出则强制结束
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ESPToolError.timeout)
            }
        }
    }

    /// 从 esptool 输出中解析百分比。
    ///
    /// esptool 5.x 的进度行形如 "... 45.3% ..."，非 TTY 环境下每行一次。
    private func parseProgress(from output: String, totalBytes: Int64) {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+\\.?\\d*)%"),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return
        }

        let percentString = String(output[range])
        if let percent = Double(percentString) {
            progress = min(percent / 100.0, 1.0)
        }
    }

    func cancel() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
        currentProcess = nil
        // 设备独占由调用方（exportFirmware / importFirmware / readDeviceInfo）
        // 在子进程退出后的 defer 中释放，这里不能提前释放：
        // 旧进程尚未退干净时放开锁，后台轮询会立刻重新打开端口并撞上 Errno 35。
        progress = 0
        progressMessage = "已取消"
    }
}

/// 保证 continuation 只被恢复一次。
///
/// 进程正常结束与超时守护可能几乎同时触发，若都调用 resume 会触发
/// "SWIFT TASK CONTINUATION MISUSE" 运行时崩溃。
private final class ContinuationGuard: @unchecked Sendable {
    private let mutex = NSLock()
    private var claimed = false

    /// 尝试认领恢复权；返回 true 表示本次调用是唯一认领者。
    func claim() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }

        if claimed { return false }
        claimed = true
        return true
    }
}

/// 线程安全的输出缓冲区。
private final class OutputBuffer: @unchecked Sendable {
    private let mutex = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        mutex.lock()
        data.append(newData)
        mutex.unlock()
    }

    var string: String {
        mutex.lock()
        defer { mutex.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
