(() => {
  const ESS_SERVICE = "0000181a-0000-1000-8000-00805f9b34fb";
  const TEMP_CHAR = "00002a6e-0000-1000-8000-00805f9b34fb";
  const HUM_CHAR = "00002a6f-0000-1000-8000-00805f9b34fb";
  const CO2_CHAR = "00002b8c-0000-1000-8000-00805f9b34fb";
  const MAX_HISTORY = 60;

  const connectBtn = document.getElementById("connect-btn");
  const statusBadge = document.getElementById("status-badge");
  const compatWarning = document.getElementById("compat-warning");
  const errorBanner = document.getElementById("error-banner");

  const co2Val = document.getElementById("co2-val");
  const tempVal = document.getElementById("temp-val");
  const humVal = document.getElementById("hum-val");
  const aqBadge = document.getElementById("aq-badge");
  const updatedAt = document.getElementById("updated-at");
  const deviceInfo = document.getElementById("device-info");

  const chartLine = document.getElementById("chart-line");
  const chartArea = document.getElementById("chart-area");
  const chartMin = document.getElementById("chart-min");
  const chartMax = document.getElementById("chart-max");

  let device = null;
  let co2History = [];
  let boundChars = [];
  let lastNotifyAt = 0;
  let pollTimer = null;
  let isPolling = false;

  const isIOSLike =
    /iPad|iPhone|iPod/i.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function hasWebBluetooth() {
    return typeof navigator !== "undefined" && !!navigator.bluetooth;
  }

  function refreshCompatNotice() {
    compatWarning.hidden = hasWebBluetooth();
  }

  window.addEventListener("load", refreshCompatNotice);
  refreshCompatNotice();

  function showError(msg) {
    if (!msg) {
      errorBanner.hidden = true;
      errorBanner.textContent = "";
      return;
    }
    errorBanner.textContent = msg;
    errorBanner.hidden = false;
  }

  function setStatus(connected, text) {
    statusBadge.textContent = text;
    statusBadge.className = connected ? "badge badge-connected" : "badge badge-idle";
    connectBtn.textContent = connected ? "연결 해제" : "센서 연결";
  }

  function toDataView(raw) {
    if (!raw) return null;
    if (raw instanceof DataView) return raw;
    if (ArrayBuffer.isView(raw)) {
      return new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    }
    if (raw instanceof ArrayBuffer) {
      return new DataView(raw);
    }
    if (raw.buffer instanceof ArrayBuffer) {
      return new DataView(raw.buffer, raw.byteOffset || 0, raw.byteLength || raw.buffer.byteLength);
    }
    return null;
  }

  function updateAirQuality(ppm) {
    if (ppm == null || Number.isNaN(ppm)) {
      aqBadge.textContent = "--";
      aqBadge.className = "aq-pill aq-unknown";
      return;
    }
    if (ppm < 800) {
      aqBadge.textContent = "쾌적";
      aqBadge.className = "aq-pill aq-good";
    } else if (ppm < 1200) {
      aqBadge.textContent = "보통";
      aqBadge.className = "aq-pill aq-moderate";
    } else if (ppm < 2000) {
      aqBadge.textContent = "환기 권장";
      aqBadge.className = "aq-pill aq-warn";
    } else {
      aqBadge.textContent = "환기 필요";
      aqBadge.className = "aq-pill aq-poor";
    }
  }

  function touchTimestamp() {
    const now = new Date();
    updatedAt.textContent = now.toLocaleTimeString("ko-KR", { hour12: false });
  }

  function renderChart() {
    if (co2History.length < 2) {
      chartLine.setAttribute("d", "");
      chartArea.setAttribute("d", "");
      chartMin.textContent = co2History.length === 1 ? `${co2History[0]} ppm` : "--";
      chartMax.textContent = "--";
      return;
    }

    const w = 600;
    const h = 140;
    const padY = 12;

    const rawMin = Math.min(...co2History);
    const rawMax = Math.max(...co2History);
    const span = Math.max(rawMax - rawMin, 100);
    const mid = (rawMin + rawMax) / 2;
    const minV = mid - span / 2;
    const maxV = mid + span / 2;

    const pts = co2History.map((v, i) => {
      const x = (w * i) / (co2History.length - 1);
      const norm = (v - minV) / (maxV - minV);
      const y = h - padY - norm * (h - padY * 2);
      return [x, y];
    });

    const lineD = pts
      .map(([x, y], i) => `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`)
      .join(" ");
    const areaD = `${lineD} L${w},${h} L0,${h} Z`;

    chartLine.setAttribute("d", lineD);
    chartArea.setAttribute("d", areaD);
    chartMin.textContent = `최저 ${rawMin} ppm`;
    chartMax.textContent = `최고 ${rawMax} ppm`;
  }

  function handleTemp(raw) {
    const view = toDataView(raw);
    if (!view || view.byteLength < 2) return;
    const tempC = view.getInt16(0, true) / 100;
    tempVal.textContent = tempC.toFixed(1);
    touchTimestamp();
  }

  function handleHum(raw) {
    const view = toDataView(raw);
    if (!view || view.byteLength < 2) return;
    const humPct = view.getUint16(0, true) / 100;
    humVal.textContent = humPct.toFixed(1);
    touchTimestamp();
  }

  function handleCO2(raw) {
    const view = toDataView(raw);
    if (!view || view.byteLength < 2) return;
    const ppm = view.getUint16(0, true);
    co2Val.textContent = String(ppm);
    updateAirQuality(ppm);
    if (ppm > 0) {
      co2History.push(ppm);
      if (co2History.length > MAX_HISTORY) {
        co2History.shift();
      }
      renderChart();
    }
    touchTimestamp();
  }

  function matchesShortUuid(uuid, shortHex) {
    const norm = String(uuid || "").toLowerCase();
    return norm === shortHex || norm === `0000${shortHex}-0000-1000-8000-00805f9b34fb`;
  }

  async function findCharacteristic(service, fullUuid, shortHex, cachedList) {
    if (cachedList) {
      const hit = cachedList.find((c) => matchesShortUuid(c.uuid, shortHex));
      if (hit) return hit;
    }
    try {
      return await service.getCharacteristic(fullUuid);
    } catch (_) {
      return await service.getCharacteristic(parseInt(shortHex, 16));
    }
  }

  async function bindCharacteristic(char, handler) {
    char.addEventListener("characteristicvaluechanged", (event) => {
      lastNotifyAt = Date.now();
      handler(event.target.value);
    });

    try {
      const initial = await char.readValue();
      handler(initial);
    } catch (_) {
      // Some iOS BLE bridges deliver values via notifications only
    }

    await sleep(120);

    try {
      await char.startNotifications();
    } catch (_) {
      // Fallback polling below will still read values periodically
    }

    await sleep(120);
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    isPolling = false;
  }

  function startFallbackPolling() {
    stopPolling();
    pollTimer = setInterval(async () => {
      if (!device || !device.gatt || !device.gatt.connected || isPolling) return;
      // Only poll if notifications haven't arrived recently (Bluefy/iOS fallback)
      if (Date.now() - lastNotifyAt < 4000) return;

      isPolling = true;
      try {
        for (const item of boundChars) {
          if (!device || !device.gatt || !device.gatt.connected) break;
          try {
            const val = await item.char.readValue();
            item.handler(val);
          } catch (_) {
            // Ignore transient read error on a single cycle
          }
          await sleep(120);
        }
      } finally {
        isPolling = false;
      }
    }, 2500);
  }

  function onDisconnected() {
    stopPolling();
    boundChars = [];
    setStatus(false, "연결 끊김");
    deviceInfo.textContent = "기기 미연결";
  }

  async function requestSensorDevice() {
    // Bluefy on iOS often fails to match 16-bit service filters; use acceptAllDevices there.
    if (isIOSLike) {
      return await navigator.bluetooth.requestDevice({
        acceptAllDevices: true,
        optionalServices: [ESS_SERVICE],
      });
    }

    try {
      return await navigator.bluetooth.requestDevice({
        filters: [{ services: [ESS_SERVICE] }],
        optionalServices: [ESS_SERVICE],
      });
    } catch (err) {
      if (err && err.name === "NotFoundError") throw err;
      return await navigator.bluetooth.requestDevice({
        acceptAllDevices: true,
        optionalServices: [ESS_SERVICE],
      });
    }
  }

  async function getEssService(server) {
    try {
      return await server.getPrimaryService(ESS_SERVICE);
    } catch (_) {
      try {
        return await server.getPrimaryService(0x181a);
      } catch (__) {
        const services = await server.getPrimaryServices();
        const found = services.find((s) => matchesShortUuid(s.uuid, "181a"));
        if (!found) {
          throw new Error("Environmental Sensing Service (0x181A)를 찾을 수 없습니다.");
        }
        return found;
      }
    }
  }

  async function connect() {
    refreshCompatNotice();
    if (!hasWebBluetooth()) {
      showError("이 브라우저에서는 Web Bluetooth를 사용할 수 없습니다. iPhone은 Bluefy 앱, PC/Android는 Chrome·Edge에서 열어주세요.");
      return;
    }

    showError("");
    stopPolling();
    boundChars = [];
    connectBtn.disabled = true;
    setStatus(false, "센서 검색 중...");

    try {
      device = await requestSensorDevice();
      device.addEventListener("gattserverdisconnected", onDisconnected);
      setStatus(false, "GATT 연결 중...");

      const server = await device.gatt.connect();
      await sleep(250);

      setStatus(false, "서비스 조회 중...");
      const service = await getEssService(server);
      await sleep(150);

      let allChars = null;
      try {
        allChars = await service.getCharacteristics();
      } catch (_) {
        allChars = null;
      }

      co2History = [];
      renderChart();

      setStatus(false, "센서 구독 중...");
      const specs = [
        { uuid: TEMP_CHAR, short: "2a6e", handler: handleTemp },
        { uuid: HUM_CHAR, short: "2a6f", handler: handleHum },
        { uuid: CO2_CHAR, short: "2b8c", handler: handleCO2 },
      ];

      // Strictly sequential GATT operations for iOS / Bluefy CoreBluetooth compatibility
      for (const spec of specs) {
        const char = await findCharacteristic(service, spec.uuid, spec.short, allChars);
        await bindCharacteristic(char, spec.handler);
        boundChars.push({ char, handler: spec.handler });
      }

      const name = device.name || "ESP32-ENV";
      setStatus(true, name);
      deviceInfo.textContent = `연결됨: ${name}`;
      startFallbackPolling();
    } catch (err) {
      if (err && err.name !== "NotFoundError") {
        const detail = err.message || String(err);
        showError(`연결 오류 (${err.name || "Error"}): ${detail}`);
      }
      setStatus(false, "연결 대기");
    } finally {
      connectBtn.disabled = false;
    }
  }

  function disconnect() {
    stopPolling();
    boundChars = [];
    if (device && device.gatt && device.gatt.connected) {
      device.gatt.disconnect();
    }
    device = null;
    setStatus(false, "연결 대기");
    deviceInfo.textContent = "기기 미연결";
  }

  connectBtn.addEventListener("click", () => {
    if (device && device.gatt && device.gatt.connected) {
      disconnect();
    } else {
      connect();
    }
  });
})();
