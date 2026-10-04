using System.Buffers.Binary;
using System.Text;
using NRadioRecorder.Windows;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

static byte[] ReadRecordingSnapshot(string path)
{
    // Windows checks sharing in both directions. This reader must permit the
    // writer's existing write access; the writer still denies other writers.
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
    var bytes = new byte[checked((int)stream.Length)];
    stream.ReadExactly(bytes);
    return bytes;
}

var mixed = new AudioMixer(2);
mixed.Add(new float[] { .6f, -.6f }, AudioSource.Application, 0);
mixed.Add(new float[] { .4f, -.4f }, AudioSource.Microphone, 0);
Check(mixed.Read(1).SequenceEqual(new float[] { .5f, -.5f }), "Two sources must be mixed at half gain.");

var single = new AudioMixer(1, 1024);
single.Add(new float[] { .75f, -.25f }, AudioSource.Microphone, 240);
var output = single.Read(480);
Check(output.Length == 960 && output[480] == .75f && output[481] == -.25f, "Single-source level or duration changed.");
Check(output.Take(480).All(sample => sample == 0), "Missing packets must remain silence.");
single.Read(1264);
Check(single.Read(1504).All(sample => sample == 0), "Ring wrap leaked old audio.");

var invalid = new AudioMixer(1);
invalid.Add(new float[] { float.NaN, 2, float.NegativeInfinity, -2 }, AudioSource.Application, 0);
Check(invalid.Read(2).SequenceEqual(new float[] { 0, 1, 0, -1 }), "Invalid values or clipping are unsafe.");
try { invalid.Add(new float[] { 1 }, AudioSource.Application, 2); throw new Exception("Odd buffer accepted."); }
catch (InvalidOperationException) { }

var large = WavePcmWriter.Header((ulong)uint.MaxValue + 1);
Check(large.Length == 80 && Encoding.ASCII.GetString(large, 0, 4) == "RF64" &&
    Encoding.ASCII.GetString(large, 12, 4) == "ds64", "Long WAV header is invalid.");

var path = Path.Combine(Path.GetTempPath(), $"NRadio-test-{Guid.NewGuid():N}.wav");
try
{
    using (var writer = new WavePcmWriter(path))
    {
        writer.Append(Enumerable.Repeat(.25f, 96_000).ToArray());
        var bytes = ReadRecordingSnapshot(path);
        Check(bytes.Length == 192_080 && BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(76)) == 192_000,
            "Checkpoint must expose one complete second of audio.");
        try { using var duplicate = new WavePcmWriter(path); throw new Exception("Existing file overwritten."); }
        catch (IOException) { }
        Check(ReadRecordingSnapshot(path).SequenceEqual(bytes), "Collision changed existing recording.");
    }
    Check(File.ReadAllBytes(path).Length == 192_080, "Finished recording is incomplete.");
}
finally { File.Delete(path); }

Console.WriteLine("Windows audio core: 5 groups passed (mixing, silence/ring, invalid samples, RF64, checkpoint/collision).");
