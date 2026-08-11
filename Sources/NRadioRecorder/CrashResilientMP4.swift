import AVFoundation
import CoreMedia

enum CrashResilientMP4 {
    /// Apple recommends ten seconds or longer for good write performance on external storage.
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    static func configure(_ writer: AVAssetWriter) {
        writer.movieFragmentInterval = fragmentInterval
    }
}
