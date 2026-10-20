import Foundation
import Combine
import Defaults

@MainActor
class DeviceViewModel: ObservableObject {
    @Published var deviceInfo: DeviceInfo = .disconnected
    @Published var isChecking = false
    @Published var errorMessage: String?

    private let espToolService = ESPToolService.shared
    private var timer: Timer?

    init() {
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    func startMonitoring() {
        // 每 2 秒检测一次设备
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDevice()
            }
        }
        timer?.fire()
    }

    func checkDevice() async {
        guard !espToolService.isRunning else { return }

        isChecking = true
        defer { isChecking = false }

        if let port = espToolService.findConnectedDevice() {
            // 设备已连接但未读取过信息，或者之前读取失败
            if deviceInfo.port.isEmpty || deviceInfo.port != port {
                do {
                    deviceInfo = try await espToolService.readDeviceInfo(port: port)
                    errorMessage = nil
                } catch {
                    // 读取失败时保留之前的设备信息，避免频繁触发重启
                    if deviceInfo.port.isEmpty {
                        deviceInfo = .disconnected
                    }
                    errorMessage = error.localizedDescription
                }
            }
            // 端口相同且已有信息，无需再次调用 flash_id（避免设备重启）
        } else {
            deviceInfo = .disconnected
            errorMessage = nil
        }
    }

    /// 手动刷新设备信息（用户主动触发）
    func refreshDeviceInfo() async {
        guard !espToolService.isRunning else { return }

        isChecking = true
        defer { isChecking = false }

        if let port = espToolService.findConnectedDevice() {
            do {
                deviceInfo = try await espToolService.readDeviceInfo(port: port)
                errorMessage = nil
            } catch {
                deviceInfo = .disconnected
                errorMessage = error.localizedDescription
            }
        } else {
            deviceInfo = .disconnected
            errorMessage = nil
        }
    }

    var isConnected: Bool {
        deviceInfo.isConnected
    }
}
