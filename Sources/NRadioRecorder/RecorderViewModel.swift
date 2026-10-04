import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ApplicationSource: Identifiable {
    let application: SCRunningApplication
    var id: String { "\(application.bundleIdentifier)-\(application.processID)" }
    var name: String { application.applicationName }
    var bundleIdentifier: String { application.bundleIdentifier }
}

struct MicrophoneSource: Identifiable {
    let device: AVCaptureDevice
    var id: String { device.uniqueID }
    var name: String { device.localizedName }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    static let shared = RecorderViewModel()
    @Published var applications: [ApplicationSource] = []
    @Published var microphones: [MicrophoneSource] = []
    @Published var selectedApplicationID = ""
    @Published var selectedMicrophoneID = ""
    @Published var applicationEnabled = true
    @Published var microphoneEnabled = false
    @Published var outputFormat: RecordingFormat {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: "outputFormat") }
    }
    @Published var outputDirectory: URL
    @Published var status = "正在读取录音来源…"
    @Published var isLoading = false
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastRecordingURL: URL?

    private let recorder: any AudioRecording
    private var timer: Timer?
    private var startedAt: Date?
    private var captureFailure: Error?
    private var stopTask: Task<Void, Never>?

    init(recorder: any AudioRecording = ApplicationAudioRecorder()) {
        self.recorder = recorder
        outputFormat = RecordingFormat(rawValue: UserDefaults.standard.string(forKey: "outputFormat") ?? "") ?? .wav
        if let path = UserDefaults.standard.string(forKey: "outputDirectory") {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies", isDirectory: true)
                .appendingPathComponent("NRadio Live Recordings", isDirectory: true)
        }
        recorder.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureFailure = error
                if self.isRecording && !self.isLoading {
                    await self.stopRecording()
                }
            }
        }
    }

    var canStart: Bool {
        let appReady = !applicationEnabled || applications.contains { $0.id == selectedApplicationID }
        let micReady = !microphoneEnabled || microphones.contains { $0.id == selectedMicrophoneID }
        return (applicationEnabled || microphoneEnabled) && appReady && micReady && !isLoading && !isRecording
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    var selectedApplicationName: String {
        applications.first(where: { $0.id == selectedApplicationID })?.name ?? "未选择 App"
    }

    var sourceDescription: String {
        var names: [String] = []
        if applicationEnabled { names.append(selectedApplicationName) }
        if microphoneEnabled {
            names.append(microphones.first(where: { $0.id == selectedMicrophoneID })?.name ?? "未选择麦克风")
        }
        return names.isEmpty ? "请至少开启一个音频源" : names.joined(separator: " + ")
    }

    func loadSources() async {
        loadMicrophones()
        if applicationEnabled && CGPreflightScreenCaptureAccess() { await loadApplications() }
        else if applicationEnabled {
            status = "录 App 音频请点击刷新并授权；仅录麦克风可关闭 App 音频，无需屏幕录制权限。"
        } else { status = "请选择麦克风，并点击开始录音。" }
    }

    func loadMicrophones() {
        guard !isRecording else { return }
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { deviceTypes = [.microphone] }
        else { deviceTypes = [.builtInMicrophone, .externalUnknown] }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified
        ).devices
            .map(MicrophoneSource.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.id ?? ""
        }
    }

    func loadApplications() async {
        guard !isRecording, !isLoading, applicationEnabled else { return }
        isLoading = true
        status = "正在读取可录音的软件…"
        defer { isLoading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let visiblePIDs = Set(content.windows.compactMap { $0.owningApplication?.processID })
            applications = content.applications
                .filter { $0.processID != ownPID && visiblePIDs.contains($0.processID) }
                .map(ApplicationSource.init)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !applications.contains(where: { $0.id == selectedApplicationID }) {
                selectedApplicationID = applications.first?.id ?? ""
            }
            status = applications.isEmpty
                ? "请先打开要录音的软件后再刷新；也可以关闭 App 音频，仅录麦克风。"
                : "选择音频源与输出格式后即可开始录音。"
        } catch {
            status = "无法读取 App 列表。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许本应用。仅录麦克风时可关闭 App 音频。详情：\(error.localizedDescription)"
        }
    }

    func sourcesChanged() {
        status = (applicationEnabled || microphoneEnabled)
            ? "已选择：\(sourceDescription)。"
            : "请至少开启 App 音频或麦克风中的一项。"
        loadMicrophones()
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
        guard !isLoading else { return }
        if isRecording { await stopRecording() } else { await startRecording() }
    }

    func prepareForTermination() async {
        guard isRecording else { return }
        await stopRecording()
    }

    func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSystemSettings(microphone: Bool = false) {
        let panel = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panel)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startRecording() async {
        guard canStart else { sourcesChanged(); return }
        let application = applicationEnabled ? applications.first { $0.id == selectedApplicationID }?.application : nil
        let microphone = microphoneEnabled ? microphones.first { $0.id == selectedMicrophoneID }?.device : nil
        isLoading = true
        captureFailure = nil
        status = "正在准备音频录制…"
        defer { isLoading = false }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let outputURL = uniqueOutputURL()
            try await recorder.start(application: application, microphone: microphone, outputURL: outputURL, format: outputFormat)
            if let captureFailure {
                try? await recorder.stop()
                throw captureFailure
            }
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
            status = "正在录制：\(sourceDescription) · \(outputFormat.rawValue.uppercased())"
        } catch {
            status = "无法开始录音：\(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        // A failure callback or Quit may arrive while a save is already running.
        // Join that save instead of starting another one or terminating early.
        if let stopTask { await stopTask.value; return }
        guard isRecording else { return }
        let task = Task { @MainActor [self] in await finishRecording() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func finishRecording() async {
        timer?.invalidate()
        timer = nil
        isLoading = true
        status = "正在保存 \(outputFormat.rawValue.uppercased()) 文件…"
        do {
            try await recorder.stop()
            status = "录音已保存。"
        } catch {
            status = "录音已停止：\(error.localizedDescription)。已写入的文件保留在所选目录。"
        }
        isRecording = false
        startedAt = nil
        isLoading = false
    }

    private func uniqueOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safeName = sourceDescription
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
        let stem = "录音_\(safeName)_\(formatter.string(from: Date()))"
        var candidate = outputDirectory.appendingPathComponent("\(stem).\(outputFormat.rawValue)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent("\(stem)-\(suffix).\(outputFormat.rawValue)")
            suffix += 1
        }
        return candidate
    }
}
