import SwiftUI
import Charts

// MARK: - 菜单栏图标

struct MenuBarLabel: View {
    let quality: Quality
    let loss: Double
    let rtt: Double

    var body: some View {
        HStack(spacing: 3) {
            // 用趋势图图标，避免和系统 Wi-Fi 图标撞脸
            Image(systemName: symbol)
            // 丢包率常显，网络正常时显示 0
            Text("\(Int(loss.rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .help(tooltip)
    }

    private var symbol: String {
        switch quality {
        case .good: "chart.line.uptrend.xyaxis"
        case .fair: "chart.line.uptrend.xyaxis"
        case .poor: "exclamationmark.triangle.fill"
        case .down: "wifi.slash"
        }
    }

    private var tooltip: String {
        switch quality {
        case .good: "网络正常 · 延迟 \(Int(rtt))ms"
        case .fair: "网络一般 · 丢包 \(Int(loss))% · 延迟 \(Int(rtt))ms"
        case .poor, .down: "网络很差 · 丢包 \(Int(loss))% · 延迟 \(Int(rtt))ms"
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
            stat("下载", latest.map { String(format: "%.1fM", $0.downMbps) } ?? "—", .primary)
            stat("上传", latest.map { String(format: "%.1fM", $0.upMbps) } ?? "—", .primary)
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
                Text("\(r.interfaceName) · \(r.channel ?? "—") · 协商 \(r.txRateMbps.map { "\($0)M" } ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await monitor.requestRecoveryNow() }
            } label: {
                Label("立即重连", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}