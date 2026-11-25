"""Sensirion SHT3x (SHT30 / SHT31 / SHT35) I2C driver for MicroPython."""

import time
from micropython import const

_CMD_MEASURE_HIGH_NO_CS = b"\x24\x00"
_CMD_SOFT_RESET = b"\x30\xA2"
_CMD_READ_STATUS = b"\xF3\x2D"
_CMD_CLEAR_STATUS = b"\x30\x41"

_CRC8_POLY = const(0x31)
_CRC8_INIT = const(0xFF)


def _crc8(data):
    crc = _CRC8_INIT
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ _CRC8_POLY) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


class SHT3xError(OSError):
    """Raised when SHT3x communication or CRC check fails."""


class SHT3x:
    def __init__(self, i2c, addr=0x44):
        self._i2c = i2c
        self._addr = addr
        self._buf = bytearray(6)

    def is_present(self):
        return self._addr in self._i2c.scan()

    def soft_reset(self):
        self._i2c.writeto(self._addr, _CMD_SOFT_RESET)
        time.sleep_ms(20)

    def read_status(self):
        self._i2c.writeto(self._addr, _CMD_READ_STATUS)
        raw = self._i2c.readfrom(self._addr, 3)
        if _crc8(raw[0:2]) != raw[2]:
            raise SHT3xError("SHT3x status CRC mismatch")
        return (raw[0] << 8) | raw[1]

    def read(self):
        """Return (temperature_c, relative_humidity_pct) with CRC-8 verification."""
        self._i2c.writeto(self._addr, _CMD_MEASURE_HIGH_NO_CS)
        time.sleep_ms(20)
        self._i2c.readfrom_into(self._addr, self._buf)

        if _crc8(self._buf[0:2]) != self._buf[2]:
            raise SHT3xError("SHT3x temperature CRC mismatch")
        if _crc8(self._buf[3:5]) != self._buf[5]:
            raise SHT3xError("SHT3x humidity CRC mismatch")

        raw_t = (self._buf[0] << 8) | self._buf[1]
        raw_h = (self._buf[3] << 8) | self._buf[4]

        temp_c = -45.0 + (175.0 * raw_t / 65535.0)
        humidity = 100.0 * raw_h / 65535.0
        if humidity < 0.0:
            humidity = 0.0
        elif humidity > 100.0:
            humidity = 100.0
        return temp_c, humidity
