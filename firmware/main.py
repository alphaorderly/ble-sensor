"""Minimal ESP32 MicroPython BLE environmental sensor (SHT3x + CM1106).

Reads temperature, humidity, and CO2 periodically and publishes them over
standard BLE Environmental Sensing Service (0x181A).
"""

import gc
import time
from machine import I2C, Pin, UART

import config
from ble_sensor import BLEEnvServer
from cm1106 import CM1106
from sht3x import SHT3x


class EnvSensorApp:
    def __init__(self):
        self.led = (
            Pin(config.PIN_STATUS_LED, Pin.OUT, value=0)
            if config.PIN_STATUS_LED is not None
            else None
        )

        self.i2c = I2C(
            config.I2C_BUS_ID,
            sda=Pin(config.PIN_I2C_SDA),
            scl=Pin(config.PIN_I2C_SCL),
            freq=config.I2C_FREQ_HZ,
        )
        self.sht = SHT3x(self.i2c, addr=config.SHT3X_I2C_ADDR)

        self.uart = UART(
            config.CO2_UART_ID,
            baudrate=config.CO2_BAUDRATE,
            bits=8,
            parity=None,
            stop=1,
            tx=Pin(config.PIN_CO2_TX),
            rx=Pin(config.PIN_CO2_RX),
        )
        self.co2 = CM1106(self.uart)

        self.sample_interval_ms = config.SAMPLE_INTERVAL_MS
        self.seq = 0

        self.ble = BLEEnvServer(
            name_prefix=config.DEVICE_NAME_PREFIX,
            manufacturer=config.MANUFACTURER_NAME,
            model=config.MODEL_NUMBER,
            firmware=config.FIRMWARE_VERSION,
            adv_interval_us=config.ADV_INTERVAL_US,
            max_connections=config.MAX_CONNECTIONS,
        )

    def _init_sensors(self):
        i2c_devices = [hex(a) for a in self.i2c.scan()]
        print("[INIT] I2C devices:", i2c_devices)
        if self.sht.is_present():
            try:
                self.sht.soft_reset()
                status = self.sht.read_status()
                print(
                    "[INIT] SHT3x OK at 0x%02X (status=0x%04X)"
                    % (config.SHT3X_I2C_ADDR, status)
                )
            except Exception as e:
                print("[INIT] SHT3x warning:", e)
        else:
            print("[WARN] SHT3x not found at 0x%02X" % config.SHT3X_I2C_ADDR)

    def sample_and_publish(self):
        temp_c = None
        humidity = None
        co2_ppm = None

        try:
            raw_t, raw_h = self.sht.read()
            temp_c = round(raw_t, 2)
            humidity = round(min(100.0, max(0.0, raw_h)), 2)
        except Exception as e:
            print("[ERR] SHT3x read failed:", e)

        try:
            co2_ppm = self.co2.read_co2(timeout_ms=800)
        except Exception as e:
            print("[ERR] CM1106 read failed:", e)

        self.seq += 1
        self.ble.update_readings(
            temp_c=temp_c,
            humidity=humidity,
            co2_ppm=co2_ppm,
            notify=True,
        )

        print(
            "[DATA] #%d temp=%sC hum=%s%% co2=%sppm ble_conns=%d"
            % (
                self.seq,
                "%.2f" % temp_c if temp_c is not None else "ERR",
                "%.2f" % humidity if humidity is not None else "ERR",
                str(co2_ppm) if co2_ppm is not None else "ERR",
                self.ble.connection_count,
            )
        )

    def _update_led(self, now, last_blink, led_state):
        if self.led is None:
            return last_blink, led_state

        if self.ble.is_connected:
            if led_state != 1:
                led_state = 1
                self.led.value(1)
        elif time.ticks_diff(now, last_blink) >= 500:
            last_blink = now
            led_state ^= 1
            self.led.value(led_state)
        return last_blink, led_state

    def run(self):
        print("========================================")
        print("ESP32 MicroPython BLE Environmental Sensor")
        print("BLE Name :", self.ble.name)
        print("Services : ESS (0x181A), DIS (0x180A)")
        print("========================================")
        self._init_sensors()

        last_sample = time.ticks_add(time.ticks_ms(), -self.sample_interval_ms)
        last_blink = time.ticks_ms()
        led_state = 0

        while True:
            now = time.ticks_ms()
            self.ble.maintain()

            if time.ticks_diff(now, last_sample) >= self.sample_interval_ms:
                last_sample = now
                self.sample_and_publish()
                if self.seq % 15 == 0:
                    gc.collect()

            last_blink, led_state = self._update_led(now, last_blink, led_state)
            time.sleep_ms(50)


def main():
    app = EnvSensorApp()
    app.run()


if __name__ == "__main__":
    main()
