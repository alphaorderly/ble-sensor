import Foundation

enum SensorWidgetIdentity {
    static let kind = "EnvSensorDesktopWidget"
    static let supportFolderName = "EnvSensorWidget"
    static let snapshotFileName = "snapshot.json"
}

enum AirQualityLevel: String, Codable, Sendable, Equatable {
    case good
    case moderate
    case ventilateSoon
    case poor
    case unknown

    var label: String {
        switch self {
        case .good: return "쾌적"
        case .moderate: return "보통"
        case .ventilateSoon: return "환기 권장"
        case .poor: return "환기 필요"
        case .unknown: return "측정 대기"
        }
    }

    static func from(co2: Int?) -> AirQualityLevel {
        guard let co2 else { return .unknown }
        switch co2 {
        case ..<800: return .good
        case 800..<1200: return .moderate
        case 1200..<2000: return .ventilateSoon
        default: return .poor
        }
    }
}

struct CO2Point: Codable, Sendable, Equatable, Identifiable {
    let timestamp: Date
    let ppm: Int

    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}

struct SensorSnapshot: Codable, Sendable, Equatable {
    var deviceName: String
    var isConnected: Bool
    var statusText: String
    var temperatureC: Double?
    var humidityPct: Double?
    var co2PPM: Int?
    var co2History: [CO2Point]
    var updatedAt: Date?

    var airQuality: AirQualityLevel {
        AirQualityLevel.from(co2: co2PPM)
    }

    static let empty = SensorSnapshot(
        deviceName: "ESP32-ENV",
        isConnected: false,
        statusText: "메뉴바 앱 실행 대기",
        temperatureC: nil,
        humidityPct: nil,
        co2PPM: nil,
        co2History: [],
        updatedAt: nil
    )

    static let preview = SensorSnapshot(
        deviceName: "ESP32-ENV-0000",
        isConnected: true,
        statusText: "ESP32-ENV-0000",
        temperatureC: 24.6,
        humidityPct: 43.2,
        co2PPM: 740,
        co2History: [
            CO2Point(timestamp: Date().addingTimeInterval(-600), ppm: 920),
            CO2Point(timestamp: Date().addingTimeInterval(-480), ppm: 880),
            CO2Point(timestamp: Date().addingTimeInterval(-360), ppm: 830),
            CO2Point(timestamp: Date().addingTimeInterval(-240), ppm: 790),
            CO2Point(timestamp: Date().addingTimeInterval(-120), ppm: 760),
            CO2Point(timestamp: Date(), ppm: 740),
        ],
        updatedAt: Date()
    )
}

enum SharedSnapshotStore {
    /// Resolve the real user home directory even when running inside a macOS App Sandbox.
    private static func realUserHomeURL() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var homeSupportFileURL: URL {
        realUserHomeURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(SensorWidgetIdentity.supportFolderName, isDirectory: true)
            .appendingPathComponent(SensorWidgetIdentity.snapshotFileName)
    }

    static func save(_ snapshot: SensorSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        writeAtomic(data, to: homeSupportFileURL)
    }

    static func load() -> SensorSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: homeSupportFileURL),
           let snap = try? decoder.decode(SensorSnapshot.self, from: data)
        {
            return snap
        }
        return .empty
    }

    private static func writeAtomic(_ data: Data, to fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
