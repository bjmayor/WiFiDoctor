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
        _ = await ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", "en0", "off"], timeout: 10)
        try? await Task.sleep(for: .seconds(3))
        _ = await ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", "en0", "on"], timeout: 10)
        try? await Task.sleep(for: .seconds(10))
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