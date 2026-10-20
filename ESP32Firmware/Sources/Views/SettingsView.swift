import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("备份目录", text: $viewModel.backupDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("浏览...") {
                        viewModel.browseBackupDirectory()
                    }
                }

                Text("当前路径: \(viewModel.expandedBackupDirectory)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("备份目录")
            }

            Section {
                Toggle("导入时提示是否先导出当前固件", isOn: $viewModel.promptBeforeImport)
            } header: {
                Text("导入确认")
            } footer: {
                Text("开启后，导入固件前会提示是否先备份当前固件")
            }

            Section {
                Button("恢复默认设置") {
                    viewModel.resetToDefaults()
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 500)
        .padding()
    }
}
