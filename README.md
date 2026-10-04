# App Audio Recording / NRadio 直播录音

轻量本地录音工具，提供 macOS 和 Windows 版本。可以录制指定 App 的声音、所选麦克风，或同时混录；输出只允许 WAV 或 MP3，不保存视频。

## 功能

- 默认仅录 App 音频，麦克风关闭
- App 音频与麦克风独立开关：仅 App、仅麦克风、两者混录
- 选择正在运行的 App、麦克风设备和保存目录
- 选择 WAV（48 kHz / 16-bit / 双声道）或 MP3（192 kbps / 双声道）
- 混录按时间戳对齐，两路各使用 50% 音量避免直接相加削波；单路保留原音量
- 静音不缩短录音；两路都关闭时无法开始
- 同名文件不覆盖，录音中不能更换音频源、输出格式或保存位置
- WAV 每秒更新文件头并同步落盘；超过 4 GiB 时自动改用 RF64
- macOS MP3 边录边编码，每秒同步落盘；正常退出会先保存
- Windows MP3 先录制同目录的 `.mp3.recording.wav`，停止后转换，转换成功才清理中间文件；失败或异常退出可保留 WAV
- 不上传音频，无网络请求或遥测

## 使用方法

1. 打开要录制的 App；录 App 音频时让它开始播放。
2. 勾选需要的音频源：
   - 仅 App：开启“App 音频”，关闭“麦克风”。
   - 仅麦克风：关闭“App 音频”，开启“麦克风”。
   - 混录：两者都开启。
3. 选择 App 和／或麦克风设备。
4. 选择保存目录及 WAV／MP3。
5. 点击“开始录音”，结束时点击“停止并保存”。

仅录麦克风不建立 App 音频捕获。macOS 开启 App 音频时需要“屏幕与系统音频录制”权限，但程序只注册音频输出，不保存画面；只有启用麦克风并开始录音时才请求麦克风权限。Windows 请在系统隐私设置中允许桌面应用访问麦克风。

Chrome、Edge 等浏览器的其他标签页可能属于同一 App／进程树。录音期间避免在同一浏览器中播放无关内容。混录建议使用耳机，以免麦克风再次拾取扬声器声音造成回声；本程序不额外做回声消除。

## 下载与系统要求

从仓库 Releases 下载对应平台的 ZIP。旧 Release 仍可能只有旧的 App 录音／MP4 功能，新代码需要重新构建发布。

- macOS 13+，本地构建需要 Swift 5.9+、Homebrew 和 LAME。
- Windows x64：麦克风录音可用于 Windows 10 2004+；指定进程音频捕获需要 Windows build 20348+（常规桌面版建议 Windows 11）。参见 [Microsoft 应用回环示例](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)。
- Windows ZIP 包含运行时，解压后运行 `NRadioRecorder.exe`。
- 未付费签名的程序可能显示 Gatekeeper／SmartScreen 提示。

## macOS 本地构建

```bash
brew install lame
./scripts/build-app.sh
open "dist/NRadio 直播录音.app"
```

构建脚本将 LAME 动态库及许可证打包到应用内，使用者不需要安装 Homebrew 或 LAME。当前打包架构跟随构建机器。

```bash
swift test --disable-sandbox
```

测试覆盖单路／混录、静音时长、环形缓冲、异常数值、WAV 检查点、RF64 文件头、文件防覆盖、44.1 kHz 单声道转换，以及三种模式的 WAV／MP3 音频轨道与时长。测试使用合成声音，不替代设备上的 App／麦克风实际录制验收。

## Windows 本地构建

需要 .NET 9 SDK：

```powershell
dotnet publish Windows/NRadioRecorder.Windows/NRadioRecorder.Windows.csproj `
  -c Release -r win-x64 --self-contained true -o publish/windows
```

Windows 使用 [NAudio](https://github.com/naudio/NAudio) 3 的 WASAPI 进程回环及麦克风捕获，并通过 Media Foundation 编码 MP3。WAV 中间文件会占用较多磁盘空间（约 11.5 MB／分钟）；MP3 转换失败时可直接使用保留的 WAV。

音频核心检查可在有 .NET 9 的 macOS 或 Windows 运行：

```bash
dotnet run --project Tests/WindowsCoreTests/WindowsCoreTests.csproj -c Release
```

核心检查与交叉编译不代表 Windows 真机的麦克风、WASAPI、Media Foundation 或界面已验收。

## 异常退出

WAV 每秒写入可读文件头，已同步的数据会保留，断电或强制退出仍可能损失最后的未同步数据。macOS MP3 已写入的完整帧通常可解码，但异常退出可能失去尾部帧。Windows MP3 异常退出时请使用同目录的 `.mp3.recording.wav`。停止或编码失败不会主动删除已录的 WAV。不要将这些机制当作备份。

## 发布

推送 `v*` 标签时，GitHub Actions 构建两端 ZIP 并创建 Release。此工作流不会因为本地构建自动发布。

## License

项目：[MIT](LICENSE)。Windows：[NAudio / MIT](https://github.com/naudio/NAudio)。macOS MP3 编码：[LAME / LGPL 2.0](https://lame.sourceforge.io/)（动态链接，应用包包含许可证；LAME 源码见其官网）。
