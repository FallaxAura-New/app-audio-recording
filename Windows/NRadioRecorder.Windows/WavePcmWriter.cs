using System.Buffers;
using System.Buffers.Binary;
using System.Text;

namespace NRadioRecorder.Windows;

internal sealed class WavePcmWriter : IDisposable
{
    private readonly FileStream file;
    private ulong audioBytes;
    private int framesSinceFlush;
    private bool disposed;
    public const int HeaderSize = 80;

    public WavePcmWriter(string path)
    {
        file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        file.Write(Header(0));
    }

    public static byte[] Header(ulong audioBytes)
    {
        var header = new byte[HeaderSize];
        var riffBytes = audioBytes + HeaderSize - 8;
        var rf64 = riffBytes > uint.MaxValue;
        void Text(int at, string value) => Encoding.ASCII.GetBytes(value).CopyTo(header, at);
        void U16(int at, ushort value) => BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(at), value);
        void U32(int at, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(at), value);
        void U64(int at, ulong value) => BinaryPrimitives.WriteUInt64LittleEndian(header.AsSpan(at), value);
        Text(0, rf64 ? "RF64" : "RIFF"); U32(4, rf64 ? uint.MaxValue : (uint)riffBytes); Text(8, "WAVE");
        Text(12, rf64 ? "ds64" : "JUNK"); U32(16, 28);
        U64(20, riffBytes); U64(28, audioBytes); U64(36, audioBytes / 4); U32(44, 0);
        Text(48, "fmt "); U32(52, 16); U16(56, 1); U16(58, 2); U32(60, AudioMixer.SampleRate);
        U32(64, AudioMixer.SampleRate * 4); U16(68, 4); U16(70, 16);
        Text(72, "data"); U32(76, rf64 ? uint.MaxValue : (uint)audioBytes);
        return header;
    }

    public void Append(ReadOnlySpan<float> samples)
    {
        if (disposed || samples.Length % 2 != 0) throw new InvalidOperationException("音频写入器状态或 PCM 格式无效。");
        var bytes = ArrayPool<byte>.Shared.Rent(samples.Length * 2);
        try
        {
            for (var i = 0; i < samples.Length; i++)
            {
                var sample = float.IsFinite(samples[i]) ? Math.Clamp(samples[i], -1, 1) : 0;
                BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(i * 2), (short)MathF.Round(sample * 32767));
            }
            file.Write(bytes.AsSpan(0, samples.Length * 2));
            audioBytes += (ulong)samples.Length * 2;
        }
        finally { ArrayPool<byte>.Shared.Return(bytes); }
        framesSinceFlush += samples.Length / 2;
        if (framesSinceFlush >= AudioMixer.SampleRate) { Checkpoint(); framesSinceFlush = 0; }
    }

    public void Checkpoint()
    {
        var end = file.Position;
        file.Position = 0;
        file.Write(Header(audioBytes));
        file.Position = end;
        file.Flush(flushToDisk: true);
    }

    public void Dispose()
    {
        if (disposed) return;
        try { Checkpoint(); }
        finally { disposed = true; file.Dispose(); }
    }
}
