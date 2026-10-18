# Power Monitoring Build: Rig, Apartment and Local-AI Analyst

A step-by-step guide, built in phases. Every phase works on its own and is enough for at least one post.

**Hardware you have:** Raspberry Pi (Compute Module + carrier, add NVMe), Raspberry Pi Zero, ESP32-S3.
**To buy:** an energy-monitoring smart plug (Phase 1), a small display for the Pi Zero (Phase 2), a light-sensor module for the ESP32 (Phase 3).

---

## ⚠️ Safety rules (read first)

1. **Never open the switchboard or touch mains wiring.** In Australia that's licensed-electrician work. Nothing in this guide needs it.
2. **Use only plugs approved for Australian sockets** (look for the RCM mark). 10 A plugs handle ~2,400 W. Your rig peaks well below that, but don't put other heavy loads on the same plug or power board.
3. **Don't modify, open or reflash a plug that's plugged in.** Choose one that supports local control out of the box.
4. **Apartment meters:** check with building management before attaching anything to a meter, even a sensor taped over its LED. Meter rooms are often locked for a reason.

---

## The architecture

```
[Rig smart plug] ──Wi-Fi, local API──┐
[ESP32-S3 + light sensor on meter LED] ──MQTT──┤
[GPU sysfs on the rig: gpu-logger.sh] ─────────┤
                                               ▼
        Raspberry Pi (NVMe) — Docker: Mosquitto (MQTT) → Telegraf → InfluxDB → Grafana
                                               │
        Pi Zero + small display ◄── live watts  │
                                               ▼
        Local LLM on the rig ◄── weekly data → plain-English report
```

All devices live on your **isolated lab network**. No cloud apps.

---

## Phase 1: Measure the rig (enough for the cost-per-token post)

### 1.1 Choose and set up the plug
- Pick an energy-monitoring plug sold for Australian sockets that offers a **local HTTP API**, so it works without the manufacturer's cloud. Shelly (Gen2+) and Tasmota-compatible plugs both do this; check the specific AU model before buying.
- Join it to your lab Wi-Fi, give it a **fixed IP** (DHCP reservation on your router), and **disable cloud access** in its settings.
- Plug the rig in through it, and the monitor too if you want total desk power. Write down which you chose.

### 1.2 Confirm you can read it locally
Replace `PLUG_IP` with its address:

```bash
# Shelly Gen2+ style:
curl -s "http://PLUG_IP/rpc/Switch.GetStatus?id=0"
# Tasmota style:
curl -s "http://PLUG_IP/cm?cmnd=Status%2010"
```

Look for the power field (`apower` on Shelly, `Power` under `ENERGY` on Tasmota). **Check the field names on your actual plug,** because firmware versions differ.

### 1.3 Quick measurement without the full stack
Good enough for the first post. Log every 2 seconds while you run a benchmark:

```bash
mkdir -p ~/bench/power
while true; do echo "$(date +%s),$(curl -s "http://PLUG_IP/rpc/Switch.GetStatus?id=0" | python3 -c 'import json,sys; print(json.load(sys.stdin)["apower"])')"; sleep 2; done | tee ~/bench/power/rig-$(date +%F-%H%M).csv
```

Ctrl+C to stop. Record three numbers:

| State | How | Watts |
|---|---|---|
| Idle | Services running, no model loaded, 5 min average | |
| Loaded idle | Model in VRAM, no requests, 5 min | |
| Under load | During `run-llamabench.sh` decode runs | |

### 1.4 Cost per million tokens

```
hours for 1M tokens = 1,000,000 ÷ (tokens per second × 3600)
kWh = (watts ÷ 1000) × hours
cost = kWh × your $/kWh   (from your electricity bill)
```

Example: 75 t/s → 3.7 h per 1M tokens. At 500 W that's 1.85 kWh; at $0.30/kWh, about **$0.56 per million tokens** (electricity only).

**Photo for the post:** the plug's own app or display showing watts mid-benchmark, next to the terminal results.

---

## Phase 2: The Pi historian and dashboard

### 2.1 Prepare the Pi
- Raspberry Pi OS Lite (64-bit) on the eMMC, with the NVMe mounted at `/data` for all databases and logs.
- Fixed IP on the lab network. Turn on the firewall and allow only SSH, Grafana (3000) and MQTT (1883) from your lab subnet:

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw allow from <LAB_SUBNET> to any port 22,1883,3000 proto tcp
sudo ufw enable
```

- Install Docker (`curl -fsSL https://get.docker.com | sh`, then log out and back in).

### 2.2 The stack (`/data/power/docker-compose.yml`)

```yaml
services:
  mosquitto:
    image: eclipse-mosquitto:2
    ports: ["1883:1883"]
    volumes: ["./mosquitto:/mosquitto/config", "/data/power/mosquitto-data:/mosquitto/data"]
    restart: unless-stopped
  influxdb:
    image: influxdb:2
    volumes: ["/data/power/influx:/var/lib/influxdb2"]
    restart: unless-stopped
  telegraf:
    image: telegraf:latest
    volumes: ["./telegraf.conf:/etc/telegraf/telegraf.conf:ro"]
    depends_on: [influxdb, mosquitto]
    restart: unless-stopped
  grafana:
    image: grafana/grafana:latest
    ports: ["3000:3000"]
    volumes: ["/data/power/grafana:/var/lib/grafana"]
    restart: unless-stopped
```

Mosquitto 2 rejects remote connections by default, so create `./mosquitto/mosquitto.conf` with a password file. Don't leave it open even on the lab network.

```
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
```

Create the user with: `docker compose run --rm mosquitto mosquitto_passwd -c /mosquitto/config/passwd power`

### 2.3 Telegraf: collect the plug and MQTT data (`telegraf.conf`, template)

```toml
[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "${INFLUX_TOKEN}"
  organization = "home"
  bucket = "power"

# Rig plug, every 2 s (Shelly Gen2+ example; adjust the URL/field for your plug)
[[inputs.http]]
  urls = ["http://PLUG_IP/rpc/Switch.GetStatus?id=0"]
  interval = "2s"
  name_override = "rig_plug"
  data_format = "json"
  fieldinclude = ["apower", "voltage", "current", "aenergy_total"]

# Apartment meter from the ESP32 (Phase 3)
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto:1883"]
  username = "power"
  password = "${MQTT_PASSWORD}"
  topics = ["apartment-meter/sensor/+/state"]
  data_format = "value"
  data_type = "float"
  name_override = "apartment"
```

Set up InfluxDB first (open `http://PI_IP:8086` once, or run its setup CLI) to create the org, bucket and token. Pass the token and MQTT password to Telegraf through environment variables, not hard-coded in the file. **Verify field names** against Phase 1.2 output; Telegraf flattens nested JSON with underscores.

### 2.4 Grafana
- Log in at `http://PI_IP:3000` and change the admin password immediately.
- Add InfluxDB as a data source, then build panels for rig watts (live), rig kWh per day, and later apartment watts.

### 2.5 Pi Zero live display (your photo)
- Hardware: a small I²C OLED (e.g., an SSD1306 128×64 module) on the Pi Zero's I²C pins (3.3 V, GND, SDA, SCL). Enable I²C in `raspi-config`.
- Software: `pip install luma.oled requests` in a venv.
- Script template (`watts.py`), reading the plug directly so it works even if the Pi historian is down:

```python
import time, requests
from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas

dev = ssd1306(i2c(port=1, address=0x3C))
URL = "http://PLUG_IP/rpc/Switch.GetStatus?id=0"   # adjust for your plug
while True:
    try:
        w = requests.get(URL, timeout=2).json()["apower"]
        text = f"AI rig\n{w:,.0f} W"
    except Exception:
        text = "AI rig\n--- W"
    with canvas(dev) as draw:
        draw.multiline_text((4, 8), text, fill="white")
    time.sleep(2)
```

Run it at boot with a systemd service once it works. Use a bigger font (`ImageFont.truetype`) for a photo-friendly display.

---

## Phase 3: Whole apartment via the meter LED (ESP32-S3)

### 3.1 Check the meter first
- Find the meter and confirm building management is fine with a taped-on sensor.
- On the meter faceplate, find the **pulse constant** (e.g., "1000 imp/kWh"). It's often printed next to the LED.

### 3.2 Hardware
- A light-sensor module with a digital output (a photodiode/LDR board with a comparator), wired to the ESP32-S3: VCC → 3.3 V, GND → GND, DO → a GPIO (e.g., GPIO4).
- Tape the sensor directly over the pulse LED and shield it from room light with black tape. Adjust the module's sensitivity screw until its LED blinks in time with the meter LED.
- Power the ESP32 from a USB adapter. It touches nothing electrical on the meter.

### 3.3 ESPHome config (template, `apartment-meter.yaml`)

```yaml
esphome:
  name: apartment-meter
esp32:
  board: esp32-s3-devkitc-1
wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
mqtt:
  broker: PI_IP
  username: power
  password: !secret mqtt_password
logger:
ota:
  - platform: esphome

sensor:
  - platform: pulse_meter
    pin: GPIO4
    name: "Apartment Power"
    unit_of_measurement: "W"
    internal_filter: 20ms        # tune if you see double counts
    timeout: 2min
    filters:
      - multiply: 60             # for 1000 imp/kWh: pulses/min × 60 = W. Other constants: 60000 ÷ imp/kWh
    total:
      name: "Apartment Energy"
      unit_of_measurement: "kWh"
      accuracy_decimals: 3
      filters:
        - multiply: 0.001        # for 1000 imp/kWh: 1 pulse = 0.001 kWh
```

Flash it with `esphome run apartment-meter.yaml` over USB the first time. Readings then arrive on MQTT topics like `apartment-meter/sensor/apartment_power/state`.

### 3.4 Validate
Compare a day's ESP32 total with your retailer's smart-meter data for the same day. Within a few percent means it's working. If it's way off, check the pulse constant and the sensor shielding.

---

## Phase 4: Modbus TCP layer (your Modbus post)

**Goal:** the Pi serves the latest readings as Modbus holding registers, like an energy meter in a building system. You then read them with a Modbus client and watch the plaintext traffic in Wireshark.

- Run a small `pymodbus` server on the Pi (in a venv or container) that updates registers every few seconds from InfluxDB. Suggested layout:

| Register | Value | Scaling |
|---|---|---|
| 40001 | Rig power | W |
| 40002 | Apartment power | W |
| 40003–40004 | Apartment energy | kWh × 1000 (32-bit) |

- **pymodbus's API changes between versions,** so start from the official server example matching the version you install, rather than code copied from an older post.
- Read it from your laptop with a Modbus client, capture the traffic in Wireshark, and note that there's no authentication at all. That's the post.
- Keep port 502 reachable **only inside the lab network.**

---

## Phase 5: Local-AI weekly analyst

**Goal:** the local LLM reads a week of data and writes a short report.

1. Query InfluxDB for daily totals: rig kWh, apartment kWh, rig share %, and peak watts.
2. Combine them with your benchmark throughput to get the cost per million tokens.
3. Send a prompt to your local OpenAI-compatible endpoint (LiteLLM or llama-server):

```bash
curl -s http://<LOCAL_ENDPOINT>/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "<MODEL>",
  "messages": [{"role":"user","content":"Here is a week of energy data as CSV: <DATA>. Write a 5-line report: total kWh, the AI rig share, cost per million tokens at $X/kWh, the biggest anomaly, one suggestion."}]}'
```

4. **Check the model's arithmetic against your own calculation** before posting anything. LLMs make number mistakes, and catching one is a post in itself.

**The "apartment PUE" (clearly labelled as an analogy):** total apartment power ÷ rig power. It isn't real PUE, but it's a fun way to show what a data centre metric means.

---

## Security checklist

- [ ] Every device on the isolated lab network, with fixed IPs
- [ ] Plug cloud access disabled
- [ ] Mosquitto: no anonymous access, password set
- [ ] Grafana admin password changed; InfluxDB token stored outside config files
- [ ] Pi firewall allows only the lab subnet
- [ ] Modbus port 502 not reachable outside the lab
- [ ] Screenshots: no IPs, Wi-Fi names, hostnames or tokens

---

## Posts and photos this produces

| Phase | Post | Photo |
|---|---|---|
| 1 | What my AI rig actually costs per million tokens | Plug reading mid-benchmark + results |
| 2 | I built a mini EPMS for my apartment | Grafana dashboard; Pi Zero display |
| 3 | Reading my electricity meter without touching a wire | Sensor taped over the meter LED |
| 4 | Modbus has no authentication: here's my own meter data in plaintext | Wireshark capture |
| 5 | My local AI writes my energy report (and where it got the maths wrong) | Report + your check |
