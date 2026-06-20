# eveng-mikrotik

Automated tooling for integrating MikroTik CHR (Cloud Hosted Router) images into Eve-NG (Emulated Virtual Environment-Next Generation). Downloads official CHR releases, generates Eve-NG QEMU templates with per-model interface mappings, and patches disk images with RouterOS configuration before first boot.

## Features

- **Download CHR images** directly from MikroTik's official server (`download.mikrotik.com`)
- **Generate Eve-NG templates** with correct CPU, RAM, Ethernet port, and interface definitions per model
- **Patch qcow2 images** by booting in QEMU, applying per-model RouterOS configuration via serial console, then shutting down cleanly
- **Supports both legacy and modern CHR login flows** (pre-7.23 `MikroTik Login:` and 7.23+ `CHR Login:`)
- **Layered RSC configuration** — model default + global custom + model-specific custom applied in order
- **Proxy support** for restricted network environments
- **Idempotent downloads** — scripts track state to avoid redundant work

## Supported Models

| Model | Description | CPU | RAM | ETH Ports |
|-------|-------------|-----|-----|-----------|
| ccr2004 | Cloud Core Router 2004 | 4 | 4096 | 4 |
| ccr2216 | Cloud Core Router 2216 | 16 | 16384 | 16 |
| crs309 | Cloud Router Switch 309 | 8 | 1024 | 8 |
| crs326 | Cloud Router Switch 326 | 24 | 2048 | 24 |
| crs520 | Cloud Router Switch 520 | 16 | 1024 | 20 |

Configuration details and interface names are defined in `templates/<model>.json`.

## Directory Structure

```
eveng-mikrotik/
├── eveng-mikrotik.sh          # Main download + template-generation script
├── patch-qcow2.sh             # QEMU boot + apply RSC config + shutdown
├── patch-qcow2.exp            # Expect script for serial console automation
├── templates/                 # Per-model definitions and RouterOS configs
│   ├── <model>.json           # Model metadata (CPU, RAM, ETH, eth_names)
│   ├── <model>.rsc            # Model-specific default config (committed)
│   ├── global-custom.rsc      # Optional: apply to all models (gitignored)
│   └── <model>-custom.rsc     # Optional: model-specific overrides (gitignored)
└── mikrotik-template.yml      # Jinja-like template for Eve-NG node YAML
```

## Usage

### Prerequisites

Install required system packages:

```bash
# Debian/Ubuntu
apt install qemu-system-x86 expect netcat curl jq unzip grep awk sed diffutils

# RHEL/CentOS/Fedora
dnf install qemu-system-x86 expect nmap-ncat curl jq unzip grep gawk sed diffutils
```

### 1. Create Eve-NG Template (download CHR + generate YAML)

```bash
./eveng-mikrotik.sh crs309 7.23.1 --verbose --force
```

Arguments:

- `MODEL` — model name (e.g. `crs309`, `crs520`, `ccr2004`)
- `VERSION` — MikroTik RouterOS version (e.g. `7.23.1`)

Options:

- `--verbose` — show detailed step-by-step output
- `--force` — overwrite existing file/directory without prompting
- `--help` — show usage

### 2. Patch qcow2 Image (apply RouterOS config)

```bash
./patch-qcow2.sh /path/to/mikrotik-crs309-7.23.1/hda.qcow2 --verbose
```

Arguments:

- `<hda.qcow2 path>` — path to the CHR disk image; model is auto-detected from the parent directory name (e.g. `mikrotik-crs309-7.23.1` → `crs309`)

Options:

- `--monitor-port N` — QEMU monitor telnet port (default: `6000`)
- `--serial-port N`  — QEMU serial telnet port (default: `6001`)
- `--verbose`        — show detailed progress

## How Patch Works

1. **QEMU Launch** — `patch-qcow2.sh` starts `qemu-system-x86_64` with `-daemonize` and telnet-backed monitor/serial on configurable ports.
2. **Readiness Poll** — polls serial port up to 15s until QEMU accepts connections.
3. **Expect Script** — `patch-qcow2.exp` connects via telnet to the serial port and:
   - Presses Enter to bypass blank-line boot prompts
   - Matches `CHR Login:` or `MikroTik Login:` with `(?i).*login:`
   - Logs in as `admin` with blank password
   - Skips password-change prompt with Ctrl-C if it appears
   - Waits for `[admin@HOSTNAME]` prompt
   - Reads `templates/<model>.rsc` and sends each non-empty, non-comment line
   - Waits for prompt after each command (non-fatal timeout)
   - Sends `/system shutdown` and exits cleanly
4. **Cleanup** — bash polls for QEMU process to exit (up to ~60s); if still running, sends `quit` to the monitor port via `nc`.

### RSC Customization

RouterOS configs are applied in layered order. Files are optional unless noted; missing files are silently skipped.

| Priority | File | Scope | Committed |
|----------|------|-------|-----------|
| 1 | `templates/<model>.rsc` | Model baseline | Yes |
| 2 | `templates/global-custom.rsc` | Global defaults for all models | No |
| 3 | `templates/<model>-custom.rsc` | Model-specific overrides | No |

Lines are sent sequentially across all files. Empty lines and `#` comments are skipped. Each command waits for the `[admin@...]` prompt before proceeding (non-fatal timeout).

### Login Flow Handling

| CHR Version | Login Prompt | Password Prompt | Post-Login |
|-------------|-------------|-----------------|------------|
| Pre-7.23    | `MikroTik Login:` | blank | skip password-change |
| 7.23+       | `CHR Login:`      | blank | skip password-change |

## Files Changed

- **`patch-qcow2.exp`** — standalone expect script; 3 args: `model serial_port monitor_port`
- **`patch-qcow2.sh`** — calls expect script, removed inline heredoc and PID tracking
- **`templates/<model>.rsc`** — per-model RouterOS configuration (add/update as needed)

## Customization

Create optional files to extend or override the committed model configs:

- `templates/global-custom.rsc` — commands applied to every model after its baseline
- `templates/<model>-custom.rsc` — commands applied only to a specific model, overriding earlier files

Both files are gitignored by default and do not need to exist.

## Troubleshooting

- **`Failed to find an available port`** — stale QEMU on ports 6000/6001. Kill it via monitor: `echo -e "quit" | nc -w 2 127.0.0.1 6000`
- **`ERROR: no login prompt after boot`** — image not ready; increase timeout or check QEMU console output
- **`ERROR: RSC file ... not found`** — ensure `templates/<model>.rsc` exists for the model passed to `patch-qcow2.sh`

## License

GPLv3 — see `LICENSE` for details.
