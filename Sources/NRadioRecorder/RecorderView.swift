import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: RecorderViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.075, blue: 0.12),
                         Color(red: 0.10, green: 0.075, blue: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                header
                sourceSection
                destinationSection
                recordingPanel
                statusBar
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
        .task {
            await model.loadSources()
        }
        .onChange(of: model.applicationEnabled) { enabled in
            model.sourcesChanged()
            if enabled { Task { await model.loadApplications() } }
        }
        .onChange(of: model.microphoneEnabled) { _ in
            model.sourcesChanged()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("NRadio 直播录音")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("App 音频、麦克风或同时录制 · 只保存声音")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("录音来源 · 可以同时开启")
                .font(.headline)
            HStack(spacing: 10) {
                Toggle("App 音频", isOn: $model.applicationEnabled)
                    .toggleStyle(.checkbox)
                    .frame(width: 105, alignment: .leading)
                    .disabled(model.isRecording || model.isLoading)
                Picker("", selection: $model.selectedApplicationID) {
                    if model.applications.isEmpty {
                        Text("请先打开直播软件").tag("")
                    }
                    ForEach(model.applications) { source in
                        Text("\(source.name)  ·  \(source.bundleIdentifier)")
                            .tag(source.id)
                    }
                }
                .labelsHidden()
                .disabled(!model.applicationEnabled || model.isRecording || model.isLoading)

                Button {
                    Task { await model.loadApplications() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!model.applicationEnabled || model.isRecording || model.isLoading)
            }
            HStack(spacing: 10) {
                Toggle("麦克风", isOn: $model.microphoneEnabled)
                    .toggleStyle(.checkbox)
                    .frame(width: 105, alignment: .leading)
                    .disabled(model.isRecording || model.isLoading)
                Picker("", selection: $model.selectedMicrophoneID) {
                    if model.microphones.isEmpty { Text("未发现麦克风").tag("") }
                    ForEach(model.microphones) { source in Text(source.name).tag(source.id) }
                }
                .labelsHidden()
                .disabled(!model.microphoneEnabled || model.isRecording || model.isLoading)
                Button { model.loadMicrophones() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!model.microphoneEnabled || model.isRecording || model.isLoading)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("保存位置")
                .font(.headline)
            HStack(spacing: 10) {
                Text(model.outputDirectory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))

                Button("选择…") {
                    model.chooseOutputDirectory()
                }
                .disabled(model.isRecording || model.isLoading)
            }
            HStack(spacing: 12) {
                Text("输出格式").font(.headline)
                Picker("输出格式", selection: $model.outputFormat) {
                    ForEach(RecordingFormat.allCases) { format in Text(format.label).tag(format) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRecording || model.isLoading)
            }
        }
    }

    private var recordingPanel: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Color.red.opacity(0.18) : Color.white.opacity(0.07))
                    .frame(width: 84, height: 84)
                RoundedRectangle(cornerRadius: model.isRecording ? 5 : 17)
                    .fill(model.isRecording ? .red : .white.opacity(0.7))
                    .frame(width: model.isRecording ? 26 : 34, height: model.isRecording ? 26 : 34)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.isRecording ? "正在录制" : "准备录制")
                    .font(.system(size: 16, weight: .semibold))
                Text(model.elapsedText)
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                Text(model.isRecording ? model.sourceDescription : "输出为 \(model.outputFormat.rawValue.uppercased()) 音频")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.toggleRecording() }
            } label: {
                Text(model.isRecording ? "停止并保存" : "开始录音")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 108)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : Color(red: 0.46, green: 0.33, blue: 0.96))
            .disabled(model.isLoading || (!model.isRecording && !model.canStart))
        }
        .padding(20)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var statusBar: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: model.isRecording ? "waveform" : "info.circle")
                .foregroundStyle(model.isRecording ? .red : .secondary)
                .padding(.top, 1)
            Text(model.status)
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.lastRecordingURL != nil && !model.isRecording {
                Button("在访达中显示") {
                    model.revealLastRecording()
                }
                .buttonStyle(.link)
            }
            if model.microphoneEnabled {
                Button("麦克风权限") { model.openSystemSettings(microphone: true) }
                    .buttonStyle(.link)
            }
            if model.applicationEnabled {
                Button("App 录音权限") { model.openSystemSettings() }
                    .buttonStyle(.link)
            }
        }
    }
}
