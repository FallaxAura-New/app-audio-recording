using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace NRadioRecorder.Windows;

internal sealed class RecordingService : IAsyncDisposable
{
    private readonly object writerLock = new();
    private WasapiRecorder? recorder;
    private CaptureDataAvailableHandler? dataHandler;
    private WaveFileWriter? writer;
    private string? temporaryWavePath;
    private string? outputPath;
    private long capturedBytes;

    public bool IsRecording => recorder is not null;

    public async Task StartAsync(uint processId, string targetOutputPath)
    {
        if (IsRecording)
        {
            throw new InvalidOperationException("已经有一项录音正在进行。");
        }

        Directory.CreateDirectory(Path.GetDirectoryName(targetOutputPath)!);
        var tempDirectory = Path.Combine(Path.GetTempPath(), "NRadioRecorder");
        Directory.CreateDirectory(tempDirectory);

        temporaryWavePath = Path.Combine(tempDirectory, $"{Guid.NewGuid():N}.wav");
        outputPath = targetOutputPath;
        capturedBytes = 0;

        try
        {
            recorder = await new WasapiRecorderBuilder()
                .WithProcessLoopback(processId, ProcessLoopbackMode.IncludeTargetProcessTree)
                .WithFormat(WaveFormat.CreateIeeeFloatWaveFormat(48_000, 2))
                .BuildAsync();

            writer = new WaveFileWriter(temporaryWavePath, recorder.WaveFormat);
            dataHandler = (buffer, flags, _, _) =>
            {
                if (buffer.IsEmpty || flags.HasFlag(AudioClientBufferFlags.Silent))
                {
                    return;
                }

                lock (writerLock)
                {
                    writer?.Write(buffer);
                    capturedBytes += buffer.Length;
                }
            };
            recorder.DataAvailable += dataHandler;
            recorder.StartRecording();
        }
        catch
        {
            await CleanupAsync(deleteTemporaryFile: true);
            throw;
        }
    }

    public async Task<string> StopAsync()
    {
        if (recorder is null || writer is null || temporaryWavePath is null || outputPath is null)
        {
            throw new InvalidOperationException("当前没有正在进行的录音。");
        }

        var finalOutputPath = outputPath;
        var wavePath = temporaryWavePath;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        void OnStopped(object? _, StoppedEventArgs args)
        {
            if (args.Exception is not null)
            {
                stopped.TrySetException(args.Exception);
            }
            else
            {
                stopped.TrySetResult();
            }
        }

        recorder.RecordingStopped += OnStopped;

        try
        {
            recorder.StopRecording();
            await stopped.Task.WaitAsync(TimeSpan.FromSeconds(10));

            lock (writerLock)
            {
                writer.Dispose();
                writer = null;
            }

            if (capturedBytes == 0)
            {
                throw new InvalidOperationException("没有收到所选软件的声音，请确认它正在播放音频。");
            }

            using var reader = new WaveFileReader(wavePath);
            MediaFoundationEncoder.EncodeToAac(reader, finalOutputPath, 160_000);
            return finalOutputPath;
        }
        catch
        {
            TryDelete(finalOutputPath);
            throw;
        }
        finally
        {
            recorder.RecordingStopped -= OnStopped;
            await CleanupAsync(deleteTemporaryFile: true);
        }
    }

    private async Task CleanupAsync(bool deleteTemporaryFile)
    {
        var currentRecorder = recorder;
        recorder = null;

        if (currentRecorder is not null)
        {
            if (dataHandler is not null)
            {
                currentRecorder.DataAvailable -= dataHandler;
            }
            await currentRecorder.DisposeAsync();
        }
        dataHandler = null;

        lock (writerLock)
        {
            writer?.Dispose();
            writer = null;
        }

        if (deleteTemporaryFile && temporaryWavePath is not null)
        {
            TryDelete(temporaryWavePath);
        }

        temporaryWavePath = null;
        outputPath = null;
        capturedBytes = 0;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public async ValueTask DisposeAsync()
    {
        if (IsRecording)
        {
            try { await StopAsync(); }
            catch { await CleanupAsync(deleteTemporaryFile: true); }
        }
    }
}
