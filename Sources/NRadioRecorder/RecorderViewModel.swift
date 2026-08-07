import AppKit
import Foundation
import ScreenCaptureKit

struct ApplicationSource: Identifiable {
    let application: SCRunningApplication

    var id: String { "\(application.bundleIdentifier)-\(application.processID)" }
    var name: String { application.applicationName }
    var bundleIdentifier: String { application.bundleIdentifier }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var applications: [ApplicationSource] = []
    @Published var selectedApplicationID: String = ""
    @Published var outputDirectory: URL
    @Published var status = "正在读取可录音的软件…"
    @Published var isLoading = false
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastRecordingURL: URL?

    private let recorder = ApplicationAudioRecorder()
    private var timer: Timer?
    private var startedAt: Date?

    init() {
        let savedPath = UserDefaults.standard.string(forKey: "outputDirectory")
        if let savedPath {
            outputDirectory = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies", isDirectory: true)
                .appendingPathComponent("NRadio Live Recordings", isDirectory: true)
        }
    }

    var canStart: Bool {
        !selectedApplicationID.isEmpty && !isLoading && !isRecording
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    var selectedApplicationName: String {
        applications.first(where: { $0.id == selectedApplicationID })?.name ?? "未选择"
    }

    func loadApplications() async {
        guard !isRecording else { return }
        isLoading = true
        status = "正在读取可录音的软件…"
        defer { isLoading = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let visiblePIDs = Set(content.windows.compactMap { $0.owningApplication?.processID })

            applications = content.applications
                .filter { $0.processID != ownPID && visiblePIDs.contains($0.processID) }
                .map(ApplicationSource.init)
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            if !applications.contains(where: { $0.id == selectedApplicationID }) {
                selectedApplicationID = applications.first?.id ?? ""
            }
            status = applications.isEmpty
                ? "没有发现可录音的软件，请先打开直播软件后再刷新。"
                : "请选择正在播放直播的软件。"
        } catch {
            status = permissionMessage(for: error)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择录音保存位置"
        panel.prompt = "选择此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            UserDefaults.standard.set(url.path, forKey: "outputDirectory")
            status = "录音将保存到所选文件夹。"
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startRecording() async {
        guard let source = applications.first(where: { $0.id == selectedApplicationID }) else {
            status = "请先选择一个录音软件。"
            return
        }

        isLoading = true
        status = "正在准备音频录制…"
        defer { isLoading = false }

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let outputURL = uniqueOutputURL(applicationName: source.name)
            try await recorder.start(
                application: source.application,
                outputURL: outputURL
            )
            lastRecordingURL = outputURL
            isRecording = true
            elapsed = 0
            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let startedAt = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
            status = "正在录制“\(source.name)”的声音，麦克风未启用。"
        } catch {
            status = "无法开始录音：\(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        timer?.invalidate()
        timer = nil
        isLoading = true
        status = "正在保存 MP4 文件…"

        do {
            try await recorder.stop()
            isRecording = false
            startedAt = nil
            status = "录音已保存，可以直接交给 Codex 转写和总结。"
        } catch {
            isRecording = false
            startedAt = nil
            status = "停止录音时出现问题：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func uniqueOutputURL(applicationName: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let safeName = applicationName
            .components(separatedBy: invalid)
            .joined(separator: "-")
        let filename = "张导直播_\(safeName)_\(formatter.string(from: Date())).mp4"
        return outputDirectory.appendingPathComponent(filename)
    }

    private func permissionMessage(for error: Error) -> String {
        "无法读取软件列表。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 NRadio 直播录音，然后重新打开应用。详情：\(error.localizedDescription)"
    }
}
