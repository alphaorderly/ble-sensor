#!/usr/bin/env python3
"""Minimal cross-platform BLE monitor for the ESP32 Environmental Sensor.

Usage:
    pip install bleak
    python3 client/ble_monitor.py
"""

import argparse
import asyncio
import struct
import sys
from datetime import datetime

from bleak import BleakClient, BleakScanner

ESS_SERVICE_UUID = "0000181a-0000-1000-8000-00805f9b34fb"
TEMP_CHAR_UUID = "00002a6e-0000-1000-8000-00805f9b34fb"
HUM_CHAR_UUID = "00002a6f-0000-1000-8000-00805f9b34fb"
CO2_CHAR_UUID = "00002b8c-0000-1000-8000-00805f9b34fb"


def decode_temp(data: bytes) -> float:
    return struct.unpack("<h", data[:2])[0] / 100.0


def decode_hum(data: bytes) -> float:
    return struct.unpack("<H", data[:2])[0] / 100.0


def decode_co2(data: bytes) -> int:
    return struct.unpack("<H", data[:2])[0]


async def find_device(name_prefix: str, timeout: float):
    print(f"Scanning for BLE sensor ({name_prefix}*) for up to {timeout:.0f}s...")
    return await BleakScanner.find_device_by_filter(
        lambda d, adv: (d.name or "").startswith(name_prefix)
        or ESS_SERVICE_UUID in (adv.service_uuids or []),
        timeout=timeout,
    )


async def run(args):
    device = await find_device(args.prefix, args.scan_timeout)
    if device is None:
        print("No matching ESP32 BLE environmental sensor found.", file=sys.stderr)
        return 1

    print(f"Found: {device.name} ({device.address})")
    latest = {"temp": None, "hum": None, "co2": None}

    def on_temp(_, data: bytearray):
        latest["temp"] = decode_temp(bytes(data))

    def on_hum(_, data: bytearray):
        latest["hum"] = decode_hum(bytes(data))

    def on_co2(_, data: bytearray):
        latest["co2"] = decode_co2(bytes(data))
        ts = datetime.now().strftime("%H:%M:%S")
        t_str = f"{latest['temp']:.2f} °C" if latest["temp"] is not None else "--"
        h_str = f"{latest['hum']:.2f} %" if latest["hum"] is not None else "--"
        print(f"[{ts}] Temp: {t_str} | Humidity: {h_str} | CO2: {latest['co2']} ppm")

    async with BleakClient(device) as client:
        t0 = decode_temp(await client.read_gatt_char(TEMP_CHAR_UUID))
        h0 = decode_hum(await client.read_gatt_char(HUM_CHAR_UUID))
        c0 = decode_co2(await client.read_gatt_char(CO2_CHAR_UUID))
        print(f"Initial Read | Temp: {t0:.2f} °C | Humidity: {h0:.2f} % | CO2: {c0} ppm")

        await client.start_notify(TEMP_CHAR_UUID, on_temp)
        await client.start_notify(HUM_CHAR_UUID, on_hum)
        await client.start_notify(CO2_CHAR_UUID, on_co2)

        if args.duration > 0:
            await asyncio.sleep(args.duration)
        else:
            print("Listening for live BLE notifications (Ctrl+C to exit)...")
            while client.is_connected:
                await asyncio.sleep(1.0)

    return 0


def main():
    parser = argparse.ArgumentParser(description="ESP32 BLE Environmental Sensor Monitor")
    parser.add_argument("--prefix", default="ESP32-ENV", help="BLE device name prefix")
    parser.add_argument("--scan-timeout", type=float, default=10.0, help="BLE scan timeout (s)")
    parser.add_argument("--duration", type=float, default=0.0, help="Listen duration in seconds (0 = infinite)")
    args = parser.parse_args()
    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("\nDisconnected.")


if __name__ == "__main__":
    main()
