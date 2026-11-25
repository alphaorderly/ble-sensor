# ESP32 BLE Environmental Sensor (`ESP32-ENV`)

ESP32(MicroPython)에서 온습도 센서(**Sensirion SHT3x**)와 CO₂ 센서(**Cubic CM1106 / CM1107**) 측정값을 표준 **BLE Environmental Sensing Service (`0x181A`)**로 송출하고, 웹 브라우저·Python CLI·macOS 위젯으로 실시간 조회하는 최소 구성 프로젝트입니다.

- **라이브 웹 뷰어 (GitHub Pages):** https://alphaorderly.github.io/ble-sensor/  
  *(Web Bluetooth 지원 브라우저 — 데스크탑/Android Chrome·Edge에서 별도 설치 없이 바로 연결 가능)*

---

## 1. 하드웨어 핀 설정 (`firmware/config.py`)

보드 배선에 맞게 [`firmware/config.py`](firmware/config.py) 상단의 GPIO 상수만 수정하면 됩니다.

| 장치 | 인터페이스 | 기본 설정 (`config.py`) |
|---|---|---|
| **SHT3x (온습도)** | I2C (`I2C_BUS_ID = 0`) | `PIN_I2C_SDA = 21`, `PIN_I2C_SCL = 22`, `100 kHz`, `0x44` |
| **CM1106 / CM1107 (CO₂)** | UART (`CO2_UART_ID = 1`) | `PIN_CO2_TX = 4`, `PIN_CO2_RX = 5`, `9600 bps 8N1` |
| **상태 LED (선택)** | GPIO 출력 | `PIN_STATUS_LED = 23` (`None` 설정 시 비활성화) |

---

## 2. BLE GATT 프로파일 (Bluetooth SIG 표준)

- **광고 이름:** `ESP32-ENV-XXXX` (`ESP32-ENV-` + BLE MAC 하위 4자리)
- **측정 주기:** 2초 (`SAMPLE_INTERVAL_MS = 2000`)

### Environmental Sensing Service (`0x181A`)
| 특성 (Characteristic) | UUID | 속성 | 데이터 포맷 (Little-Endian) |
|---|---|---|---|
| Temperature | `0x2A6E` | Read, Notify | `sint16`, 단위 `0.01 °C` |
| Humidity | `0x2A6F` | Read, Notify | `uint16`, 단위 `0.01 %` |
| CO₂ Concentration | `0x2B8C` | Read, Notify | `uint16`, 단위 `1 ppm` |

### Device Information Service (`0x180A`)
- Manufacturer Name (`0x2A29`), Model Number (`0x2A24`), Firmware Revision (`0x2A26`)

---

## 3. 사용 방법

### 웹 브라우저 (GitHub Pages)
1. Chrome 또는 Edge에서 https://alphaorderly.github.io/ble-sensor/ 접속
2. **센서 연결** 버튼 클릭 → `ESP32-ENV-XXXX` 선택
3. 실시간 CO₂, 온도, 습도 및 최근 추이 그래프 확인

### Python CLI (macOS / Windows / Linux)
```bash
pip install bleak
python3 client/ble_monitor.py
```

### macOS 메뉴바 & 바탕화면 위젯 앱 (macOS 14+)
```bash
./macos_app/build_and_install.sh
```
`/Applications/EnvSensorWidget.app` 실행 후 바탕화면 우클릭 → **위젯 편집...** → **`ESP32 환경 센서`** 위젯을 추가합니다.

### ESP32 MicroPython 펌웨어 업로드
```bash
pip install mpremote
mpremote connect <SERIAL_PORT> sleep 2 cp \
  firmware/config.py firmware/sht3x.py firmware/cm1106.py \
  firmware/ble_sensor.py firmware/main.py : + reset
```

---

## 프로젝트 구조

```text
ble-sensor/
├── firmware/
│   ├── config.py        # GPIO 핀맵, BLE 설정, 측정 주기
│   ├── sht3x.py         # Sensirion SHT3x I2C 드라이버
│   ├── cm1106.py        # Cubic CM1106/CM1107 UART CO2 드라이버
│   ├── ble_sensor.py    # NimBLE GATT 서버 (ESS 0x181A + DIS 0x180A)
│   └── main.py          # 주기적 측정 및 BLE Notify 루프
├── web/
│   ├── index.html       # GitHub Pages용 Web Bluetooth 실시간 뷰어
│   ├── style.css
│   └── app.js
├── client/
│   └── ble_monitor.py   # Python(bleak) 실시간 터미널 모니터
├── macos_app/           # macOS 메뉴바 BLE 호스트 + WidgetKit 위젯
└── .github/workflows/
    └── deploy-pages.yml # GitHub Pages 자동 배포 워크플로
```
