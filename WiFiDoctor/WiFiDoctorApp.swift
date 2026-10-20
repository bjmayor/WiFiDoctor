import SwiftUI

@main
struct WiFiDoctorApp: App {
    @State private var monitor: NetworkMonitor

    init() {
        let m = NetworkMonitor()
        m.start()
        _monitor = State(initialValue: m)
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor)
        } label: {
            MenuBarLabel(
                quality: monitor.currentQuality,
                loss: monitor.samples.last?.netLoss ?? 0
            )
        }
        .menuBarExtraStyle(.window)

        Window("网络体检", id: "main") {
            MonitorPanel(monitor: monitor)
        }
        .defaultSize(width: 400, height: 380)
    }
}