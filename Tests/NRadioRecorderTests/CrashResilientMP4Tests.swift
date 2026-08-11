import AVFoundation
import CoreMedia
import XCTest
@testable import NRadioRecorder

final class CrashResilientMP4Tests: XCTestCase {
    func testWriterUsesTenSecondMovieFragments() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NRadioRecorderTests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        CrashResilientMP4.configure(writer)

        XCTAssertTrue(writer.movieFragmentInterval.isNumeric)
        XCTAssertEqual(CMTimeGetSeconds(writer.movieFragmentInterval), 10, accuracy: 0.001)
        writer.cancelWriting()
    }
}
