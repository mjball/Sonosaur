import Darwin

extension Discovery {

    static func gatewayMAC(in subnet: Subnet) -> String? {
        let routes = ipv4Routes()
        let defaultRoute = routes.first { route in
            route.isDefault && route.gatewayIP.map { subnet.contains($0) } == true
        }
        guard let gateway = defaultRoute?.gatewayIP else { return nil }
        return routes.first { $0.destinationIP == gateway && $0.gatewayMAC != nil }?.gatewayMAC
    }

    private struct Route {
        let isDefault: Bool
        let destinationIP: UInt32
        let gatewayIP: UInt32?
        let gatewayMAC: String?
    }

    private static func ipv4Routes() -> [Route] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }

        return buffer.prefix(length).withUnsafeBytes { raw in
            var routes: [Route] = []
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= raw.count {
                let header = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let messageLength = Int(header.pointee.rtm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                let addresses = socketAddresses(following: header)
                guard let destination = addresses[RTAX_DST].flatMap(ipv4) else { continue }
                let gateway = addresses[RTAX_GATEWAY]
                routes.append(Route(
                    isDefault: destination == 0 && header.pointee.rtm_flags & RTF_GATEWAY != 0,
                    destinationIP: destination,
                    gatewayIP: gateway.flatMap(ipv4),
                    gatewayMAC: gateway.flatMap(macAddress)
                ))
            }
            return routes
        }
    }

    // Each sockaddr after the header is padded to a 4-byte boundary (ROUNDUP in net/route.h).
    private static func socketAddresses(following header: UnsafePointer<rt_msghdr>) -> [Int32: UnsafePointer<sockaddr>] {
        var addresses: [Int32: UnsafePointer<sockaddr>] = [:]
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<rt_msghdr>.size)
        for index in 0..<RTAX_MAX where header.pointee.rtm_addrs & (1 << index) != 0 {
            let address = cursor.assumingMemoryBound(to: sockaddr.self)
            addresses[index] = address
            let length = Int(address.pointee.sa_len)
            cursor = cursor.advanced(by: length > 0 ? 1 + ((length - 1) | 3) : 4)
        }
        return addresses
    }

    private static func ipv4(_ address: UnsafePointer<sockaddr>) -> UInt32? {
        guard address.pointee.sa_family == AF_INET else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }

    private static func macAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        guard address.pointee.sa_family == AF_LINK else { return nil }
        return address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            guard link.pointee.sdl_alen == 6,
                  let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)
            else { return nil }
            let bytes = UnsafeRawPointer(link).advanced(by: dataOffset + Int(link.pointee.sdl_nlen))
            return (0..<6).map { index in
                let hex = String(bytes.load(fromByteOffset: index, as: UInt8.self), radix: 16)
                return hex.count == 1 ? "0" + hex : hex
            }.joined(separator: ":")
        }
    }
}
