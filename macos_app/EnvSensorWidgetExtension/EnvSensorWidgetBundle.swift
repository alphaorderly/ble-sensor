import AppIntents
import SwiftUI
import WidgetKit

struct RefreshSensorWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "센서 데이터 새로고침"
    static let description = IntentDescription("ESP32 BLE 센서의 최신 측정값으로 위젯을 갱신합니다.")

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: SensorWidgetIdentity.kind)
        return .result()
    }
}

struct EnvSensorEntry: TimelineEntry {
    let date: Date
    let snapshot: SensorSnapshot
}

struct EnvSensorTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> EnvSensorEntry {
        EnvSensorEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (EnvSensorEntry) -> Void) {
        if context.isPreview {
            let live = SharedSnapshotStore.load()
            let snap = (live.co2PPM != nil || live.temperatureC != nil) ? live : .preview
            completion(EnvSensorEntry(date: .now, snapshot: snap))
            return
        }
        completion(EnvSensorEntry(date: .now, snapshot: SharedSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EnvSensorEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedSnapshotStore.load()
        let entry = EnvSensorEntry(date: now, snapshot: snapshot)
        let nextRefresh = Calendar.current.date(byAdding: .second, value: 60, to: now) ?? now.addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct WidgetSparklineView: View {
    let points: [CO2Point]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if points.count >= 2 {
                let values = points.map { Double($0.ppm) }
                let rawMin = values.min() ?? 400
                let rawMax = values.max() ?? 1000
                let mid = (rawMin + rawMax) / 2.0
                let span = max(rawMax - rawMin, 80.0)
                let minVal = mid - span / 2.0
                let maxVal = mid + span / 2.0
                let w = geo.size.width
                let h = geo.size.height

                let coords: [CGPoint] = values.enumerated().map { idx, val in
                    let x = w * CGFloat(idx) / CGFloat(values.count - 1)
                    let norm = (val - minVal) / (maxVal - minVal)
                    let y = h - CGFloat(norm) * (h - 4) - 2
                    return CGPoint(x: x, y: y)
                }

                ZStack {
                    Path { path in
                        guard let first = coords.first, let last = coords.last else { return }
                        path.move(to: CGPoint(x: first.x, y: h))
                        path.addLine(to: first)
                        for pt in coords.dropFirst() {
                            path.addLine(to: pt)
                        }
                        path.addLine(to: CGPoint(x: last.x, y: h))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.24), tint.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        guard let first = coords.first else { return }
                        path.move(to: first)
                        for pt in coords.dropFirst() {
                            path.addLine(to: pt)
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .widgetAccentable()

                    if let last = coords.last {
                        Circle()
                            .fill(tint)
                            .frame(width: 4.5, height: 4.5)
                            .position(last)
                            .widgetAccentable()
                    }
                }
            } else {
                Path { path in
                    let y = geo.size.height * 0.65
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}

struct EnvSensorWidgetEntryView: View {
    let entry: EnvSensorEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var snap: SensorSnapshot { entry.snapshot }

    private var airColor: Color {
        switch snap.airQuality {
        case .good: return .green
        case .moderate: return .yellow
        case .ventilateSoon: return .orange
        case .poor: return .red
        case .unknown: return .secondary
        }
    }

    private var isStale: Bool {
        guard let updated = snap.updatedAt else { return true }
        return Date().timeIntervalSince(updated) > 180
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallLayout
            default:
                mediumLayout
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color.clear
                if renderingMode == .fullColor {
                    LinearGradient(
                        colors: [
                            airColor.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                }
            }
        }
    }

    // MARK: - Small Desktop Widget
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(snap.isConnected && !isStale ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                    .widgetAccentable()

                Text("환경 센서")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Button(intent: RefreshSensorWidgetIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(snap.co2PPM.map { "\($0)" } ?? "---")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    Text("ppm")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(snap.airQuality.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(airColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(airColor.opacity(0.16), in: Capsule())
                    .widgetAccentable()
            }

            Spacer(minLength: 2)

            Divider()
                .overlay(Color.primary.opacity(0.08))

            HStack(spacing: 0) {
                HStack(spacing: 3) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(snap.temperatureC.map { String(format: "%.1f°", $0) } ?? "--°")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: "humidity.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.cyan)
                    Text(snap.humidityPct.map { String(format: "%.0f%%", $0) } ?? "--%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Medium Desktop Widget
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(snap.isConnected && !isStale ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .widgetAccentable()

                Text(snap.isConnected ? snap.deviceName : snap.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if let updated = snap.updatedAt {
                    Text(updated, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                Button(intent: RefreshSensorWidgetIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(snap.co2PPM.map { "\($0)" } ?? "---")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text("ppm")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("CO₂ 농도")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(snap.airQuality.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(airColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(airColor.opacity(0.16), in: Capsule())
                        .widgetAccentable()

                    WidgetSparklineView(points: snap.co2History, tint: airColor)
                        .frame(width: 112, height: 30)
                }
            }

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.primary.opacity(0.08))

            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("온도")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(snap.temperatureC.map { String(format: "%.1f°C", $0) } ?? "--.-°C")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 24)
                    .overlay(Color.primary.opacity(0.08))
                    .padding(.horizontal, 10)

                HStack(spacing: 7) {
                    Image(systemName: "humidity.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("습도")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(snap.humidityPct.map { String(format: "%.1f%%", $0) } ?? "--.-%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct EnvSensorDesktopWidget: Widget {
    let kind: String = SensorWidgetIdentity.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EnvSensorTimelineProvider()) { entry in
            EnvSensorWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("ESP32 환경 센서")
        .description("ESP32 BLE 센서의 CO₂, 온도, 습도를 바탕화면 위젯으로 표시합니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct EnvSensorWidgetBundle: WidgetBundle {
    var body: some Widget {
        EnvSensorDesktopWidget()
    }
}
