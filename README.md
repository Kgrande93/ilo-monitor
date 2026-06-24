# iLO Monitor - grandedata.no

A self-hosted monitoring script that polls the HP iLO interface via IPMI and sends alerts via ntfy when temperatures are too high or critical errors are detected.

Built for HP ProLiant G9 (iLO 5 and 3) running in a Proxmox environment.

---

## How it works

The script is run automatically by cron every 5 minutes and does the following:

1. **Temperature monitoring** — Fetches temperature data from iLO via IPMI and sends an alert if a sensor reports a critical status.
2. **SEL check** — Checks the iLO log for critical events such as PSU failures, fan failures, and hardware degradation. Only alerts the first time a new error is detected.
3. **IPMI availability** — If iLO doesn't respond, one retry is made after 60 seconds before an alert about the missing response is sent.
4. **Cooldown** — The script remembers which errors have already been alerted on, so you don't get flooded with repeated messages.

---

## Requirements

- Debian 12 LXC on Proxmox
- `ipmitool` and `curl` (installed automatically by `install.sh`)
- iLO user with network access from the LXC
- Self-hosted [ntfy](https://ntfy.sh) instance

---

## Installation

### Step 1 - Create a Debian LXC

Use the community scripts on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"
```

### Step 2 - Clone the repo inside the LXC

```bash
apt-get install -y git
git clone https://github.com/Kgrande93/ilo-monitor.git
cd ilo-monitor
```

### Step 3 - Fill in config.env

Open `config.env` and fill in your own values:

```bash
nano config.env
```

You need to change the following:

| Variable         | What to fill in                                       |
| ---------------- | ------------------------------------------------------ |
| `ILO_G9_IP`      | IP address of the server's iLO interface               |
| `ILO_G9_USER`    | Username in the iLO panel (default: `Administrator`)   |
| `ILO_G9_PASS`    | The password you've set in the iLO panel                |
| `ILO_G9_NAME`    | Optional display name shown in alerts                  |
| `NTFY_URL`       | Full URL to your ntfy instance, including the topic      |
| `ALERT_COOLDOWN` | Seconds between repeated alerts (default: `3600`)       |

### Step 4 - Run the installation

```bash
bash install.sh
```

This installs `ipmitool`, creates the directory structure, copies files, and sets up cron.

### Step 5 - Test

```bash
bash /opt/ilo-monitor/ilo_monitor.sh test
```

You should receive a test alert in ntfy.

---

## Commands

Run a full check (SDR + SEL):
```bash
bash ilo_monitor.sh
```

Send a test message to ntfy:
```bash
bash ilo_monitor.sh test
```

Show the raw SEL log:
```bash
bash ilo_monitor.sh sel
```

Show raw SDR sensor data:
```bash
bash ilo_monitor.sh sdr
```

Show state files, SEL markers, and log:
```bash
bash ilo_monitor.sh status
```

Reset cooldown states:
```bash
bash ilo_monitor.sh reset-alerts
```

Reset SEL markers (re-alerts everything):
```bash
bash ilo_monitor.sh reset-sel
```

Show all commands:
```bash
bash ilo_monitor.sh help
```

---

## Files

| File             | Description                                          |
| ---------------- | ------------------------------------------------------ |
| `ilo_monitor.sh` | Main script — monitors iLO and sends alerts            |
| `config.env`     | Configuration file with credentials and settings       |
| `install.sh`     | Installation script run inside the LXC                 |
| `README.md`     | This file               |
| `LICENSE`     | LICENSE              |

---

## Logging

All events are logged to `/var/log/ilo-monitor.log`:

```bash
tail -f /var/log/ilo-monitor.log
```

---

## Security

- `config.env` has `chmod 600` — only root can read the credentials
- The iLO user should have read-only access in the iLO panel
- Credentials stay local to the LXC
