import SwiftUI
import Charts

// MARK: - 菜单栏图标

struct MenuBarLabel: View {
    let quality: Quality
    let loss: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            if loss > 0 {
                Text("\(Int(loss))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
        }
    }

    private var symbol: String {
        switch quality {
        case .good: "wifi"
        case .fair: "wifi.exclamationmark"
        case .poor: "wifi.slash"
        case .down: "wifi.slash"
        }
    }

    private var color: Color {
        switch quality {
        case .good: .green
        case .fair: .orange
        case .poor, .down: .red
        }
    }
}

// MARK: - 悬浮面板

struct MonitorPanel: View {
    @Bindable var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statsRow
            chart
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var latest: Sample? { monitor.samples.last }

    private var header: some View {
        HStack {
            Label("网络体检", systemImage: "stethoscope")
                .font(.headline)
            Spacer()
            Picker("", selection: .constant(monitor.isRunning)) {
                Text("运行中").tag(true)
                Text("已暂停").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .onChange(of: monitor.isRunning) { _, running in
                running ? monitor.start() : monitor.stop()
            }
        }
    }

    private var statsRow: some View {
        let st = monitor.recentStats
        return HStack(spacing: 0) {
            stat("丢包", String(format: "%.0f%%", st.avgLoss),
                 st.avgLoss >= 40 ? .red : (st.avgLoss >= 20 ? .orange : .green))
            stat("延迟", String(format: "%.0fms", st.avgRTT), .primary)
            stat("信号", latest?.rssi.map { "\($0)dBm" } ?? "—",
                 (latest?.rssi ?? -100) <= -75 ? .orange : .primary)
            stat("速率", latest?.txRateMbps.map { "\($0)M" } ?? "—", .primary)
        }
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var chart: some View {
        Chart(monitor.samples.suffix(180)) { s in
            LineMark(
                x: .value("时间", s.timestamp),
                y: .value("丢包", s.netLoss)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(.orange)

            if let gw = s.gatewayLoss {
                LineMark(
                    x: .value("时间", s.timestamp),
                    y: .value("网关丢包", gw)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue.opacity(0.7))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100])
        }
        .chartXAxis(.hidden)
        .frame(height: 120)
    }

    private var footer: some View {
        HStack {
            if let r = latest {
                Text("\(r.interfaceName) · \(r.channel ?? "—") · \(r.isWiFi ? "Wi-Fi" : "其他链路")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("立即重连") {
                Task { await monitor.requestRecoveryNow() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}