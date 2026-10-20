import Foundation
import Combine
import Defaults
import AppKit

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var backupDirectory: String {
        didSet {
            Defaults[.backupDirectory] = backupDirectory
        }
    }

    @Published var promptBeforeImport: Bool {
        didSet {
            Defaults[.promptBeforeImport] = promptBeforeImport
        }
    }

    init() {
        self.backupDirectory = Defaults[.backupDirectory]
        self.promptBeforeImport = Defaults[.promptBeforeImport]
    }

    func resetToDefaults() {
        backupDirectory = "~/ESP32-bin-backup"
        promptBeforeImport = true
    }

    func browseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择备份目录"

        if panel.runModal() == .OK, let url = panel.url {
            backupDirectory = url.path
        }
    }

    var expandedBackupDirectory: String {
        (backupDirectory as NSString).expandingTildeInPath
    }
}
