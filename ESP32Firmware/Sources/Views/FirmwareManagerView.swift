import SwiftUI

struct FirmwareManagerView: View {
    @StateObject private var deviceViewModel = DeviceViewModel()
    @StateObject private var viewModel = FirmwareManagerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 设备状态
            DeviceStatusCard(
                deviceInfo: deviceViewModel.deviceInfo,
                isChecking: deviceViewModel.isChecking
            )
            .padding()

            Divider()

            // 固件列表
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.firmwares.isEmpty {
                        EmptyFirmwareView()
                    } else {
                        ForEach(viewModel.firmwares) { firmware in
                            FirmwareListItem(
                                firmware: firmware,
                                isConnected: deviceViewModel.isConnected,
                                isBusy: viewModel.isExporting || viewModel.isImporting,
                                onImport: {
                                    viewModel.prepareImport(firmware)
                                },
                                onDelete: {
                                    viewModel.prepareDelete(firmware)
                                },
                                onRename: {
                                    viewModel.prepareRename(firmware)
                                }
                            )
                            Divider()
                        }
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // 底部操作栏
            HStack {
                Spacer()

                Button(action: {
                    Task {
                        await viewModel.exportFirmware()
                    }
                }) {
                    Label("导出当前固件", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.borderedProminent)
                // 导入期间同样要禁用：串口同一时刻只能被一个 esptool 进程独占，
                // 两个进程抢同一个端口会失败并报 "port is busy"。
                .disabled(!deviceViewModel.isConnected || viewModel.isExporting || viewModel.isImporting)

                if viewModel.isExporting {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("导出中...")
                        .foregroundColor(.secondary)
                } else if viewModel.isImporting {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("导入中...")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .onAppear {
            viewModel.deviceViewModel = deviceViewModel
            viewModel.loadFirmwares()
        }
        .alert("导入固件", isPresented: $viewModel.showImportConfirm) {
            Button("导出后导入") {
                Task {
                    await viewModel.importFirmware(skipBackup: true)
                }
            }
            Button("直接导入") {
                Task {
                    await viewModel.importFirmware(skipBackup: false)
                }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelImport()
            }
        } message: {
            Text("导入前是否要先导出当前固件？")
        }
        .alert("删除固件", isPresented: $viewModel.showDeleteConfirm) {
            Button("删除", role: .destructive) {
                viewModel.deleteFirmware()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认删除此固件？此操作不可撤销。")
        }
        .alert("重命名固件", isPresented: $viewModel.showRenameDialog) {
            TextField("固件名称", text: $viewModel.renameNewName)
            Button("确定") {
                viewModel.renameFirmware()
            }
            Button("取消", role: .cancel) {
                viewModel.showRenameDialog = false
                viewModel.selectedFirmware = nil
                viewModel.renameNewName = ""
            }
        } message: {
            Text("输入新的固件名称")
        }
        .alert("错误", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("确定") {
                viewModel.clearMessages()
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .banner(data: Binding(
            get: { viewModel.successMessage.map { BannerData(message: $0, color: Color.green) } },
            set: { _ in viewModel.clearMessages() }
        ))
    }
}

struct EmptyFirmwareView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("暂无已导出的固件")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("连接设备后，点击「导出当前固件」开始备份")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// Banner 修饰器
struct BannerData: Equatable {
    let message: String
    let color: Color
}

struct BannerModifier: ViewModifier {
    @Binding var data: BannerData?
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let banner = data {
                HStack {
                    Text(banner.message)
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding()
                .background(banner.color)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            content
        }
        .animation(.easeInOut(duration: 0.3), value: data != nil)
        .onChange(of: data) { newData in
            hideTask?.cancel()
            if newData != nil {
                // 1.5 秒后自动隐藏
                hideTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        await MainActor.run {
                            data = nil
                        }
                    }
                }
            }
        }
    }
}

extension View {
    func banner(data: Binding<BannerData?>) -> some View {
        modifier(BannerModifier(data: data))
    }
}
