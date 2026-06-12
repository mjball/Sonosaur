import Foundation
import Network

/// Finds Sonos players on the LAN.
///
/// Strategy (no SSDP, no multicast entitlement):
/// 1. Load cached IPs from UserDefaults.
/// 2. Try each cached IP — if reachable, call ZoneGroupTopology to get all devices.
/// 3. If nothing cached or all stale, TCP-scan the local /24 on port 1400 (concurrency-limited).
/// 4. On success, save the found IPs so next relaunch is instant.
enum Discovery {

    private static let cacheKey = "sonosaur.knownHosts"
    private static let deviceDescPath = "/xml/device_description.xml"
    private static let zonePath = "/ZoneGroupTopology/Control"
    private static let zoneService = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"

    // MARK: - Entry point

    static func discover() async -> [SonosDevice] {
        let cached = cachedHosts()
        for host in cached {
            if let devices = try? await devicesViaZoneTopology(seedHost: host), !devices.isEmpty {
                return devices
            }
        }
        // Subnet scan
        guard let seedHost = await scanSubnet() else { return [] }
        let devices = (try? await devicesViaZoneTopology(seedHost: seedHost)) ?? []
        if !devices.isEmpty {
            saveHosts(devices.map(\.host))
        }
        return devices
    }

    // MARK: - ZoneGroupTopology

    static func devicesViaZoneTopology(seedHost: String) async throws -> [SonosDevice] {
        let xml = try await SoapClient.post(
            host: seedHost,
            path: zonePath,
            service: zoneService,
            action: "GetZoneGroupState",
            bodyXML: ""
        )
        // The state is URL-encoded XML inside <ZoneGroupState>…</ZoneGroupState>
        let rawState = try SoapClient.extractTag("ZoneGroupState", from: xml)
        let state = rawState
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#xD;", with: "")

        return parseZoneMembers(from: state)
    }

    // MARK: - XML parsing

    /// Pull ZoneMember elements: UUID, RoomName, Location (IP).
    private static func parseZoneMembers(from xml: String) -> [SonosDevice] {
        // Match <ZoneMember ... /> or <ZoneGroupMember ... />
        let memberPattern = #"<Zone(?:Group)?Member\s([^>]*/?>)"#
        guard let memberRegex = try? NSRegularExpression(pattern: memberPattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = NSRange(xml.startIndex..., in: xml)
        let matches = memberRegex.matches(in: xml, range: ns)

        var seen = Set<String>()
        var devices: [SonosDevice] = []

        for match in matches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let attrs = String(xml[range])

            guard
                let uuid = attr("UUID", from: attrs),
                let location = attr("Location", from: attrs),
                let roomName = attr("ZoneName", from: attrs),
                let host = hostFromLocation(location)
            else { continue }

            // Skip satellites / invisible slave units (no ZoneName or duplicate UUID)
            guard !seen.contains(uuid) else { continue }
            seen.insert(uuid)

            devices.append(SonosDevice(id: uuid, roomName: roomName, host: host, volume: 0))
        }

        return devices.sorted { $0.roomName < $1.roomName }
    }

    private static func attr(_ name: String, from attrs: String) -> String? {
        let pattern = #"\b"# + name + #"="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
              let r = Range(m.range(at: 1), in: attrs)
        else { return nil }
        return String(attrs[r])
    }

    private static func hostFromLocation(_ location: String) -> String? {
        // Location is like http://192.168.1.42:1400/xml/device_description.xml
        guard let url = URL(string: location) else { return nil }
        return url.host
    }

    // MARK: - Subnet scan

    private static func scanSubnet() async -> String? {
        guard let localIP = localIPv4() else { return nil }
        let prefix = localIP.components(separatedBy: ".").dropLast().joined(separator: ".")

        return await withTaskGroup(of: String?.self) { group in
            let semaphore = AsyncSemaphore(limit: 20)
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                group.addTask {
                    await semaphore.withPermit {
                        await isSonosHost(host) ? host : nil
                    }
                }
            }
            for await result in group {
                if let found = result {
                    group.cancelAll()
                    return found
                }
            }
            return nil
        }
    }

    private static func isSonosHost(_ host: String) async -> Bool {
        // Quick TCP connect on port 1400, 1-second timeout.
        await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: 1400,
                using: .tcp
            )
            var resolved = false
            let resolve: (Bool) -> Void = { ok in
                guard !resolved else { return }
                resolved = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: resolve(true)
                case .failed, .cancelled: resolve(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { resolve(false) }
        }
    }

    // MARK: - Local IP

    private static func localIPv4() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let curr = ptr {
            let fa = curr.pointee
            if fa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: fa.ifa_name)
                guard name.hasPrefix("en") else { ptr = fa.ifa_next; continue }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sa = fa.ifa_addr.pointee
                withUnsafeMutablePointer(to: &sa) { ptr in
                    ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                let ip = String(cString: buf)
                if !ip.hasPrefix("127.") {
                    addr = ip
                    break
                }
            }
            ptr = fa.ifa_next
        }
        return addr
    }

    // MARK: - Cache

    private static func cachedHosts() -> [String] {
        UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
    }

    static func saveHosts(_ hosts: [String]) {
        UserDefaults.standard.set(hosts, forKey: cacheKey)
    }
}

// MARK: - Tiny async semaphore (replaces DispatchSemaphore in async context)

actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { count = limit }

    func withPermit<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { Task { await self.release() } }
        return await body()
    }

    private func acquire() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}
