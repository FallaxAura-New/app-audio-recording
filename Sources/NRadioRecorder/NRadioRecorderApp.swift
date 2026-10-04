import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = RecorderViewModel.shared
        guard model.isRecording else { return .terminateNow }

        Task { @MainActor in
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct NRadioRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderViewModel.shared

    var body: some Scene {
        WindowGroup {
            RecorderView(model: model)
                .frame(minWidth: 700, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
