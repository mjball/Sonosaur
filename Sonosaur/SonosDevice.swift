import Foundation

/// A single Sonos player on the local network.
struct SonosDevice: Identifiable, Equatable {
    /// UUID from the UPnP device description — stable across reboots.
    let id: String
    /// Room/display name from ZoneGroupTopology.
    let roomName: String
    /// LAN host — may change if DHCP reassigns, but we re-discover on startup.
    let host: String
    /// 0–100, as reported by RenderingControl GetVolume.
    var volume: Double
}
