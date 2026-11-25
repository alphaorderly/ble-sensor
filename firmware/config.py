"""Hardware pinout and BLE configuration for ESP32 MicroPython environmental sensor.

Adjust the GPIO pin numbers below to match your ESP32 board wiring.
"""

# ---------------------------------------------------------------------------
# Device Identity (BLE Advertising & Device Information Service 0x180A)
# ---------------------------------------------------------------------------
DEVICE_NAME_PREFIX = "ESP32-ENV"
MANUFACTURER_NAME = "OpenSource"
MODEL_NUMBER = "ESP32-ENV"
FIRMWARE_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Hardware Pinout (Edit these GPIO numbers for your wiring)
# ---------------------------------------------------------------------------
# I2C — Sensirion SHT3x (Temperature & Humidity)
I2C_BUS_ID = 0
PIN_I2C_SDA = 21
PIN_I2C_SCL = 22
I2C_FREQ_HZ = 100_000
SHT3X_I2C_ADDR = 0x44

# UART — Cubic CM1106 / CM1107 (NDIR CO2)
CO2_UART_ID = 1
PIN_CO2_TX = 4
PIN_CO2_RX = 5
CO2_BAUDRATE = 9600

# Status LED (Active High: 1=ON, 0=OFF; set to None to disable)
PIN_STATUS_LED = 23

# ---------------------------------------------------------------------------
# Sampling & BLE Parameters
# ---------------------------------------------------------------------------
SAMPLE_INTERVAL_MS = 2000
ADV_INTERVAL_US = 250_000
MAX_CONNECTIONS = 3
