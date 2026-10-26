import Foundation
import SwiftUI
import UserNotifications
import Observation

/// 全局状态机：采样 → 判定 → 通知/恢复。
@MainActor
@Observable
final class NetworkMonitor {
    // MARK: - 可调参数
    var sampleInterval: TimeInterval = 5
    var badThresholdLoss: Double = 40          // 丢包 ≥40% 记为“差”
    var badDurationToWarn: TimeInterval = 300  // 持续 5 分钟才通知
    var consecutiveBadToRecover = 3           // 连续 N 次采样差则尝试恢复
    var autoRecoveryEnabled = true             // 用户总开关：关掉后只监测不干预
    var recoveryCooldown: TimeInterval = 900   // 两次恢复之间的冷却（秒）
    var maxRecoveriesPerHour = 5               // 一小时内最多恢复几次

    // MARK: - 状态
    private(set) var samples: [Sample] = []
    private(set) var currentQuality: Quality = .good
    private(set) var isRunning = false
    private(set) var lastRecoveryAt: Date?

    private let throughput = ThroughputCounter()
    private var task: Task<Void, Never>?
    private var consecutiveBad = 0
    private var badSince: Date?
    private var warnedForCurrentEpisode = false
    private var recoveryTimestamps: [Date] = []
    private var lastRecoveryAtTime: Date?

    // MARK: - 依赖（默认自用版；上架时替换）
    private let proc: ProcessProviding = DefaultProcessProvider()
    private let link: LinkInfoProviding = CoreWLANLinkInfoProvider()
    private let recovery: NetworkRecovery = DirectCommandRecovery()

    private let maxSamples = 720   // 约 1 小时 @5s

    var recentStats: Stats {
        Stats.from(samples.suffix(60))
    }

    var hourStats: Stats {
        let cutoff = Date().addingTimeInterval(-3600)
        return Stats.from(samples.filter { $0.timestamp >= cutoff })
    }

    private static func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }
    private func fmtDouble(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let boot = ProcessInfo.processInfo.environment["WIFIDOCTOR_OUT"] ?? "/tmp/wifidoctor-samples.log"
        if let h = FileHandle(forWritingAtPath: boot) { try? h.close() } else {
            try? Data().write(to: URL(fileURLWithPath: boot))
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.sampleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    func requestRecoveryNow() async {
        await recovery.restore(reason: "用户手动触发")
        lastRecoveryAt = Date()
    }

    // MARK: - 核心采样

    private func tick() async {
        let route = await proc.defaultRoute()
        let iface = route?.interface ?? "?"
        let gateway = route?.gateway ?? ""

        let info = await link.currentLink()
        let onWiFi = info?.interfaceName == iface

        // 网关：只有走 Wi-Fi 且拿到网关才测，否则无意义
        var gwLoss: Double?
        var gwRTT: Double?
        if onWiFi, !gateway.isEmpty {
            let r = await proc.ping(host: gateway, count: 4)
            gwLoss = r.lossPercent
            gwRTT = r.averageRTT
        }

        let tp = await throughput.sample(interface: iface)

        let net = await proc.ping(host: "1.1.1.1", count: 4)

        let sample = Sample(
            timestamp: Date(),
            interfaceName: iface,
            isUp: info?.isUp ?? false,
            isWiFi: onWiFi,
            rssi: onWiFi ? info?.rssi : nil,
            noise: onWiFi ? info?.noise : nil,
            channel: onWiFi ? info?.channel : nil,
            txRateMbps: onWiFi ? info?.txRateMbps : nil,
            downMbps: tp.down,
            upMbps: tp.up,
            gatewayLoss: gwLoss,
            gatewayRTT: gwRTT,
            netLoss: net.lossPercent,
            netRTT: net.averageRTT ?? 0
        )

        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        evaluate(sample)

        #if DEBUG
        if ProcessInfo.processInfo.environment["WIFIDOCTOR_LOG"] == "1" {
            let path = ProcessInfo.processInfo.environment["WIFIDOCTOR_OUT"] ?? "/tmp/wifidoctor-samples.log"
            if let h = FileHandle(forWritingAtPath: path) {
                defer { try? h.close() }
                let gw = fmtDouble(sample.gatewayLoss), gr = fmtDouble(sample.gatewayRTT)
                let line = String(format: "[%@] if=%@ link=%@ rssi=%@ ch=%@ rate=%@ down=%.1fM up=%.1fM gw=%@%%/%@ms net=%.0f%%/%.0fms\n",
                             Self.fmt(sample.timestamp), sample.interfaceName, sample.isUp ? "UP" : "DOWN",
                             sample.rssi.map(String.init) ?? "-", sample.channel ?? "-",
                             sample.txRateMbps.map(String.init) ?? "-", sample.downMbps, sample.upMbps,
                             gw, gr, sample.netLoss, sample.netRTT)
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!)
            }
            let gw = fmtDouble(sample.gatewayLoss), gr = fmtDouble(sample.gatewayRTT)
            print(String(format: "[%@] if=%@ link=%@ rssi=%@ ch=%@ rate=%@ gw=%@%%/%@ms net=%.0f%%/%.0fms",
                         Self.fmt(sample.timestamp), sample.interfaceName, sample.isUp ? "UP" : "DOWN",
                         sample.rssi.map(String.init) ?? "-", sample.channel ?? "-",
                         sample.txRateMbps.map(String.init) ?? "-", gw, gr, sample.netLoss, sample.netRTT))
        }
        #endif
    }

    // MARK: - 判定与动作

    private func evaluate(_ s: Sample) {
        // 判定用“本地跳优先”：网关丢包高说明 AP 有问题；否则看公网
        let localLoss = s.gatewayLoss ?? s.netLoss
        currentQuality = Quality(loss: localLoss, rtt: s.netRTT)

        let isBad = !s.isUp || localLoss >= badThresholdLoss

        // 关键护栏：不在 Wi-Fi 上（例如在用手机热点）时，绝不累计恢复计数，
        // 否则蜂窝一卡就会去动 Wi-Fi，把用户从热点踢回 Wi-Fi。
        if !s.isWiFi {
            consecutiveBad = 0
        }

        if isBad {
            if s.isWiFi { consecutiveBad += 1 }
            badSince = badSince ?? s.timestamp

            // 持续够久 → 通知一次（每轮只提醒一次，别打扰）
            if !warnedForCurrentEpisode,
               let since = badSince,
               s.timestamp.timeIntervalSince(since) >= badDurationToWarn {
                warnedForCurrentEpisode = true
                Task { await notifyBad(avgLoss: localLoss) }
            }

            // 连续差 → 尝试恢复（带冷却与次数上限，避免疯狂重启 Wi-Fi）
            if consecutiveBad >= consecutiveBadToRecover,
               s.isWiFi,
               autoRecoveryEnabled,
               recovery.isAvailable {
                consecutiveBad = 0
                let now = Date()

                // 清理一小时前的记录
                recoveryTimestamps.removeAll { now.timeIntervalSince($0) > 3600 }

                let cooledDown = lastRecoveryAtTime.map { now.timeIntervalSince($0) >= recoveryCooldown } ?? true
                let underLimit = recoveryTimestamps.count < maxRecoveriesPerHour

                if cooledDown && underLimit {
                    recoveryTimestamps.append(now)
                    lastRecoveryAtTime = now
                    lastRecoveryAt = now
                    let reason = "连续采样丢包 \(Int(localLoss))%"
                    Task {
                        await recovery.restore(reason: reason)
                        await notifyRecovered()
                    }
                } else if !underLimit {
                    // 已达上限：停止折腾 Wi-Fi，改为提醒用户
                    if !warnedForCurrentEpisode {
                        warnedForCurrentEpisode = true
                        Task { await notifyGiveUp() }
                    }
                }
            }
        } else {
            if warnedForCurrentEpisode {
                warnedForCurrentEpisode = false
                Task { await notifyRecovered() }
            }
            consecutiveBad = 0
            badSince = nil
        }
    }

    // MARK: - 通知

    private func requestAuth() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func notifyBad(avgLoss: Double) async {
        guard await requestAuth() else { return }
        let content = UNMutableNotificationContent()
        content.title = "网络很差，先去做别的"
        content.body = String(format: "已持续 %.0f 分钟，丢包约 %d%%。建议把大任务留到网络空档。", badDurationToWarn / 60, Int(avgLoss))
        content.sound = .default
        let req = UNNotificationRequest(identifier: "bad-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    private func notifyGiveUp() async {
        guard await requestAuth() else { return }
        let content = UNMutableNotificationContent()
        content.title = "自动修复已暂停"
        content.body = "1 小时内已尝试修复 \(maxRecoveriesPerHour) 次仍未成功。可能是酒店整体故障，建议改用手机热点或换个位置。"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "giveup-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    private func notifyRecovered() async {
        guard await requestAuth() else { return }
        let st = hourStats
        let content = UNMutableNotificationContent()
        content.title = "网络已恢复"
        content.body = String(format: "近一小时平均丢包 %.1f%%，延迟 %.0f ms。", st.avgLoss, st.avgRTT)
        content.sound = .default
        let req = UNNotificationRequest(identifier: "ok-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}