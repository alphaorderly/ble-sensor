"""Minimal Cubic CM1106 / CM1107 UART NDIR CO2 sensor driver for MicroPython."""

import time
from micropython import const

_HEAD_TX = const(0x11)
_HEAD_RX = const(0x16)
_CMD_MEASURE = const(0x01)


def _checksum(frame_without_cs):
    return (256 - (sum(frame_without_cs) & 0xFF)) & 0xFF


def _build_frame(cmd, payload=b""):
    body = bytes([_HEAD_TX, 1 + len(payload), cmd]) + payload
    return body + bytes([_checksum(body)])


class CM1106Error(OSError):
    """Raised when CM1106/CM1107 UART communication or checksum fails."""


class CM1106:
    def __init__(self, uart):
        self._uart = uart
        self._cmd_measure = _build_frame(_CMD_MEASURE)  # b"\x11\x01\x01\xed"

    def _drain_rx(self):
        while self._uart.any():
            self._uart.read()

    def _transact(self, tx_frame, expected_cmd, timeout_ms=800):
        self._drain_rx()
        self._uart.write(tx_frame)

        buf = bytearray()
        deadline = time.ticks_add(time.ticks_ms(), timeout_ms)
        expected_total = None

        while time.ticks_diff(deadline, time.ticks_ms()) > 0:
            if self._uart.any():
                chunk = self._uart.read()
                if chunk:
                    buf.extend(chunk)
                    while len(buf) > 0 and buf[0] != _HEAD_RX:
                        del buf[0]
                    if expected_total is None and len(buf) >= 2:
                        expected_total = buf[1] + 3
                    if expected_total is not None and len(buf) >= expected_total:
                        frame = bytes(buf[:expected_total])
                        if (sum(frame) & 0xFF) != 0:
                            raise CM1106Error("CM1106 checksum mismatch")
                        if frame[2] != expected_cmd:
                            raise CM1106Error("CM1106 unexpected cmd 0x%02x" % frame[2])
                        return frame
            time.sleep_ms(10)

        raise CM1106Error("CM1106 timeout (received %d bytes)" % len(buf))

    def read_co2(self, timeout_ms=800):
        """Trigger measurement and return CO2 concentration in ppm (int)."""
        frame = self._transact(self._cmd_measure, _CMD_MEASURE, timeout_ms=timeout_ms)
        if len(frame) < 8:
            raise CM1106Error("CM1106 short response (%d bytes)" % len(frame))
        return (frame[3] << 8) | frame[4]
