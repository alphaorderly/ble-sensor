(() => {
  const ESS_SERVICE = 0x181a;
  const TEMP_CHAR = 0x2a6e;
  const HUM_CHAR = 0x2a6f;
  const CO2_CHAR = 0x2b8c;
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

  if (!("bluetooth" in navigator)) {
    compatWarning.hidden = false;
    connectBtn.disabled = true;
  }

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

  function handleTemp(dataView) {
    if (dataView.byteLength < 2) return;
    const tempC = dataView.getInt16(0, true) / 100;
    tempVal.textContent = tempC.toFixed(1);
    touchTimestamp();
  }

  function handleHum(dataView) {
    if (dataView.byteLength < 2) return;
    const humPct = dataView.getUint16(0, true) / 100;
    humVal.textContent = humPct.toFixed(1);
    touchTimestamp();
  }

  function handleCO2(dataView) {
    if (dataView.byteLength < 2) return;
    const ppm = dataView.getUint16(0, true);
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

  async function bindCharacteristic(service, uuid, handler) {
    const char = await service.getCharacteristic(uuid);
    const initial = await char.readValue();
    handler(initial);
    char.addEventListener("characteristicvaluechanged", (event) => {
      handler(event.target.value);
    });
    await char.startNotifications();
  }

  function onDisconnected() {
    setStatus(false, "연결 끊김");
    deviceInfo.textContent = "기기 미연결";
  }

  async function connect() {
    showError("");
    connectBtn.disabled = true;
    setStatus(false, "센서 검색 중...");

    try {
      device = await navigator.bluetooth.requestDevice({
        filters: [{ services: [ESS_SERVICE] }, { namePrefix: "ESP32-ENV" }],
        optionalServices: [ESS_SERVICE],
      });

      device.addEventListener("gattserverdisconnected", onDisconnected);
      setStatus(false, "연결 중...");

      const server = await device.gatt.connect();
      const service = await server.getPrimaryService(ESS_SERVICE);

      co2History = [];
      renderChart();

      await Promise.all([
        bindCharacteristic(service, TEMP_CHAR, handleTemp),
        bindCharacteristic(service, HUM_CHAR, handleHum),
        bindCharacteristic(service, CO2_CHAR, handleCO2),
      ]);

      const name = device.name || "ESP32-ENV";
      setStatus(true, name);
      deviceInfo.textContent = `연결됨: ${name}`;
    } catch (err) {
      if (err && err.name !== "NotFoundError") {
        showError(`연결 오류: ${err.message || err}`);
      }
      setStatus(false, "연결 대기");
    } finally {
      connectBtn.disabled = false;
    }
  }

  function disconnect() {
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
