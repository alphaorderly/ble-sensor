import CoreBluetooth
import Foundation
import Observation
import WidgetKit

enum BLEConnectionState: Equatable {
    case unknown
    case poweredOff
    case unauthorized
    case scanning
    case connecting(String)
    case connected(String)
    case disconnected

    var statusText: String {
        switch self {
        case .unknown: return "Bluetooth 초기화 중..."
        case .poweredOff: return "Bluetooth 꺼짐"
        case .unauthorized: return "Bluetooth 권한 필요"
        case .scanning: return "센서 검색 중..."
        case .connecting(let name): return "\(name) 연결 중..."
        case .connected(let name): return name
        case .disconnected: return "연결 끊김 · 재연결 대기"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
@Observable
final class BLESensorManager: NSObject {
    static let essServiceUUID = CBUUID(string: "181A")
    static let tempCharUUID = CBUUID(string: "2A6E")
    static let humCharUUID = CBUUID(string: "2A6F")
    static let co2CharUUID = CBUUID(string: "2B8C")

    private static let lastPeripheralKey = "EnvSensorWidget.lastPeripheralUUID"
    private static let maxHistoryCount = 45
    private static let minWidgetReloadInterval: TimeInterval = 15.0

    private(set) var connectionState: BLEConnectionState = .unknown
    private(set) var deviceName: String = "ESP32-ENV"
    private(set) var temperatureC: Double?
    private(set) var humidityPct: Double?
    private(set) var co2PPM: Int?
    private(set) var lastUpdated: Date?
    private(set) var co2History: [CO2Point] = []

    var airQuality: AirQualityLevel {
        AirQualityLevel.from(co2: co2PPM)
    }

    var menuBarTitle: String {
        guard let t = temperatureC, let c = co2PPM else {
            return connectionState.isConnected ? "측정 중" : "BLE"
        }
        return String(format: "%.1f° %dppm", t, c)
    }

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var reconnectTimer: Timer?

    private var lastWidgetReloadDate: Date = .distantPast
    private var lastReloadedCO2: Int?
    private var lastReloadedTemp: Double?

    override init() {
        super.init()
        let previous = SharedSnapshotStore.load()
        self.deviceName = previous.deviceName
        self.co2History = previous.co2History
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            updateStateFromCentral()
            return
        }
        cancelReconnectTimer()
        if let current = peripheral, current.state == .connected || current.state == .connecting {
            return
        }

        if let savedIDString = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
           let savedUUID = UUID(uuidString: savedIDString),
           let known = centralManager.retrievePeripherals(withIdentifiers: [savedUUID]).first
        {
            connect(to: known)
            centralManager.scanForPeripherals(
                withServices: [Self.essServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            return
        }

        connectionState = .scanning
        publishSnapshot(forceWidgetReload: true)
        centralManager.scanForPeripherals(
            withServices: [Self.essServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func reconnect() {
        cancelReconnectTimer()
        centralManager.stopScan()
        if let existing = peripheral {
            centralManager.cancelPeripheralConnection(existing)
            peripheral = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
        startScanning()
    }

    func forceRefreshWidget() {
        publishSnapshot(forceWidgetReload: true)
    }

    private func connect(to target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        let name = target.name ?? deviceName
        deviceName = name
        connectionState = .connecting(name)
        publishSnapshot(forceWidgetReload: false)
        centralManager.connect(target, options: nil)
    }

    private func scheduleReconnect(after seconds: TimeInterval = 3.0) {
        cancelReconnectTimer()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.startScanning()
            }
        }
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func updateStateFromCentral() {
        switch centralManager.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            connectionState = .poweredOff
            publishSnapshot(forceWidgetReload: true)
        case .unauthorized:
            connectionState = .unauthorized
            publishSnapshot(forceWidgetReload: true)
        default:
            connectionState = .unknown
        }
    }

    private func appendCO2History(_ ppm: Int) {
        co2History.append(CO2Point(timestamp: Date(), ppm: ppm))
        if co2History.count > Self.maxHistoryCount {
            co2History.removeFirst(co2History.count - Self.maxHistoryCount)
        }
    }

    private func publishSnapshot(forceWidgetReload: Bool) {
        let snap = SensorSnapshot(
            deviceName: deviceName,
            isConnected: connectionState.isConnected,
            statusText: connectionState.statusText,
            temperatureC: temperatureC,
            humidityPct: humidityPct,
            co2PPM: co2PPM,
            co2History: co2History,
            updatedAt: lastUpdated
        )
        SharedSnapshotStore.save(snap)

        let now = Date()
        let elapsed = now.timeIntervalSince(lastWidgetReloadDate)
        let co2Jump: Bool = {
            guard let curr = co2PPM, let prev = lastReloadedCO2 else { return co2PPM != nil }
            return abs(curr - prev) >= 25
        }()
        let tempJump: Bool = {
            guard let curr = temperatureC, let prev = lastReloadedTemp else { return temperatureC != nil }
            return abs(curr - prev) >= 0.3
        }()

        let shouldReload = forceWidgetReload
            || (lastReloadedCO2 == nil && co2PPM != nil && temperatureC != nil && humidityPct != nil)
            || elapsed >= Self.minWidgetReloadInterval
            || (elapsed >= 5.0 && (co2Jump || tempJump))

        if shouldReload {
            lastWidgetReloadDate = now
            lastReloadedCO2 = co2PPM
            lastReloadedTemp = temperatureC
            WidgetCenter.shared.reloadTimelines(ofKind: SensorWidgetIdentity.kind)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLESensorManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            updateStateFromCentral()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasESS = advertisedServices.contains { $0.uuidString.uppercased() == "181A" }
        nonisolated(unsafe) let discoveredPeripheral = peripheral
        nonisolated(unsafe) let manager = central

        MainActor.assumeIsolated {
            let matchesName = advName.hasPrefix("ESP32-ENV")
            guard matchesName || hasESS else { return }

            if !advName.isEmpty {
                deviceName = advName
            }
            manager.stopScan()
            connect(to: discoveredPeripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let manager = central
        nonisolated(unsafe) let connectedPeripheral = peripheral
        let connectedName = peripheral.name

        MainActor.assumeIsolated {
            manager.stopScan()
            cancelReconnectTimer()
            let name = connectedName ?? deviceName
            deviceName = name
            connectionState = .connected(name)
            UserDefaults.standard.set(connectedPeripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
            publishSnapshot(forceWidgetReload: true)
            connectedPeripheral.discoverServices([Self.essServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            connectionState = .disconnected
            publishSnapshot(forceWidgetReload: true)
            scheduleReconnect(after: 2.0)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let disconnectedID = peripheral.identifier
        MainActor.assumeIsolated {
            if self.peripheral?.identifier == disconnectedID {
                self.peripheral = nil
            }
            connectionState = .disconnected
            publishSnapshot(forceWidgetReload: true)
            scheduleReconnect(after: 2.0)
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLESensorManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        nonisolated(unsafe) let p = peripheral
        MainActor.assumeIsolated {
            guard let services = p.services else { return }
            for service in services where service.uuid == Self.essServiceUUID {
                p.discoverCharacteristics(
                    [Self.tempCharUUID, Self.humCharUUID, Self.co2CharUUID],
                    for: service
                )
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else { return }
        nonisolated(unsafe) let p = peripheral
        nonisolated(unsafe) let s = service
        MainActor.assumeIsolated {
            guard let chars = s.characteristics else { return }
            for char in chars {
                switch char.uuid {
                case Self.tempCharUUID, Self.humCharUUID, Self.co2CharUUID:
                    p.readValue(for: char)
                    p.setNotifyValue(true, for: char)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let uuidString = characteristic.uuid.uuidString.uppercased()
        MainActor.assumeIsolated {
            switch uuidString {
            case "2A6E" where data.count >= 2:
                let raw = Int16(bitPattern: UInt16(data[0]) | (UInt16(data[1]) << 8))
                temperatureC = Double(raw) / 100.0
                lastUpdated = Date()
                publishSnapshot(forceWidgetReload: false)
            case "2A6F" where data.count >= 2:
                let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
                humidityPct = Double(raw) / 100.0
                lastUpdated = Date()
                publishSnapshot(forceWidgetReload: false)
            case "2B8C" where data.count >= 2:
                let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
                let ppm = Int(raw)
                co2PPM = ppm
                lastUpdated = Date()
                if ppm > 0 {
                    appendCO2History(ppm)
                }
                publishSnapshot(forceWidgetReload: false)
            default:
                break
            }
        }
    }
}
