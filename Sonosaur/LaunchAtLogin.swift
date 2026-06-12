import ServiceManagement

/// Wraps SMAppService so the UI can bind to a simple Bool.
@MainActor
final class LaunchAtLogin: ObservableObject {

    static let shared = LaunchAtLogin()

    @Published var isEnabled: Bool {
        didSet { toggle(to: isEnabled) }
    }

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    private func toggle(to enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the published value if the system call failed.
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
