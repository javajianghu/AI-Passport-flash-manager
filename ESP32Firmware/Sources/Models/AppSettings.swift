import Foundation
import Defaults

extension Defaults.Keys {
    static let backupDirectory = Key<String>("backupDirectory", default: "~/ESP32-bin-backup")
    static let promptBeforeImport = Key<Bool>("promptBeforeImport", default: true)
}

struct AppSettings: Codable, Defaults.Serializable {
    var backupDirectory: String
    var promptBeforeImport: Bool

    init(backupDirectory: String = "~/ESP32-bin-backup", promptBeforeImport: Bool = true) {
        self.backupDirectory = backupDirectory
        self.promptBeforeImport = promptBeforeImport
    }

    var expandedBackupDirectory: String {
        (backupDirectory as NSString).expandingTildeInPath
    }
}
