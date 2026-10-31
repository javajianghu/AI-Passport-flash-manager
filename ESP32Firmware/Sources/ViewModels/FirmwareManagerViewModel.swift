import Foundation
import Combine
import Defaults

@MainActor
class FirmwareManagerViewModel: ObservableObject {
    @Published var firmwares: [Firmware] = []
    @Published var isExporting = false
    @Published var isImporting = false
    @Published var showImportConfirm = false
    @Published var showDeleteConfirm = false
    @Published var showRenameDialog = false
    @Published var selectedFirmware: Firmware?
    @Published var renameNewName = ""
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let espToolService = ESPToolService.shared
    private let fileService = FileService.shared

    var deviceViewModel: DeviceViewModel?

    var promptBeforeImport: Bool {
        Defaults[.promptBeforeImport]
    }

    var backupDirectory: String {
        Defaults[.backupDirectory]
    }

    func loadFirmwares() {
        firmwares = fileService.loadFirmwares(from: backupDirectory)
    }

    func exportFirmware() async {
        guard let device = deviceViewModel, device.isConnected else {
            errorMessage = "请先连接设备"
            return
        }

        isExporting = true
        errorMessage = nil
        successMessage = nil

        do {
            try fileService.ensureBackupDirectoryExists(backupDirectory)
            _ = try await espToolService.exportFirmware(
                port: device.deviceInfo.port,
                macAddress: device.deviceInfo.macAddress,
                outputDirectory: backupDirectory
            )
            loadFirmwares()
            successMessage = "固件导出成功"
        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
    }

    func prepareImport(_ firmware: Firmware) {
        selectedFirmware = firmware
        if promptBeforeImport {
            showImportConfirm = true
        } else {
            Task {
                await importFirmware()
            }
        }
    }

    func importFirmware(skipBackup: Bool = false) async {
        guard let firmware = selectedFirmware,
              let device = deviceViewModel,
              device.isConnected else {
            errorMessage = "请先连接设备"
            return
        }

        isImporting = true
        errorMessage = nil
        successMessage = nil
        showImportConfirm = false

        do {
            // 备份与写入交给 ESPToolService 在同一次设备独占内完成：
            // 若分两步执行，中间会放开端口，后台轮询可能插进来执行
            // flash-id，而 flash-id 会触发 ESP32 复位，打断随后的写入。
            let backup: FirmwareBackup? = (skipBackup && device.deviceInfo.macAddress != "Unknown")
                ? FirmwareBackup(
                    macAddress: device.deviceInfo.macAddress,
                    outputDirectory: backupDirectory
                )
                : nil

            successMessage = backup != nil ? "正在备份当前固件..." : "正在写入固件..."

            try await espToolService.importFirmware(
                port: device.deviceInfo.port,
                firmwarePath: firmware.path,
                backup: backup
            )

            loadFirmwares()
            successMessage = "固件导入成功"
        } catch {
            errorMessage = error.localizedDescription
        }

        isImporting = false
        selectedFirmware = nil
    }

    func prepareDelete(_ firmware: Firmware) {
        selectedFirmware = firmware
        showDeleteConfirm = true
    }

    func deleteFirmware() {
        guard let firmware = selectedFirmware else { return }

        do {
            try fileService.deleteFirmware(firmware, from: backupDirectory)
            loadFirmwares()
            successMessage = "固件已删除"
        } catch {
            errorMessage = error.localizedDescription
        }

        selectedFirmware = nil
        showDeleteConfirm = false
    }

    func prepareRename(_ firmware: Firmware) {
        selectedFirmware = firmware
        renameNewName = firmware.customName ?? firmware.originalName
        showRenameDialog = true
    }

    func renameFirmware() {
        guard let firmware = selectedFirmware else { return }

        do {
            try fileService.renameFirmware(firmware, newName: renameNewName, in: backupDirectory)
            loadFirmwares()
            successMessage = "固件已重命名"
        } catch {
            errorMessage = error.localizedDescription
        }

        selectedFirmware = nil
        showRenameDialog = false
        renameNewName = ""
    }

    func cancelImport() {
        espToolService.cancel()
        isImporting = false
        selectedFirmware = nil
        showImportConfirm = false
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}
