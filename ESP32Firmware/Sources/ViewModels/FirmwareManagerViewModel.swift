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
            // 如果需要先备份
            if skipBackup && device.deviceInfo.macAddress != "Unknown" {
                successMessage = "正在备份当前固件..."
                _ = try await espToolService.exportFirmware(
                    port: device.deviceInfo.port,
                    macAddress: device.deviceInfo.macAddress,
                    outputDirectory: backupDirectory
                )
                loadFirmwares()
            }

            successMessage = "正在写入固件..."
            try await espToolService.importFirmware(
                port: device.deviceInfo.port,
                firmwarePath: firmware.path
            )
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
