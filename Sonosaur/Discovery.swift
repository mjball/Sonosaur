import Foundation

/// Finds Sonos players on the LAN.
///
/// Strategy: fire ZoneGroupTopology directly at all ARP-cache hosts concurrently —
/// one HTTP round trip finds AND enumerates the whole household.
/// Fallback: full subnet scan using the real netmask (handles /22, /23, /24, …).
enum Discovery {

    private static let cacheKey = "sonosaur.knownHosts"
    private static let zonePath = "/ZoneGroupTopology/Control"
    private static let zoneService = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"

    // MARK: - Entry point

    static func discover() async -> [SonosDevice] {
        // Cached IPs first — cheapest.
        if let devices = await firstTopology(in: cachedHosts()), !devices.isEmpty {
            saveHosts(devices.map(\.host))
            return devices
        }
        // ARP cache — all recently-seen LAN hosts, no network permission required to read.
        if let devices = await firstTopology(in: hostsFromArpCache()), !devices.isEmpty {
            saveHosts(devices.map(\.host))
            return devices
        }
        // Full subnet scan fallback.
        if let devices = await firstTopology(in: subnetHostList()), !devices.isEmpty {
            saveHosts(devices.map(\.host))
            return devices
        }
        return []
    }

    // MARK: - Concurrent topology probe

    /// Fires ZoneGroupTopology at all `hosts` concurrently; returns devices from the first
    /// successful response. One round trip: find seed + enumerate the whole household.
    private static func firstTopology(in hosts: [String]) async -> [SonosDevice]? {
        guard !hosts.isEmpty else { return nil }
        return await withTaskGroup(of: [SonosDevice]?.self) { group in
            for host in hosts {
                group.addTask {
                    (try? await devicesViaZoneTopology(seedHost: host)).flatMap { $0.isEmpty ? nil : $0 }
                }
            }
            for await result in group {
                if let devices = result {
                    group.cancelAll()
                    return devices
                }
            }
            return nil
        }
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
        let rawState = try SoapClient.extractTag("ZoneGroupState", from: xml)
        let state = rawState
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#xD;", with: "")
        return parseZoneMembers(from: state)
    }

    // MARK: - ARP cache

    /// Reads all LAN IPs from the kernel ARP table (no network connection needed).
    private static func hostsFromArpCache() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-a"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pattern = #"\((\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: ns).compactMap { match in
            guard let r = Range(match.range(at: 1), in: output) else { return nil }
            let ip = String(output[r])
            return (ip == "127.0.0.1" || ip.hasPrefix("169.254")) ? nil : ip
        }
    }

    // MARK: - Subnet scan (fallback)

    private static func subnetHostList() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let curr = ptr {
            let fa = curr.pointee
            defer { ptr = fa.ifa_next }
            guard fa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: fa.ifa_name).hasPrefix("en")
            else { continue }

            var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var maskBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sa = fa.ifa_addr.pointee
            var sm = fa.ifa_netmask.pointee
            withUnsafeMutablePointer(to: &sa) { p in
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    inet_ntop(AF_INET, &$0.pointee.sin_addr, &addrBuf, socklen_t(INET_ADDRSTRLEN))
                }
            }
            withUnsafeMutablePointer(to: &sm) { p in
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    inet_ntop(AF_INET, &$0.pointee.sin_addr, &maskBuf, socklen_t(INET_ADDRSTRLEN))
                }
            }
            let ipStr = String(cString: addrBuf)
            let maskStr = String(cString: maskBuf)
            guard !ipStr.hasPrefix("127."), !ipStr.hasPrefix("169.254"),
                  let ipInt = ipToUInt32(ipStr),
                  let maskInt = ipToUInt32(maskStr), maskInt != 0
            else { continue }

            let network = ipInt & maskInt
            let broadcast = network | ~maskInt
            return ((network + 1)..<broadcast).map { uint32ToIP($0) }
        }
        return []
    }

    // MARK: - XML parsing

    private static func parseZoneMembers(from xml: String) -> [SonosDevice] {
        let memberPattern = #"<Zone(?:Group)?Member\s([^>]*/?>)"#
        guard let memberRegex = try? NSRegularExpression(
            pattern: memberPattern, options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let ns = NSRange(xml.startIndex..., in: xml)
        var seen = Set<String>()
        var devices: [SonosDevice] = []
        for match in memberRegex.matches(in: xml, range: ns) {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let attrs = String(xml[range])
            guard let uuid = xmlAttr("UUID", from: attrs),
                  let location = xmlAttr("Location", from: attrs),
                  let roomName = xmlAttr("ZoneName", from: attrs),
                  let host = URL(string: location)?.host,
                  !seen.contains(uuid)
            else { continue }
            seen.insert(uuid)
            devices.append(SonosDevice(id: uuid, roomName: roomName, host: host, volume: 0))
        }
        return devices.sorted { $0.roomName < $1.roomName }
    }

    private static func xmlAttr(_ name: String, from attrs: String) -> String? {
        let pattern = #"\b"# + name + #"="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
              let r = Range(m.range(at: 1), in: attrs)
        else { return nil }
        return String(attrs[r])
    }

    // MARK: - IP helpers

    private static func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    private static func uint32ToIP(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    // MARK: - Cache

    static func cachedHosts() -> [String] {
        UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
    }

    static func saveHosts(_ hosts: [String]) {
        UserDefaults.standard.set(hosts, forKey: cacheKey)
    }
}
