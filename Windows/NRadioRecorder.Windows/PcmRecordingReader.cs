using NAudio.Wave;

namespace NRadioRecorder.Windows;

/// Reads our fixed 80-byte WAV/RF64 header without a 32-bit RIFF size limit.
internal sealed class PcmRecordingReader : WaveStream
{
    private readonly FileStream file;
    public PcmRecordingReader(string path)
    {
        file = File.OpenRead(path);
        file.Position = WavePcmWriter.HeaderSize;
    }
    public override WaveFormat WaveFormat { get; } = new(AudioMixer.SampleRate, 16, 2);
    public override long Length => file.Length - WavePcmWriter.HeaderSize;
    public override long Position
    {
        get => file.Position - WavePcmWriter.HeaderSize;
        set => file.Position = value + WavePcmWriter.HeaderSize;
    }
    public override int Read(byte[] buffer, int offset, int count) => file.Read(buffer, offset, count);
    protected override void Dispose(bool disposing)
    {
        if (disposing) file.Dispose();
        base.Dispose(disposing);
    }
}
