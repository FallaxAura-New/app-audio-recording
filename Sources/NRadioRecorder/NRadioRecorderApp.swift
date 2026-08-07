import SwiftUI

@main
struct NRadioRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            RecorderView()
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
