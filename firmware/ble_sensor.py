"""Minimal BLE Environmental Sensing GATT Server for MicroPython (NimBLE).

Exposes standard Bluetooth SIG services only:
  - Environmental Sensing Service (0x181A): Temperature, Humidity, CO2
  - Device Information Service (0x180A): Manufacturer, Model, Firmware
"""

import bluetooth
import struct
from micropython import const

_IRQ_CENTRAL_CONNECT = const(1)
_IRQ_CENTRAL_DISCONNECT = const(2)

_FLAG_READ = const(0x0002)
_FLAG_NOTIFY = const(0x0010)

# Advertising Data Types
_ADV_TYPE_FLAGS = const(0x01)
_ADV_TYPE_UUID16_COMPLETE = const(0x03)
_ADV_TYPE_NAME = const(0x09)
_ADV_TYPE_APPEARANCE = const(0x19)

# Bluetooth SIG Appearance: Generic Sensor (0x0540)
_APPEARANCE_GENERIC_SENSOR = const(0x0540)

# Standard Environmental Sensing Service (0x181A)
_ENV_SENSE_UUID = bluetooth.UUID(0x181A)
_TEMP_CHAR = (bluetooth.UUID(0x2A6E), _FLAG_READ | _FLAG_NOTIFY)  # sint16, 0.01 degC
_HUM_CHAR = (bluetooth.UUID(0x2A6F), _FLAG_READ | _FLAG_NOTIFY)   # uint16, 0.01 %RH
_CO2_CHAR = (bluetooth.UUID(0x2B8C), _FLAG_READ | _FLAG_NOTIFY)   # uint16, 1 ppm
_ENV_SENSE_SERVICE = (_ENV_SENSE_UUID, (_TEMP_CHAR, _HUM_CHAR, _CO2_CHAR))

# Standard Device Information Service (0x180A)
_DEV_INFO_UUID = bluetooth.UUID(0x180A)
_MANUFACTURER_CHAR = (bluetooth.UUID(0x2A29), _FLAG_READ)
_MODEL_CHAR = (bluetooth.UUID(0x2A24), _FLAG_READ)
_FW_REV_CHAR = (bluetooth.UUID(0x2A26), _FLAG_READ)
_DEV_INFO_SERVICE = (_DEV_INFO_UUID, (_MANUFACTURER_CHAR, _MODEL_CHAR, _FW_REV_CHAR))


def _adv_encode(name=None, services=None, appearance=0):
    payload = bytearray()

    def _append(adv_type, value):
        payload.extend(struct.pack("BB", len(value) + 1, adv_type))
        payload.extend(value)

    # General Discoverable + BR/EDR Not Supported
    _append(_ADV_TYPE_FLAGS, struct.pack("B", 0x06))

    if appearance:
        _append(_ADV_TYPE_APPEARANCE, struct.pack("<h", appearance))

    if services:
        for uuid in services:
            b = bytes(uuid)
            if len(b) == 2:
                _append(_ADV_TYPE_UUID16_COMPLETE, b)

    if name:
        _append(_ADV_TYPE_NAME, name.encode("utf-8"))

    if len(payload) > 31:
        raise ValueError("BLE advertising payload exceeds 31 bytes (%d)" % len(payload))
    return bytes(payload)


class BLEEnvServer:
    def __init__(
        self,
        name_prefix="ESP32-ENV",
        manufacturer="OpenSource",
        model="ESP32-ENV",
        firmware="1.0.0",
        adv_interval_us=250_000,
        max_connections=3,
    ):
        self._ble = bluetooth.BLE()
        self._ble.active(True)

        # Build device name from BLE MAC tail (fits 31-byte adv packet)
        _, mac = self._ble.config("mac")
        self.mac_str = ":".join("%02X" % b for b in mac)
        suffix = "%02X%02X" % (mac[-2], mac[-1])
        self.name = "%s-%s" % (name_prefix, suffix)

        self._ble.config(gap_name=self.name)

        self._adv_interval_us = adv_interval_us
        self._max_connections = max_connections
        self._connections = set()
        self._need_advertise = False

        self._ble.irq(self._irq)

        services = self._ble.gatts_register_services(
            (_ENV_SENSE_SERVICE, _DEV_INFO_SERVICE)
        )
        (
            (self._h_temp, self._h_hum, self._h_co2),
            (self._h_mfg, self._h_model, self._h_fw),
        ) = services

        self._ble.gatts_set_buffer(self._h_mfg, 32, False)
        self._ble.gatts_set_buffer(self._h_model, 32, False)
        self._ble.gatts_set_buffer(self._h_fw, 16, False)

        self._ble.gatts_write(self._h_mfg, manufacturer.encode("utf-8"))
        self._ble.gatts_write(self._h_model, model.encode("utf-8"))
        self._ble.gatts_write(self._h_fw, firmware.encode("utf-8"))

        self._ble.gatts_write(self._h_temp, struct.pack("<h", 0))
        self._ble.gatts_write(self._h_hum, struct.pack("<H", 0))
        self._ble.gatts_write(self._h_co2, struct.pack("<H", 0))

        self._adv_data = _adv_encode(
            name=self.name,
            services=(_ENV_SENSE_UUID,),
            appearance=_APPEARANCE_GENERIC_SENSOR,
        )
        self._advertise()

    def _irq(self, event, data):
        if event == _IRQ_CENTRAL_CONNECT:
            conn_handle, _, _ = data
            self._connections.add(conn_handle)
            if len(self._connections) < self._max_connections:
                self._need_advertise = True
        elif event == _IRQ_CENTRAL_DISCONNECT:
            conn_handle, _, _ = data
            self._connections.discard(conn_handle)
            self._need_advertise = True

    def _advertise(self):
        self._need_advertise = False
        try:
            self._ble.gap_advertise(
                self._adv_interval_us,
                adv_data=self._adv_data,
                connectable=True,
            )
        except OSError:
            pass

    def maintain(self):
        """Restart advertising when needed (safe to call from main loop)."""
        if self._need_advertise:
            self._advertise()

    @property
    def is_connected(self):
        return len(self._connections) > 0

    @property
    def connection_count(self):
        return len(self._connections)

    def update_readings(self, temp_c=None, humidity=None, co2_ppm=None, notify=True):
        """Update GATT characteristic values and notify connected clients."""
        temp_packed = None
        hum_packed = None
        co2_packed = None

        if temp_c is not None:
            t_val = max(-32768, min(32767, int(round(temp_c * 100.0))))
            temp_packed = struct.pack("<h", t_val)
            self._ble.gatts_write(self._h_temp, temp_packed)

        if humidity is not None:
            h_val = max(0, min(10000, int(round(humidity * 100.0))))
            hum_packed = struct.pack("<H", h_val)
            self._ble.gatts_write(self._h_hum, hum_packed)

        if co2_ppm is not None:
            c_val = max(0, min(65535, int(co2_ppm)))
            co2_packed = struct.pack("<H", c_val)
            self._ble.gatts_write(self._h_co2, co2_packed)

        if notify and self._connections:
            for ch in list(self._connections):
                for handle, packed in (
                    (self._h_temp, temp_packed),
                    (self._h_hum, hum_packed),
                    (self._h_co2, co2_packed),
                ):
                    if packed is not None:
                        try:
                            self._ble.gatts_notify(ch, handle, packed)
                        except OSError:
                            pass
