# App Audio Recording

macOS 和 Windows 录音工具。支持录制指定 App、麦克风或两者混录，保存为 WAV 或 MP3。默认只录 App 音频。

## 使用

从 [Releases](https://github.com/FallaxAura-New/app-audio-recording/releases) 下载对应平台的 ZIP，解压后运行。

- macOS 13+。
- Windows x64：仅录麦克风需要 Windows 10 2004+；录 App 需要 build 20348+，建议使用 Windows 11。

1. 勾选 App 音频、麦克风，或同时勾选两项。
2. 选择所需的 App 和麦克风设备。
3. 选择保存目录和格式，点击“开始录音”。
4. 结束时点击“停止并保存”。

macOS 录 App 需要屏幕录制权限，录麦克风需要麦克风权限。Windows 需允许桌面应用访问麦克风。

录浏览器时，其他标签页的声音也可能被录入。混录建议使用耳机，避免麦克风重复收音。

## 格式

- WAV：48 kHz、16-bit PCM、双声道。
- MP3：192 kbps、双声道。

Windows 的 MP3 在停止后转换；转换失败时，原始录音保留为同目录的 `.mp3.recording.wav`。

## 构建

### macOS

需要 Xcode 和 LAME。

```bash
brew install lame
swift test --disable-sandbox
./scripts/build-app.sh
```

输出：`dist/NRadio 直播录音.app`。

### Windows

需要 .NET 9 SDK（9.0.302 或更高的 9.0 版本）。

```powershell
dotnet run --project Tests/WindowsCoreTests/WindowsCoreTests.csproj -c Release
dotnet publish Windows/NRadioRecorder.Windows/NRadioRecorder.Windows.csproj `
  -c Release -r win-x64 --self-contained true -o publish/windows
```

## 发布

推送 `main` 会构建两端安装包，可在 Actions 下载。推送 `v*` 标签会创建 Release。

## 许可证

本项目使用 [MIT](LICENSE)。音频依赖：[NAudio（MIT）](https://github.com/naudio/NAudio)、[LAME（LGPL）](https://lame.sourceforge.io/)。macOS 应用包包含 LAME 许可证。
