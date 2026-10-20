import Foundation

/// 一次网络采样。字段与命令行版 watcher 保持一致，便于对照排查。
struct Sample: Identifiable, Sendable {
    let id: UUID = UUID()
    let timestamp: Date

    /// 主链路接口，例如 en0（Wi-Fi）、en8（iPhone 热点）
    var interfaceName: String
    /// 链路是否 UP
    var isUp: Bool
    /// 当前是否走 Wi-Fi
    var isWiFi: Bool

    /// 信号强度（dBm）。非 Wi-Fi 或无权限时为 nil。
    var rssi: Int?
    var noise: Int?
    var channel: String?
    var txRateMbps: Int?
    /// 实际下行/上行速率（Mbps，来自网卡字节计数差分）
    var downMbps: Double = 0
    var upMbps: Double = 0

    /// 到默认网关的丢包率(%) / 延迟(ms)
    var gatewayLoss: Double?
    var gatewayRTT: Double?
    /// 到 1.1.1.1 的丢包率(%) / 延迟(ms)
    var netLoss: Double
    var netRTT: Double

    init(timestamp: Date = Date(),
         interfaceName: String,
         isUp: Bool,
         isWiFi: Bool,
         rssi: Int? = nil,
         noise: Int? = nil,
         channel: String? = nil,
         txRateMbps: Int? = nil,
         downMbps: Double = 0,
         upMbps: Double = 0,
         gatewayLoss: Double? = nil,
         gatewayRTT: Double? = nil,
         netLoss: Double = 0,
         netRTT: Double = 0) {
        self.timestamp = timestamp
        self.interfaceName = interfaceName
        self.isUp = isUp
        self.isWiFi = isWiFi
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.txRateMbps = txRateMbps
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.gatewayLoss = gatewayLoss
        self.gatewayRTT = gatewayRTT
        self.netLoss = netLoss
        self.netRTT = netRTT
    }
}

/// 链路质量档位，用于着色和文案。
enum Quality: String, Sendable {
    case good, fair, poor, down

    init(loss: Double, rtt: Double) {
        if loss >= 50 { self = .poor }
        else if loss >= 20 { self = .fair }
        else if rtt >= 250 { self = .fair }
        else { self = .good }
    }

    var label: String {
        switch self {
        case .good: "良好"
        case .fair: "一般"
        case .poor: "很差"
        case .down: "断开"
        }
    }
}

/// 一段时间窗口的统计，用于趋势展示。
struct Stats: Sendable {
    var samples: Int = 0
    var avgLoss: Double = 0
    var maxLoss: Double = 0
    var avgRTT: Double = 0
    var minRSSI: Int?
    var badRatio: Double = 0        // 丢包 ≥25% 的采样占比

    static func from(_ items: [Sample]) -> Stats {
        guard !items.isEmpty else { return Stats() }
        let losses = items.map(\.netLoss)
        let rtts = items.map(\.netRTT)
        let rssis = items.compactMap(\.rssi)
        return Stats(
            samples: items.count,
            avgLoss: losses.reduce(0, +) / Double(items.count),
            maxLoss: losses.max() ?? 0,
            avgRTT: rtts.reduce(0, +) / Double(items.count),
            minRSSI: rssis.min(),
            badRatio: Double(losses.filter { $0 >= 25 }.count) / Double(items.count)
        )
    }
}