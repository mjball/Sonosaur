import Foundation

@MainActor
final class SonosController: ObservableObject {

    @Published var devices: [SonosDevice] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let rcPath = "/MediaRenderer/RenderingControl/Control"
    private let rcService = "urn:schemas-upnp-org:service:RenderingControl:1"
    private var pendingSetVolume: [String: Task<Void, Never>] = [:]

    /// Kicked off immediately at init — discovery starts before the popover ever opens.
    init() {
        Task { await self.startBackgroundLoop() }
    }

    // MARK: - Background loop

    /// Discovers devices immediately, then silently re-discovers every 5 minutes.
    private func startBackgroundLoop() async {
        await refresh()
        while true {
            // Sleep off-actor so the main actor isn't tied up.
            try? await Task.sleep(for: .seconds(300))
            await silentRefresh()
        }
    }

    // MARK: - Discovery

    /// Full refresh with loading state — used on first launch and manual Refresh button.
    func refresh() async {
        isLoading = true
        errorMessage = nil
        let found = await Discovery.discover()
        if found.isEmpty {
            errorMessage = "No Sonos devices found on this network."
            isLoading = false
            return
        }
        await applyDiscoveredDevices(found)
        isLoading = false
    }

    /// Background re-discovery — updates volumes/device list without disrupting the UI.
    private func silentRefresh() async {
        let found = await Discovery.discover()
        guard !found.isEmpty else { return }
        await applyDiscoveredDevices(found)
    }

    /// Fetches current volumes for all discovered devices and merges into `devices`.
    private func applyDiscoveredDevices(_ found: [SonosDevice]) async {
        var updated = found
        await withTaskGroup(of: (Int, Double?).self) { group in
            for (i, device) in found.enumerated() {
                group.addTask { [device] in
                    let vol = try? await self.fetchVolume(device: device)
                    return (i, vol)
                }
            }
            for await (i, vol) in group {
                if let v = vol { updated[i].volume = v }
            }
        }
        // Preserve volumes of devices already showing if the new fetch failed.
        for i in updated.indices {
            if updated[i].volume == 0,
               let existing = devices.first(where: { $0.id == updated[i].id }) {
                updated[i].volume = existing.volume
            }
        }
        devices = updated
    }

    // MARK: - Volume

    func setVolume(device: SonosDevice, volume: Double) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx].volume = volume
        }
        pendingSetVolume[device.id]?.cancel()
        pendingSetVolume[device.id] = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            try? await self.sendSetVolume(device: device, volume: volume)
        }
    }

    func flushVolume(device: SonosDevice, volume: Double) {
        pendingSetVolume[device.id]?.cancel()
        pendingSetVolume[device.id] = nil
        Task { try? await self.sendSetVolume(device: device, volume: volume) }
    }

    // MARK: - SOAP

    private func fetchVolume(device: SonosDevice) async throws -> Double {
        let xml = try await SoapClient.post(
            host: device.host, path: rcPath, service: rcService, action: "GetVolume",
            bodyXML: "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        )
        let raw = try SoapClient.extractTag("CurrentVolume", from: xml)
        guard let val = Double(raw) else { throw SoapClient.SoapError.parseError(raw) }
        return val
    }

    private func sendSetVolume(device: SonosDevice, volume: Double) async throws {
        let clamped = Int(max(0, min(100, volume.rounded())))
        _ = try await SoapClient.post(
            host: device.host, path: rcPath, service: rcService, action: "SetVolume",
            bodyXML: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>"
        )
    }
}
