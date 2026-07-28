import SwiftUI

@main
struct FrEQApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Menu-bar only (LSUIElement). The dropdown is a compact launcher;
        // the full controls open in a resizable window (AppState.showMainWindow).
        // Monochrome template icon so it adapts to light/dark menu bars.
        MenuBarExtra("FrEQ", systemImage: "waveform") {
            MenuBarContent()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
