namespace NRadioRecorder.Windows;

internal enum RecordingFormat { Wav, Mp3 }
internal enum AudioSource { Application, Microphone }

internal sealed class AudioMixer
{
    public const int SampleRate = 48_000;
    private readonly float[] ring;
    private readonly int capacityFrames;
    private readonly float gain;
    private readonly Dictionary<AudioSource, long> sourceEnds = new();
    public long OutputFrame { get; private set; }
    public long ReceivedFrames { get; private set; }

    public AudioMixer(int sourceCount, int capacityFrames = SampleRate * 4)
    {
        this.capacityFrames = capacityFrames;
        ring = new float[capacityFrames * 2];
        gain = sourceCount > 1 ? .5f : 1f;
    }

    public void Add(ReadOnlySpan<float> samples, AudioSource source, long timestampFrame)
    {
        if (samples.Length % 2 != 0) throw new InvalidOperationException("音频数据不是有效的双声道 PCM。");
        var frames = samples.Length / 2;
        var start = timestampFrame;
        if (sourceEnds.TryGetValue(source, out var previous) && Math.Abs(previous - start) <= 96) start = previous;
        if (start >= OutputFrame + capacityFrames || start + frames > OutputFrame + capacityFrames)
            throw new InvalidOperationException("音频时间戳超出混音缓冲范围，录音已停止。");
        sourceEnds[source] = start + frames;
        ReceivedFrames += frames;
        for (var frame = 0; frame < frames; frame++)
        {
            var absolute = start + frame;
            if (absolute < OutputFrame) continue;
            var slot = (int)(absolute % capacityFrames) * 2;
            for (var channel = 0; channel < 2; channel++)
            {
                var sample = samples[frame * 2 + channel];
                ring[slot + channel] += (float.IsFinite(sample) ? sample : 0) * gain;
            }
        }
    }

    public float[] Read(long endFrame, int maximumFrames = 4096)
    {
        var frames = (int)Math.Max(0, Math.Min(maximumFrames, endFrame - OutputFrame));
        var output = new float[frames * 2];
        for (var frame = 0; frame < frames; frame++)
        {
            var slot = (int)(OutputFrame % capacityFrames) * 2;
            output[frame * 2] = Math.Clamp(ring[slot], -1f, 1f);
            output[frame * 2 + 1] = Math.Clamp(ring[slot + 1], -1f, 1f);
            ring[slot] = ring[slot + 1] = 0;
            OutputFrame++;
        }
        return output;
    }
}
