import SwiftUI

/// One time bucket the sidebar/detail pane can roll totals up over.
/// Mirrors the range picker in the design (今天/本周/本月/全部).
enum TimeRange: String, CaseIterable, Identifiable, Hashable {
    case today, week, month, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "全部"
        }
    }

    var dotColor: Color {
        switch self {
        case .today: return Theme.rangeToday
        case .week: return Theme.rangeWeek
        case .month: return Theme.rangeMonth
        case .all: return Theme.rangeAll
        }
    }
}

/// Which of the sidebar's 监控 entries the panes to its right are showing.
enum SidebarSection: String, CaseIterable, Identifiable {
    case apps, connections, domains, uploads

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apps: return "所有 App"
        case .connections: return "活跃连接"
        case .domains: return "域名总览"
        case .uploads: return "上传检查"
        }
    }

    var systemImage: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .connections: return "point.3.filled.connected.trianglepath.dotted"
        case .domains: return "globe"
        case .uploads: return "arrow.up.doc"
        }
    }
}

/// One app↔host pair — the unit 活跃连接 lists, flattening the per-app
/// domain breakdowns into a single machine-wide view.
struct ConnectionRow: Identifiable, Equatable {
    var id: String { appID + "|" + host }
    var appID: String
    var appName: String
    var badge: AppBadge
    var host: String
    var kind: String
    var rateDownKBps: Double
    var connectionCount: Int
}

/// One remote host with every app talking to it folded together, for 域名总览
/// — the same hosts as `DomainUsage`, but keyed by host instead of by app.
struct DomainRollup: Identifiable, Equatable {
    var id: String { host }
    var host: String
    var kind: String
    var rateDownKBps: Double
    var totalDownKB: Double
    var totalUpKB: Double
    var connectionCount: Int
    var appNames: [String]
}

/// The span 实时速率 ranks apps over. Ranking on a single second made the
/// list reshuffle constantly; even 实时 uses a 10-second average.
enum RateWindow: Int, CaseIterable, Identifiable {
    case live = 10
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var label: String {
        switch self {
        case .live: return "近 10 秒"
        case .oneMinute: return "近 1 分钟"
        case .fiveMinutes: return "近 5 分钟"
        case .fifteenMinutes: return "近 15 分钟"
        }
    }
}

/// App list sort mode (实时速率 / 累计流量).
enum SortMode {
    case rate, total

    var label: String {
        switch self {
        case .rate: return "实时速率"
        case .total: return "累计流量"
        }
    }
}

/// Health of the background monitors, surfaced in the UI instead of
/// silently showing all-zero data when `nettop`/`lsof` can't be read.
enum MonitoringStatus: Equatable {
    case starting
    case ok
    case degraded(String)
    case unavailable(String)
}

/// Icon for an app: its real icon when it has an installed bundle, else a
/// two-tone gradient square with initials (processes with no bundle have
/// no icon of their own).
struct AppBadge: Equatable {
    /// Bundle ID to look the real icon up by; nil for bare processes.
    var bundleID: String? = nil
    var initials: String
    var colorTop: Color
    var colorBottom: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [colorTop, colorBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// One remote host an app is talking to, aggregated from live connections.
struct DomainUsage: Identifiable, Equatable {
    var id: String { host }
    var host: String
    var kind: String
    var rateDownKBps: Double
    var totalDownKB: Double
    var totalUpKB: Double
    var connectionCount: Int
}

/// One row of the app list / detail pane — the real-data analogue of a
/// `DATA` entry in the original design's mock.
struct AppUsage: Identifiable, Equatable {
    let id: String
    var name: String
    var bundleID: String
    var badge: AppBadge
    var connectionCount: Int
    var statusLine: String
    var rateDownKBps: Double
    var rateUpKBps: Double
    var totalDownKB: [TimeRange: Double]
    var totalUpKB: [TimeRange: Double]
    /// Last 60 one-second samples, oldest first.
    var downHistory: [Double]
    var upHistory: [Double]
    var domains: [DomainUsage]
    var isPaused: Bool
    /// False for a row rebuilt from saved history for an app that hasn't
    /// run this launch — it has totals but no rates, hosts or pause control.
    var isLive: Bool = true
    /// A local proxy other apps connect through. What it moves is those
    /// apps' traffic a second time, so machine totals leave it out.
    var isProxy: Bool = false
    /// Average rates over the chosen `RateWindow`, and this app's share of
    /// every app's traffic in it (0...1); what 实时速率 ranks by.
    var windowDownKBps: Double = 0
    var windowUpKBps: Double = 0
    var windowShare: Double = 0

    var meta: String { isLive ? "\(statusLine) · \(connectionCount) 个连接" : statusLine }

    static func == (lhs: AppUsage, rhs: AppUsage) -> Bool {
        lhs.id == rhs.id
            && lhs.connectionCount == rhs.connectionCount
            && lhs.rateDownKBps == rhs.rateDownKBps
            && lhs.rateUpKBps == rhs.rateUpKBps
            && lhs.totalDownKB == rhs.totalDownKB
            && lhs.totalUpKB == rhs.totalUpKB
            && lhs.downHistory == rhs.downHistory
            && lhs.upHistory == rhs.upHistory
            && lhs.domains == rhs.domains
            && lhs.isPaused == rhs.isPaused
            && lhs.isLive == rhs.isLive
            && lhs.isProxy == rhs.isProxy
            && lhs.windowDownKBps == rhs.windowDownKBps
            && lhs.windowUpKBps == rhs.windowUpKBps
            && lhs.windowShare == rhs.windowShare
    }
}
