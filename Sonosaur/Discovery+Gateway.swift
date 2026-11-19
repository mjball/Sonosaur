import Foundation

extension Discovery {

    static func gatewayMAC(in subnet: Subnet) -> String? {
        let routes = ipv4Routes()
        let defaultRoute = routes.first { route in
            route.isDefault && route.gatewayIP.map { subnet.contains($0) } == true
        }
        guard let gateway = defaultRoute?.gatewayIP else { return nil }
        return routes.first { $0.destinationIP == gateway && $0.gatewayMAC != nil }?.gatewayMAC
    }

    static func arpTableIPs() -> [UInt32] {
        ipv4Routes().filter { $0.gatewayMAC != nil }.map(\.destinationIP)
    }

    private struct Route {
        let isDefault: Bool
        let destinationIP: UInt32
        let gatewayIP: UInt32?
        let gatewayMAC: String?
    }

    private static func ipv4Routes() -> [Route] {
        routingTable().withUnsafeBytes { table in
            var routes: [Route] = []
            let headerSize = MemoryLayout<rt_msghdr>.size
            var offset = 0
            while offset + headerSize <= table.count {
                let header = table.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let messageLength = Int(header.rtm_msglen)
                guard messageLength >= headerSize, offset + messageLength <= table.count else { break }
                let message = UnsafeRawBufferPointer(rebasing: table[offset..<(offset + messageLength)])
                offset += messageLength

                let addresses = socketAddresses(in: message, present: header.rtm_addrs)
                guard let destination = addresses[RTAX_DST].flatMap(ipv4) else { continue }
                let gateway = addresses[RTAX_GATEWAY]
                routes.append(Route(
                    isDefault: destination == 0 && header.rtm_flags & RTF_GATEWAY != 0,
                    destinationIP: destination,
                    gatewayIP: gateway.flatMap(ipv4),
                    gatewayMAC: gateway.flatMap(macAddress)
                ))
            }
            return routes
        }
    }

    // The table can grow between sizing it and reading it, which fails with ENOMEM.
    private static func routingTable() -> [UInt8] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return [] }
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 {
                return Array(buffer.prefix(length))
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    private static func socketAddresses(
        in message: UnsafeRawBufferPointer,
        present: Int32
    ) -> [Int32: UnsafeRawBufferPointer] {
        var addresses: [Int32: UnsafeRawBufferPointer] = [:]
        var cursor = MemoryLayout<rt_msghdr>.size
        for index in 0..<RTAX_MAX where present & (1 << index) != 0 {
            guard cursor < message.count else { break }
            let length = Int(message[cursor])
            let end = min(cursor + length, message.count)
            addresses[index] = UnsafeRawBufferPointer(rebasing: message[cursor..<end])
            cursor += roundedUpToFourBytes(length)
        }
        return addresses
    }

    private static func roundedUpToFourBytes(_ length: Int) -> Int {
        length > 0 ? 1 + ((length - 1) | 3) : 4
    }

    private static func ipv4(_ address: UnsafeRawBufferPointer) -> UInt32? {
        let familyOffset = MemoryLayout<sockaddr_in>.offset(of: \.sin_family)!
        let addressOffset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!
        guard address.count >= addressOffset + 4,
              address[familyOffset] == AF_INET
        else { return nil }
        return UInt32(bigEndian: address.loadUnaligned(fromByteOffset: addressOffset, as: UInt32.self))
    }

    private static func macAddress(_ address: UnsafeRawBufferPointer) -> String? {
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
        guard address.count >= dataOffset,
              address[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_family)!] == AF_LINK,
              address[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen)!] == 6
        else { return nil }
        let start = dataOffset + Int(address[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!])
        guard address.count >= start + 6 else { return nil }
        return address[start..<(start + 6)].map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
