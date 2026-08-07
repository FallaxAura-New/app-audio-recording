# App Audio Recording / NRadio 直播录音

一个只录制指定软件声音的轻量桌面工具，支持 macOS 和 Windows。它不会调用麦克风，也不会写入屏幕画面；输出文件是仅包含 AAC 音频轨道的 `.mp4`，适合直播存档、转写、总结和知识库整理。

## 功能

- 从正在运行的软件中选择录音来源
- 只捕获该软件及其子进程播放的系统音频
- 不访问麦克风，不生成视频轨道
- 自由选择保存目录，文件名自动带日期时间
- macOS 使用 Apple ScreenCaptureKit
- Windows 使用 WASAPI Process Loopback 和 Media Foundation
- GitHub Actions 自动构建两端安装包

## 直接下载

进入仓库的 **Releases** 页面下载对应平台：

- `NRadioRecorder-macOS.zip`：macOS 13 或更高版本
- `NRadioRecorder-Windows-x64.zip`：Windows 10 2004（build 19041）或更高版本，64 位

Windows 包含运行时，解压后直接运行 `NRadioRecorder.exe`。未使用付费代码签名证书时，Windows SmartScreen 或 macOS Gatekeeper 可能会显示未知开发者提示。

## 使用方法

1. 先打开直播软件或浏览器并开始播放。
2. 打开 NRadio 直播录音，刷新并选择目标软件。
3. 选择录音保存位置，点击“开始录音”。
4. 直播结束后点击“停止并保存”，等待 MP4 编码完成。

Chrome、Edge 等浏览器会把标签页音频放在子进程中，Windows 版会包含所选主进程的子进程，macOS 版会包含所选应用的声音。为了避免混入其他内容，录音期间不要在同一浏览器中播放无关音视频。

## macOS 本地构建

需要 macOS 13+ 和 Swift 5.9+：

```bash
chmod +x scripts/*.sh
./scripts/build-app.sh
open "dist/NRadio 直播录音.app"
```

首次打开时，macOS 会请求“屏幕与系统音频录制”权限。虽然系统权限名称包含“屏幕”，本程序只注册音频输出，不会保存画面。

## Windows 本地构建

需要 Windows 10 2004+ 和 .NET 9 SDK：

```powershell
dotnet publish Windows/NRadioRecorder.Windows/NRadioRecorder.Windows.csproj `
  -c Release -r win-x64 --self-contained true -o publish/windows
```

Windows 版使用 [NAudio](https://github.com/naudio/NAudio) 3 的 WASAPI 进程回环接口。停止录制时，程序先结束无损临时音频流，再通过 Windows Media Foundation 编码为 160 kbps AAC/MP4，完成后自动清理临时文件。

## 发布 Release

推送形如 `v1.0.0` 的标签后，`.github/workflows/release.yml` 会自动构建 macOS 和 Windows ZIP，并创建 GitHub Release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 隐私

录音完全保存在本机。应用没有网络请求、遥测或分析服务，也不会上传录音。

## License

[MIT](LICENSE)。Windows 音频功能依赖同为 MIT License 的 [NAudio](https://github.com/naudio/NAudio)。
