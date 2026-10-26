import Foundation

/// 恢复动作的抽象层。
///
/// 这是为上架准备的关键 seam：
///  - 自用版：`DirectCommandRecovery` 直接调 networksetup（需要非沙箱）
///  - 上架版：`LaunchAgentRecovery` 让现有的 wifi-guard.sh 去处理，或 `HelperRecovery` 走 SMJobBless
///
/// 上架时只需替换实现，UI 与调度逻辑一行不用改。
protocol NetworkRecovery: Sendable {
    /// 当前环境是否允许执行恢复动作
    var isAvailable: Bool { get }
    /// 人类可读的能力说明，用于在设置里提示
    var capabilityDescription: String { get }
    func restore(reason: String) async
}

/// 自用版：直接调 networksetup。
struct DirectCommandRecovery: NetworkRecovery {
    var isAvailable: Bool { true }
    var capabilityDescription: String { "直接调用 networksetup 重启 Wi-Fi" }

    func restore(reason: String) async {
        // 安全护栏：只有当默认路由确实在 en0 上时才动手。
        // 否则会有把用户从手机热点踢回 Wi-Fi 的风险（曾发生过）。
        guard await Self.primaryInterface() == "en0" else { return }

        // 再确认 Wi-Fi 电源是开着的；关着就不要"顺手打开"
        let power = await ProcessRunner.run("/usr/sbin/networksetup",
                                            ["-getairportpower", "en0"], timeout: 5)
        guard power.out.contains("On") else { return }

        _ = await ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", "en0", "off"], timeout: 10)
        try? await Task.sleep(for: .seconds(3))
        _ = await ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", "en0", "on"], timeout: 10)
        try? await Task.sleep(for: .seconds(10))
    }

    /// 当前默认路由所在接口（en0 = Wi-Fi，en8 = iPhone 热点 等）
    private static func primaryInterface() async -> String {
        let r = await ProcessRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 5)
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces) == "interface" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}

/// 上架版：把恢复交给已经装好的 LaunchAgent（wifi-guard.sh）。
/// App 本身不执行任何特权命令，因此完全符合沙箱要求。
struct LaunchAgentRecovery: NetworkRecovery {
    var isAvailable: Bool { true }
    var capabilityDescription: String { "交给 wifi-guard 后台服务处理" }

    func restore(reason: String) async {
        // 通知 guard 立刻做一次检查：写一个触发文件即可，避免 App 直接改网络。
        let flag = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wifiguard-force")
        try? Data().write(to: flag)
        try? await Task.sleep(for: .seconds(1))
        try? FileManager.default.removeItem(at: flag)
    }
}