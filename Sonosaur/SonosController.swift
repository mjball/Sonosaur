import Foundation

/// Owns the list of known Sonos devices and all SOAP calls to them.
///
/// Lives on the MainActor so every `@Published` mutation is safe to consume from SwiftUI.
@MainActor
final class SonosController: ObservableObject {

    @Published var devices: [SonosDevice] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let rcPath = "/MediaRenderer/RenderingControl/Control"
    private let rcService = "urn:schemas-upnp-org:service:RenderingControl:1"

    // Debounce: track the last-sent volume per device so we can coalesce rapid slider drags.
    private var pendingSetVolume: [String: Task<Void, Never>] = [:]

    // MARK: - Discovery

    func refresh() async {
        isLoading = true
        errorMessage = nil
        let found = await Discovery.discover()
        if found.isEmpty {
            errorMessage = "No Sonos devices found on this network."
            isLoading = false
            return
        }
        // Fetch current volumes for all found devices.
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
        devices = updated
        isLoading = false
    }

    // MARK: - Volume

    func setVolume(device: SonosDevice, volume: Double) {
        // Update the local model immediately so the slider feels snappy.
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx].volume = volume
        }

        // Cancel any pending SOAP call for this device, then schedule a new one
        // 80 ms out — rapid drags collapse into a single trailing call.
        pendingSetVolume[device.id]?.cancel()
        pendingSetVolume[device.id] = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            try? await self.sendSetVolume(device: device, volume: volume)
        }
    }

    /// Call this from the slider's `onEditingChanged(false)` to guarantee the
    /// final value is always flushed — even if the drag ended within the debounce window.
    func flushVolume(device: SonosDevice, volume: Double) {
        pendingSetVolume[device.id]?.cancel()
        pendingSetVolume[device.id] = nil
        Task { try? await self.sendSetVolume(device: device, volume: volume) }
    }

    // MARK: - SOAP primitives

    private func fetchVolume(device: SonosDevice) async throws -> Double {
        let xml = try await SoapClient.post(
            host: device.host,
            path: rcPath,
            service: rcService,
            action: "GetVolume",
            bodyXML: "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        )
        let raw = try SoapClient.extractTag("CurrentVolume", from: xml)
        guard let val = Double(raw) else { throw SoapClient.SoapError.parseError(raw) }
        return val
    }

    private func sendSetVolume(device: SonosDevice, volume: Double) async throws {
        let clamped = Int(max(0, min(100, volume.rounded())))
        _ = try await SoapClient.post(
            host: device.host,
            path: rcPath,
            service: rcService,
            action: "SetVolume",
            bodyXML: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>"
        )
    }
}
