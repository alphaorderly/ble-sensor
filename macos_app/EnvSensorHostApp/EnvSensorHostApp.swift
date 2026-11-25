import AppKit
import SwiftUI

@main
struct EnvSensorHostApp: App {
    @State private var ble = BLESensorManager()
    @AppStorage("EnvSensorWidget.showMenuBarValues") private var showMenuBarValues = true

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "aqi.medium")
                if showMenuBarValues {
                    Text(ble.menuBarTitle)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Text(ble.connectionState.statusText)

        if let t = ble.temperatureC, let h = ble.humidityPct, let c = ble.co2PPM {
            Text(String(format: "CO₂ %d ppm (%@) · %.1f°C · %.1f%%", c, ble.airQuality.label, t, h))
        }

        if ble.connectionState == .unauthorized {
            Button("Bluetooth 권한 설정 열기...") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Divider()

        Button("바탕화면 위젯 지금 새로고침") {
            ble.forceRefreshWidget()
        }

        Button(showMenuBarValues ? "✓ 메뉴바에 실시간 수치 표시" : "메뉴바에 실시간 수치 표시") {
            showMenuBarValues.toggle()
        }

        Button("BLE 다시 연결") {
            ble.reconnect()
        }

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
