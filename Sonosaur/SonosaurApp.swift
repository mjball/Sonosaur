import SwiftUI

@main
struct SonosaurApp: App {
    @StateObject private var controller = SonosController()

    var body: some Scene {
        MenuBarExtra("Sonosaur", systemImage: "hifispeaker.2.fill") {
            MenuContent(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
