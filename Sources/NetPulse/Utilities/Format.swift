import Foundation

/// Byte-rate / byte-size formatting, ported 1:1 from `fmtRate`/`fmtSize` in
/// the original NetPulse.dc.html mock so displayed numbers read identically.
enum Format {
    static func rate(_ kbps: Double) -> String {
        if kbps >= 1024 {
            let decimals = kbps >= 10240 ? 1 : 2
            return String(format: "%.\(decimals)f MB/s", kbps / 1024)
        }
        if kbps >= 100 { return "\(Int(kbps.rounded())) KB/s" }
        if kbps < 1 { return "0 KB/s" }
        return String(format: "%.1f KB/s", kbps)
    }

    static func size(_ kb: Double) -> String {
        if kb >= 1_048_576 { return String(format: "%.2f GB", kb / 1_048_576) }
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        return "\(Int(kb.rounded())) KB"
    }
}
