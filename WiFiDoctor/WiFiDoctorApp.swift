import SwiftUI
import AppKit

@main
struct WiFiDoctorApp: App {
    @State private var monitor: NetworkMonitor

    init() {
        let m = NetworkMonitor()
        m.start()
        _monitor = State(initialValue: m)
    }

    var body: some Scene {
        // 菜单栏图标 → 点击弹出浮层面板（menuBarExtraStyle(.window) 才会浮在最上层）
        MenuBarExtra {
            MonitorPanel(monitor: monitor)
        } label: {
            MenuBarLabel(
                quality: monitor.currentQuality,
                loss: monitor.samples.last?.netLoss ?? 0,
                rtt: monitor.samples.last?.netRTT ?? 0
            )
        }
        .menuBarExtraStyle(.window)

        // 独立窗口：面板里的「打开独立窗口」用它。
        // LSUIElement=true 时窗口不会自动置前，需要显式激活 App。
        Window("网络体检", id: "main") {
            MonitorPanel(monitor: monitor)
        }
        .defaultSize(width: 420, height: 400)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开独立窗口") {
                    NSApp.sendAction(Selector(("newDocument:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("立即重连 Wi-Fi") {
                    Task { await monitor.requestRecoveryNow() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button(monitor.isRunning ? "暂停监测" : "开始监测") {
                    monitor.isRunning ? monitor.stop() : monitor.start()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("退出 WiFiDoctor") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Link("项目主页", destination: URL(string: "https://github.com/bjmayor/WiFiDoctor")!)
            }
        }
    }
}