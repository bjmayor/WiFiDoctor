import Foundation
import CoreWLAN

/// 用 CoreWLAN 读取 Wi-Fi 链路信息（快）。
///
/// macOS 14+ 读取 RSSI 需要定位权限，缺失时字段返回 nil 而不是失败——
/// 这样即使上架后没拿到权限，App 也只是少显示几个数字，不会崩。
struct CoreWLANLinkInfoProvider: LinkInfoProviding {
    private let interfaceName: String

    init(interfaceName: String = "en0") {
        self.interfaceName = interfaceName
    }

    func currentLink() async -> LinkInfo? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var result: LinkInfo?
                let ifaces = CWWiFiClient.shared().interfaceNames() ?? []
                if let name = ifaces.first(where: { $0 == self.interfaceName }) {
                    let iface = CWWiFiClient.shared().interface(withName: name)
                    let rssiValue = iface?.rssiValue()
                    let noiseValue = iface?.noiseMeasurement()
                    let txRate = iface?.transmitRate()
                    let channel = iface?.wlanChannel()?.channelNumber
                    let isUp = iface?.powerOn() ?? false

                    result = LinkInfo(
                        rssi: rssiValue,
                        noise: noiseValue,
                        channel: channel.map { "ch\($0)" },
                        txRateMbps: txRate.flatMap { $0 > 0 ? Int($0) : nil },
                        interfaceName: name,
                        isUp: isUp
                    )
                }
                continuation.resume(returning: result)
            }
        }
    }
}