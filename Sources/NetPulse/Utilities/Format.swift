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
        // Under 1 KB/s but not idle: "0 KB/s" beside a 6% share read as a bug.
        if kbps < 1 { return kbps > 0.05 ? "<1 KB/s" : "0 KB/s" }
        return String(format: "%.1f KB/s", kbps)
    }

    static func size(_ kb: Double) -> String {
        if kb >= 1_048_576 { return String(format: "%.2f GB", kb / 1_048_576) }
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        // A few hundred bytes rounded to "0 KB" read as no traffic at all.
        if kb > 0 && kb < 0.5 { return "<1 KB" }
        return "\(Int(kb.rounded())) KB"
    }

    /// A byte count: exact under 1 KB, where a request's size matters.
    static func bytes(_ count: Int) -> String {
        count < 1024 ? "\(count) B" : size(Double(count) / 1024)
    }
}
