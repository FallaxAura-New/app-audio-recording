using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace NRadioRecorder.Windows;

internal sealed class RecordingService : IAsyncDisposable
{
    private sealed record Capture(WasapiRecorder Recorder, CaptureDataAvailableHandler Handler,
        EventHandler<StoppedEventArgs> StoppedHandler, TaskCompletionSource Completion);
    private readonly object audioLock = new();
    private readonly List<Capture> captures = new();
    private WavePcmWriter? writer;
    private AudioMixer? mixer;
    private MMDevice? microphoneDevice;
    private CancellationTokenSource? pumpCancellation;
    private Task? pumpTask;
    private string? wavePath;
    private string? outputPath;
    private RecordingFormat format;
    private long startTimestamp;
    private bool accepting;
    private bool stopping;
    private Exception? terminalError;

    public event Action<Exception>? Failed;
    public bool IsRecording { get { lock (audioLock) return writer is not null; } }
    public bool HasFailure { get { lock (audioLock) return terminalError is not null; } }
    public string? RecoverablePath { get; private set; }

    public async Task StartAsync(uint? processId, string? microphoneId, string targetOutputPath, RecordingFormat outputFormat)
    {
        if (IsRecording) throw new InvalidOperationException("已经有一项录音正在进行。");
        if (processId is null && microphoneId is null) throw new InvalidOperationException("请至少开启一个音频源。");
        if (processId is not null && !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
            throw new NotSupportedException("App 录音需要 Windows build 20348 或更高版本；可改为仅录麦克风。");
        if (File.Exists(targetOutputPath)) throw new IOException("输出文件已存在，请更换文件名。");
        Directory.CreateDirectory(Path.GetDirectoryName(targetOutputPath)!);
        format = outputFormat;
        outputPath = targetOutputPath;
        wavePath = format == RecordingFormat.Wav ? targetOutputPath : targetOutputPath + ".recording.wav";
        RecoverablePath = null;
        lock (audioLock)
        {
            stopping = false;
            terminalError = null;
        }

        try
        {
            if (processId is not null)
            {
                var recorder = await new WasapiRecorderBuilder()
                    .WithProcessLoopback(processId.Value, ProcessLoopbackMode.IncludeTargetProcessTree)
                    .WithFormat(WaveFormat.CreateIeeeFloatWaveFormat(AudioMixer.SampleRate, 2)).BuildAsync();
                Attach(recorder, AudioSource.Application);
            }
            if (microphoneId is not null)
            {
                using var enumerator = new MMDeviceEnumerator();
                microphoneDevice = enumerator.GetDevice(microphoneId);
                var recorder = await new WasapiRecorderBuilder().WithDevice(microphoneDevice)
                    .WithFormat(WaveFormat.CreateIeeeFloatWaveFormat(AudioMixer.SampleRate, 2)).BuildAsync();
                Attach(recorder, AudioSource.Microphone);
            }
            lock (audioLock)
            {
                writer = new WavePcmWriter(wavePath);
                RecoverablePath = wavePath;
                mixer = new AudioMixer(captures.Count);
                startTimestamp = Stopwatch.GetTimestamp();
                accepting = true;
            }
            pumpCancellation = new CancellationTokenSource();
            pumpTask = PumpAsync(pumpCancellation.Token);
            foreach (var capture in captures) capture.Recorder.StartRecording();
            lock (audioLock) if (terminalError is not null) throw terminalError;
        }
        catch (Exception startupError)
        {
            try { await CleanupAsync(); }
            catch (Exception cleanupError) { throw new AggregateException(startupError, cleanupError); }
            throw;
        }
    }

    private void Attach(WasapiRecorder recorder, AudioSource source)
    {
        CaptureDataAvailableHandler handler = (buffer, flags, _, qpc) =>
        {
            lock (audioLock)
            {
                if (!accepting || mixer is null || buffer.IsEmpty) return;
                try
                {
                    var samples = flags.HasFlag(AudioClientBufferFlags.Silent)
                        ? new float[buffer.Length / sizeof(float)]
                        : MemoryMarshal.Cast<byte, float>(buffer).ToArray();
                    var now = Stopwatch.GetTimestamp();
                    var offset = qpc / 10_000_000.0 - startTimestamp / (double)Stopwatch.Frequency;
                    var elapsed = (now - startTimestamp) / (double)Stopwatch.Frequency;
                    if (flags.HasFlag(AudioClientBufferFlags.TimestampError) || qpc == 0 || Math.Abs(offset - elapsed) > 2)
                        offset = elapsed - samples.Length / 2.0 / AudioMixer.SampleRate;
                    mixer.Add(samples, source, (long)Math.Round(offset * AudioMixer.SampleRate));
                }
                catch (Exception ex) { Fail(ex); }
            }
        };
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<StoppedEventArgs> stoppedHandler = (_, args) =>
        {
            lock (audioLock)
            {
                if (!stopping) Fail(args.Exception ?? new InvalidOperationException("音频源已断开。"));
                else terminalError ??= args.Exception;
            }
            completion.TrySetResult();
        };
        recorder.DataAvailable += handler;
        recorder.RecordingStopped += stoppedHandler;
        captures.Add(new Capture(recorder, handler, stoppedHandler, completion));
    }

    private async Task PumpAsync(CancellationToken cancellation)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(20));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellation))
            {
                lock (audioLock)
                {
                    if (!accepting) continue;
                    var elapsed = (Stopwatch.GetTimestamp() - startTimestamp) / (double)Stopwatch.Frequency;
                    try { Flush((long)(Math.Max(0, elapsed - .3) * AudioMixer.SampleRate)); }
                    catch (Exception ex) { Fail(ex); }
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Flush(long endFrame)
    {
        if (mixer is null || writer is null) return;
        while (mixer.OutputFrame < endFrame) writer.Append(mixer.Read(endFrame));
    }

    private void Fail(Exception error)
    {
        if (terminalError is not null) return;
        terminalError = error;
        accepting = false;
        _ = Task.Run(() => Failed?.Invoke(error));
    }

    public async Task<string> StopAsync()
    {
        if (writer is null || wavePath is null || outputPath is null)
            throw new InvalidOperationException("当前没有正在进行的录音。");
        var endFrame = (long)((Stopwatch.GetTimestamp() - startTimestamp) /
            (double)Stopwatch.Frequency * AudioMixer.SampleRate);
        var finalPath = outputPath;
        var sourcePath = wavePath;
        Exception? failure;
        lock (audioLock)
        {
            stopping = true;
            failure = terminalError;
        }
        try
        {
            foreach (var capture in captures)
            {
                try { capture.Recorder.StopRecording(); }
                catch (Exception ex) { failure ??= ex; capture.Completion.TrySetResult(); }
            }
            foreach (var capture in captures)
            {
                try { await capture.Completion.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
                catch (Exception ex) { failure ??= ex; }
            }
            lock (audioLock)
            {
                accepting = false;
                failure ??= terminalError;
                Flush(endFrame);
                writer.Dispose();
                writer = null;
                if (mixer?.ReceivedFrames == 0) failure ??= new InvalidOperationException("没有收到音频，请确认音频源正在工作。");
            }
            if (failure is not null) throw failure;
            if (format == RecordingFormat.Mp3)
            {
                await Task.Run(() =>
                {
                    using var reader = new PcmRecordingReader(sourcePath);
                    using var destination = new FileStream(finalPath, FileMode.CreateNew, FileAccess.Write);
                    MediaFoundationEncoder.EncodeToMp3(reader, destination, 192_000);
                    destination.Flush(flushToDisk: true);
                });
                // A failed WAV cleanup does not invalidate the completed MP3.
                try { File.Delete(sourcePath); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            RecoverablePath = finalPath;
        }
        catch (Exception ex) { failure = ex; }
        try { await CleanupAsync(); }
        catch (Exception ex) { failure ??= ex; }
        if (failure is not null)
        {
            var preserved = RecoverablePath is not null && File.Exists(RecoverablePath)
                ? $"已写入的文件保留在：{RecoverablePath}"
                : "请检查所选保存目录";
            throw new InvalidOperationException($"停止录音失败：{failure.Message}。{preserved}", failure);
        }
        return finalPath;
    }

    private async Task CleanupAsync()
    {
        lock (audioLock)
        {
            stopping = true;
            accepting = false;
        }
        var errors = new List<Exception>();
        pumpCancellation?.Cancel();
        if (pumpTask is not null)
        {
            try { await pumpTask; }
            catch (Exception ex) { errors.Add(ex); }
        }
        pumpCancellation?.Dispose();
        pumpCancellation = null;
        pumpTask = null;
        var previousCaptures = captures.ToArray();
        captures.Clear();
        foreach (var capture in previousCaptures)
        {
            capture.Recorder.DataAvailable -= capture.Handler;
            capture.Recorder.RecordingStopped -= capture.StoppedHandler;
            try { await capture.Recorder.DisposeAsync(); }
            catch (Exception ex) { errors.Add(ex); }
        }
        try { microphoneDevice?.Dispose(); }
        catch (Exception ex) { errors.Add(ex); }
        microphoneDevice = null;
        WavePcmWriter? previousWriter;
        lock (audioLock)
        {
            previousWriter = writer;
            writer = null;
            mixer = null;
        }
        try { previousWriter?.Dispose(); }
        catch (Exception ex) { errors.Add(ex); }
        wavePath = outputPath = null;
        if (errors.Count > 0) throw new AggregateException("录音资源清理失败。", errors);
    }

    public async ValueTask DisposeAsync()
    {
        if (IsRecording) await StopAsync();
    }
}
