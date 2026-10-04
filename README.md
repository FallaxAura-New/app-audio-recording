# App Audio Recording / NRadio 直播录音

本地桌面录音工具，支持 macOS 和 Windows。可以录制指定 App 的声音、所选麦克风，或同时混录。只输出 WAV 或 MP3，不保存视频，不上传录音。

## 录音模式

App 音频与麦克风是两个独立开关，默认仅开启 App 音频：

- **仅 App**：开启 App 音频，关闭麦克风。
- **仅麦克风**：关闭 App 音频，开启麦克风；不需要打开其他 App。
- **混录**：同时开启两项，并选择 App 与麦克风设备。

两项都关闭时不能开始。录音中不能更换音频源、输出格式或保存目录。

## 使用方法

1. 选择录音模式；需要 App 音频时，先打开目标 App 并开始播放。
2. 刷新并选择 App 和／或麦克风。
3. 选择保存目录及 WAV／MP3。
4. 点击“开始录音”，结束时点击“停止并保存”。
5. 等待保存完成，再通过界面打开录音所在位置。

同名文件不会覆盖，文件名包含音频源和录制日期时间。

### 权限与声音范围

- macOS 录 App 音频需要“屏幕录制”或“屏幕与系统音频录制”权限，名称随系统版本而异。程序只注册音频输出，不保存画面。
- macOS 仅在开启麦克风并开始录音时请求麦克风权限。仅录麦克风不会建立 App 音频捕获，也不依赖屏幕录制权限。
- Windows 录麦克风需要在系统隐私设置中允许桌面应用访问麦克风。
- 录浏览器时，同一浏览器的其他标签页也可能被录入；Windows 会包含所选进程的子进程。请避免同时播放无关内容。
- 混录建议使用耳机，避免麦克风再次拾取扬声器声音。本程序不额外做回声消除、降噪或自动音量调整。

## 音频格式与保存方式

- **WAV**：48 kHz、16-bit PCM、双声道，未压缩，约 11.5 MB／分钟。
- **MP3**：192 kbps、双声道，约 1.4 MB／分钟，属于有损压缩。

混录按时间戳对齐，两路各使用 50% 音量以降低相加削波风险；仅录一路时保留原音量。没有音频数据的时间段会补静音，不会把静音时间删除。

WAV 每约一秒更新文件头并同步落盘。文件超出普通 RIFF 大小限制时自动使用 RF64，扩展名仍为 `.wav`；播放超大文件需要支持 RF64 的播放器。

两个平台的 MP3 保存流程不同：

- **macOS**：边录边编码，定期同步落盘，停止时写完尾部数据。
- **Windows**：先在保存目录写入 `<文件名>.mp3.recording.wav`，停止后通过 Media Foundation 转成 MP3。转换失败时保留 WAV；转换成功后尝试清理中间 WAV，无法删除时也会保留。

### 异常退出与恢复

正常退出已开始的录音会先停止并保存；保存失败时界面会报告错误，不代表已经得到完整文件。

强制退出、崩溃或断电时：

- WAV 已同步的数据会保留，但最后未同步的数据或文件头仍可能不完整。
- macOS MP3 已写入的完整帧通常可以解码，尾部未写完的数据可能丢失。
- Windows MP3 请检查同目录的 `.mp3.recording.wav`；转换未完成时优先使用这个 WAV。

异常保存不会主动删除已录音频。这些机制不能替代备份；长时间录音请确保磁盘空间充足。

## 系统要求与下载

- **macOS**：macOS 13 或更高版本。
- **Windows**：x64、Windows 10 2004（build 19041）或更高版本；指定 App 录音另需 build 20348 或更高版本，常规桌面系统建议 Windows 11。旧系统仍可仅录麦克风。参见 [Microsoft 应用回环示例](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)。

在仓库 **Releases** 页面下载已发布的 ZIP。Windows 包含运行时，解压后运行 `NRadioRecorder.exe`；macOS 打开应用包即可，不需要额外安装 LAME。

下载包的功能以对应标签的源码为准。提交或推送功能分支不会更新已有 Release；旧安装包可能仍是仅录 App、输出 MP4 的版本。未经付费签名的应用可能出现 Gatekeeper／SmartScreen 提示。

## 本地开发与构建

以下命令均在仓库根目录运行。

### macOS

构建需要 Swift 5.9+、macOS SDK 和 LAME；运行 XCTest 测试请使用完整 Xcode 的开发工具。安装好 Xcode 并完成首次启动后，可通过 `DEVELOPER_DIR` 指向它的 `Contents/Developer`，不必改变系统全局工具选择。

```bash
brew install lame
swift test --disable-sandbox
./scripts/build-app.sh
open "dist/NRadio 直播录音.app"
```

只有 Command Line Tools 时若出现 `unable to resolve module dependency: XCTest`，请改用完整 Xcode 工具链，而不是删除测试。

构建脚本将 LAME 动态库和许可证放入应用包。构建结果使用本机架构，不是 Universal 应用。也可通过 `LAME_PREFIX` 指定已有 LAME 安装位置。

开发运行：

```bash
./scripts/run-dev.sh
```

### Windows

构建需要兼容 `global.json` 的 .NET SDK：9.0.302 或更高的 9.0 SDK。只安装其他主版本可能无法运行项目命令；该选择由 [SDK roll-forward 规则](https://learn.microsoft.com/en-us/dotnet/core/tools/global-json)控制。

```powershell
dotnet run --project Tests/WindowsCoreTests/WindowsCoreTests.csproj -c Release
dotnet publish Windows/NRadioRecorder.Windows/NRadioRecorder.Windows.csproj `
  -c Release -r win-x64 --self-contained true -o publish/windows
```

输出在 `publish/windows`。Windows 音频捕获使用固定版本的 [NAudio](https://github.com/naudio/NAudio)，MP3 编码使用系统 Media Foundation。

## 测试与验收边界

macOS 测试覆盖单路／混录、静音时长、环形缓冲、异常数值、WAV 检查点与 RF64 文件头、防覆盖、44.1 kHz 单声道转换、三种模式的 WAV／MP3 音频轨道与时长，以及保存重入和失败状态。

Windows 音频核心测试覆盖混音、静音和缓冲、异常数值、RF64、WAV 检查点与防覆盖。这些测试可以在 macOS 或 Windows 上运行，但 Windows 文件共享行为需要 Windows runner 验证。

自动化测试使用合成声音或模拟保存，不会启动真实麦克风录制。核心测试和交叉编译不等于设备验收；发版前还应在两端分别对三种音频源与 WAV／MP3 的六种组合做短录音、停止、播放检查，并检查权限拒绝、设备断开与正常退出的反馈。

## GitHub 构建与发布

- **Build**：合入 `main`、提交 PR 或手动运行时，执行测试并构建两端 ZIP。任一平台测试失败时，该平台后续打包不会继续；成功构建的 ZIP 位于 Actions artifacts。
- **Release**：推送 `v*` 标签时，执行两端测试与构建；两端都成功后才创建 GitHub Release 并附加 ZIP。

本地构建不会触发远程发布。本项目不自动提交或推送代码。

## 隐私与许可证

录音保存在本机所选目录。应用没有网络上传、遥测或分析服务；构建时下载依赖不属于录音运行流程。

项目：[MIT](LICENSE)。Windows 音频依赖：[NAudio / MIT](https://github.com/naudio/NAudio)。macOS MP3 编码：[LAME](https://lame.sourceforge.io/)（动态链接，应用包包含 `LAME-COPYING` 和 `LAME-LICENSE`；源码与许可证以 LAME 官方发布为准）。
