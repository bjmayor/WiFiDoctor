import Foundation

/// 读取网卡字节计数器，差分得到实际上下行速率（Mbps）。
///
/// 实现说明：用 `/usr/sbin/netstat -ib` 解析 Ibytes/Obytes 两列。
///
/// 之所以不直接解析 getifaddrs 的 ifa_data：
/// 那是内核私有 if_data 布局，字段偏移随架构/内核变化，
/// 实测会把 5GB 的计数读成 1.7e14 这种明显错误的值。
/// sysctl(NET_RT_IFLIST2) 虽是公开 API，但 Swift 的 if_data64 overlay
/// 不暴露 ifi_ibytes64，手工按偏移读同样不可靠（实测恒为 0）。
///
/// netstat -ib 是系统自带、跨版本稳定的文本接口，
/// 且与 ifconfig / nettop 同源，一行即可取到，可直接对照验证。
/// 上架 App Store 时若要去掉外部进程，可换成 Network.framework 实现，
/// 接口签名保持不变即可。
final class ThroughputCounter: @unchecked Sendable {
    private var lastSample: (date: Date, rx: UInt64, tx: UInt64)?

    /// 返回 (下行Mbps, 上行Mbps)。第一次调用只建立基线，返回 0。
    func sample(interface: String) async -> (down: Double, up: Double) {
        let now = Date()
        guard let (rx, tx) = byteCounts(for: interface) else { return (0, 0) }

        defer { lastSample = (now, rx, tx) }

        guard let last = lastSample else { return (0, 0) }
        let dt = now.timeIntervalSince(last.date)
        guard dt > 0.2 else { return (0, 0) }

        // 计数器回绕（切换网络 / 接口重置）时丢弃这次
        guard rx >= last.rx, tx >= last.tx else { return (0, 0) }

        let dRx = Double(rx - last.rx) * 8 / 1_000_000   // Mbit
        let dTx = Double(tx - last.tx) * 8 / 1_000_000
        return (dRx / dt, dTx / dt)
    }

    /// 从 netstat -ib 中取指定接口的 (Ibytes, Obytes)
    private func byteCounts(for name: String) -> (rx: UInt64, tx: UInt64)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-ibn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            guard cols.count >= 11, cols[0] == name else { continue }
            // Network 列为 "<Link#N>" 才是累计计数；IP 行的数字是重复展示，跳过
            guard cols[2].hasPrefix("<") else { continue }
            guard let rx = UInt64(cols[6]), let tx = UInt64(cols[9]) else { continue }
            return (rx, tx)
        }
        return nil
    }
}