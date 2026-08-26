import Foundation
import Darwin

/// Caches reverse-DNS lookups for remote IPs so the domain table can show
/// hostnames (e.g. "googlevideo.com") instead of raw addresses. Best-effort:
/// many CDN/cloud IPs have no PTR record, in which case the IP is shown as-is.
actor ReverseDNSResolver {
    private var cache: [String: (host: String, expires: Date)] = [:]
    private let ttl: TimeInterval = 600

    func resolve(_ ip: String) async -> String {
        let now = Date()
        if let hit = cache[ip], hit.expires > now { return hit.host }
        let resolved = await Task.detached(priority: .utility) { Self.reverseLookup(ip) ?? ip }.value
        cache[ip] = (resolved, now.addingTimeInterval(ttl))
        return resolved
    }

    private static func reverseLookup(_ ip: String) -> String? {
        lookupIPv4(ip) ?? lookupIPv6(ip)
    }

    private static func lookupIPv4(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        return String(cString: hostBuf)
    }

    private static func lookupIPv6(_ ip: String) -> String? {
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else { return nil }
        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        return String(cString: hostBuf)
    }
}
