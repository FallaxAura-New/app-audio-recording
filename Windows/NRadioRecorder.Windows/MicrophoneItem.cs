using NAudio.CoreAudioApi;

namespace NRadioRecorder.Windows;

internal sealed record MicrophoneItem(string Id, string Name)
{
    public static List<MicrophoneItem> GetAvailable()
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<MicrophoneItem>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (device) result.Add(new MicrophoneItem(device.ID, device.FriendlyName));
        }
        return result.OrderBy(device => device.Name).ToList();
    }
}
