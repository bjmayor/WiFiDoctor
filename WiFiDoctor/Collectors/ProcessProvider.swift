import Foundation

/// 采集一次网络状态。
///
/// 拆成两个 provider 是为了上架做准备：
///  - `LinkInfoProviding`：RSSI / 信道 / 协商速率。上架版本走 CoreWLAN（快，需要定位权限）
///  - `ProcessProviding`：ping / 默认路由。这部分上架后要换成 Network.framework 或继续用 BSD socket
protocol LinkInfoProviding: Sendable {
    func currentLink() async -> LinkInfo?
}

struct LinkInfo: Sendable {
    var rssi: Int?
    var noise: Int?
    var channel: String?
    var txRateMbps: Int?
    var interfaceName: String
    var isUp: Bool
}

protocol ProcessProviding: Sendable {
    func ping(host: String, count: Int) async -> PingResult
    func defaultRoute() async -> (interface: String, gateway: String)?
}

struct PingResult: Sendable {
    var lossPercent: Double
    var averageRTT: Double?
    var received: Int
    var sent: Int
}

/// 极简线程安全标记，用于 Process 超时保护。
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

enum ProcessRunner {
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 10) async -> (code: Int32, out: String, err: String) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            // 防止 timeout 秒内没退出导致挂死。用一个线程安全的 flag。
            let finished = ManagedAtomicFlag()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !finished.get() { task.terminate() }
            }

            task.terminationHandler = { proc in
                finished.set()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (proc.terminationStatus,
                                                   String(decoding: outData, as: UTF8.self),
                                                   String(decoding: errData, as: UTF8.self)))
            }
            do {
                try task.run()
            } catch {
                continuation.resume(returning: (-1, "", "\(error)"))
            }
        }
    }
}

struct DefaultProcessProvider: ProcessProviding {
    let pingPath = "/sbin/ping"
    let routePath = "/sbin/route"

    func ping(host: String, count: Int) async -> PingResult {
        // -i 0.4 + -t 3：单次最长 3 秒，避免网络极差时采样被拖成几十秒
        let (code, out, _) = await ProcessRunner.run(pingPath, ["-c", "\(count)", "-i", "0.4", "-W", "900", "-t", "3", host])
        guard code == 0 else {
            return PingResult(lossPercent: 100, averageRTT: nil, received: 0, sent: count)
        }
        let received = Self.intValue(of: "packets received", in: out)
        let sent = Self.intValue(of: "packets transmitted", in: out) ?? count
        var rtt: Double?
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("round-trip") || l.hasPrefix("rtt") {
                // round-trip min/avg/max/stddev = 3.1/45.2/60.0/8.7 ms
                let parts = l.split(separator: "=")
                if parts.count == 2 {
                    let nums = parts[1].split(separator: "/")
                    if nums.count >= 2 {
                        rtt = Double(nums[1].trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        let loss = sent > 0 ? Double(sent - (received ?? 0)) / Double(sent) * 100 : 100
        return PingResult(lossPercent: loss, averageRTT: rtt, received: received ?? 0, sent: sent)
    }

    func defaultRoute() async -> (interface: String, gateway: String)? {
        let (code, out, _) = await ProcessRunner.run(routePath, ["-n", "get", "default"])
        guard code == 0 else { return nil }
        var iface: String?
        var gw: String?
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "interface" { iface = parts[1] }
            if parts[0] == "gateway" { gw = parts[1] }
        }
        guard let iface else { return nil }
        return (iface, gw ?? "")
    }

    /// 从 "4 packets transmitted, 4 packets received, 0.0% packet loss" 中取数字
    private static func intValue(of label: String, in text: String) -> Int? {
        // label 形如 "packets received"
        guard let re = try? NSRegularExpression(pattern: "(\\d+)\\s+\\Q\(label)\\E") else { return nil }
        for line in text.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let m = re.firstMatch(in: s, range: range),
                  let r = Range(m.range(at: 1), in: s) else { continue }
            return Int(s[r])
        }
        return nil
    }
}