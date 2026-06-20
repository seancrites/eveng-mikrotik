# eveng-mikrotik

Automated tooling for integrating MikroTik CHR (Cloud Hosted Router) images into Eve-NG (Emulated Virtual Environment-Next Generation). Downloads official CHR releases, generates Eve-NG QEMU templates with per-model interface mappings, and patches disk images with RouterOS configuration before first boot.

## Features

- **Download CHR images** directly from MikroTik's official server (`download.mikrotik.com`)
- **Generate Eve-NG templates** with correct CPU, RAM, Ethernet port, and interface definitions per model
- **Patch qcow2 images** by booting in QEMU, applying per-model RouterOS configuration via serial console, then shutting down cleanly
- **Supports both legacy and modern CHR login flows** (pre-7.23 `MikroTik Login:` and 7.23+ `CHR Login:`)
- **Layered RSC configuration** — generated model default + global custom + model-specific custom applied in order
- **Proxy support** for restricted network environments
- **Idempotent downloads** — scripts track state to avoid redundant work

## Supported Models

`ccr2004`, `ccr2216`, `crs309`, `crs326`, `crs520`, `rb5009`

Configuration details (interface names, etc.) are defined in `templates/<model>.json`.

### Interface Naming Reference

MikroTik product codes encode the interface types and counts in their model name. The following table decodes the naming convention.

| Connector | Model Suffix | Speed | Interface Type | Used On |
|-----------|-------------|-------|---------------|---------|
| `ether` | — | 1 Gbps | Copper RJ45 | RB5009, CRS326 |
| `sfp-sfpplus` | `S+` | 1 / 10 Gbps | SFP / SFP+ | CCR2004, CRS309, CRS326, RB5009 |
| `sfp28` | `S28` | 25 Gbps | SFP28 | CCR2004, CCR2216, CRS520 |
| `qsfpplus` | `Q+` | 40 Gbps | QSFP+ | CCR2216, CRS326 |
| `qsfp28` | `Q28` | 100 Gbps | QSFP28 | CRS520 |

### Interface Inventory by Model

| Full Model Code | 1G RJ45 | SFP+ (1 / 10G) | SFP28 (25G) | QSFP+ (40G) | QSFP28 (100G) |
|-----------------|---------|---------------|-------------|-------------|---------------|
| `CCR2004-1G-12S+2XS` | 1 | 12 | 2 | — | — |
| `CCR2216-1G-12S+2XS+2Q` | 1 | — | 12 | 2 | — |
| `CRS309-1G-8S+` | 1 | 8 | — | — | — |
| `CRS326-24G-2S+RM` | 24 | 2 | — | — | — |
| `CRS520-4XS-16XQ-RM` | — | — | 4 | — | 16 |
| `RB5009UG+S+IN` | 8 | 1 | — | — | — |

## Directory Structure

```
eveng-mikrotik/
├── eveng-mikrotik.sh           # Main download + template-generation script
├── patch-qcow2.sh              # QEMU boot + RSC generation + apply config + shutdown
├── patch-qcow2.exp             # Expect script for serial console automation
├── templates/                  # Per-model definitions and RSC template
│   ├── mikrotik-template.rsc   # Base RSC template (placeholders expanded at runtime)
│   ├── <model>.json            # Model metadata (name, ether_names, cpu, ram)
│   ├── global-custom.rsc       # Optional: apply to all models (gitignored)
│   └── <model>-custom.rsc      # Optional: model-specific overrides (gitignored)
└── mikrotik-template.yml       # Jinja-like template for Eve-NG node YAML
```

## Usage

### Prerequisites

Install required system packages:

```bash
# Debian/Ubuntu
apt install qemu-system-x86 expect netcat curl jq unzip grep awk sed diffutils
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

1. **RSC Generation** — `patch-qcow2.sh` reads `templates/<model>.json` and `templates/mikrotik-template.rsc`, expands the `@@ETHER_PORTS@@`, `@@ETHER_NAMES_RENAME@@`, and `@@NAME@@` placeholders, and writes the result to `/tmp/<model>.rsc`. Ethernet port count is derived from the `ether_names` array in the JSON.
2. **QEMU Launch** — starts `qemu-system-x86_64` with telnet-backed monitor/serial on configurable ports.
3. **Readiness Poll** — polls serial port up to 15s until QEMU accepts connections.
4. **Expect Script** — `patch-qcow2.exp` connects via telnet to the serial port and:
   - Presses Enter to bypass blank-line boot prompts
   - Matches `CHR Login:` or `MikroTik Login:` with `(?i).*login:`
   - Logs in as `admin` with blank password
   - Skips password-change prompt with Ctrl-C if it appears
   - Waits for `[admin@HOSTNAME]` prompt
   - Reads the generated RSC from `/tmp/<model>.rsc` and applies it, then applies optional `global-custom.rsc` and `<model>-custom.rsc` if present
   - Sends `/system shutdown` and exits cleanly
5. **Cleanup** — bash polls for QEMU process to exit (up to ~60s); if still running, sends `quit` to the monitor port via `nc`.

### RSC Customization

The base RSC is generated on-the-fly from `templates/mikrotik-template.rsc` and `templates/<model>.json`. Additional optional files are applied in layered order. Missing files are silently skipped.

| Priority | File | Scope | Source |
|----------|------|-------|--------|
| 1 | `/tmp/<model>.rsc` | Model baseline (generated) | `mikrotik-template.rsc` + `<model>.json` |
| 2 | `templates/global-custom.rsc` | Global defaults for all models | User-defined (gitignored) |
| 3 | `templates/<model>-custom.rsc` | Model-specific overrides | User-defined (gitignored) |

### Login Flow Handling

| CHR Version | Login Prompt | Password Prompt | Post-Login |
|-------------|-------------|-----------------|------------|
| Pre-7.23    | `MikroTik Login:` | blank | skip password-change |
| 7.23+       | `CHR Login:`      | blank | skip password-change |

## RSC Template

The file `templates/mikrotik-template.rsc` is a RouterOS script containing three placeholders:

- `@@ETHER_PORTS@@` — replaced with the number of ethernet ports (derived from `ether_names` array length)
- `@@ETHER_NAMES_RENAME@@` — replaced with `set [find default-name=etherN] disable-running-check=no name=<name>` lines, one per entry in `ether_names`, in array order
- `@@NAME@@` — replaced with the uppercase model name (e.g. `ccr2004` → `CCR2004`)

The generated RSC is written to `/tmp/<model>.rsc` and is ephemeral. It is kept for debugging purposes.

## Customization

Create optional files to extend or override the generated model config:

- `templates/global-custom.rsc` — commands applied to every model after its baseline
- `templates/<model>-custom.rsc` — commands applied only to a specific model, overriding earlier files

Both files are gitignored by default and do not need to exist.

## Troubleshooting

- **`Failed to find an available port`** — stale QEMU on ports 6000/6001. Kill it via monitor: `echo -e "quit" | nc -w 2 127.0.0.1 6000`
- **`ERROR: no login prompt after boot`** — image not ready; increase timeout or check QEMU console output
- **`ERROR: Model JSON file not found`** — ensure `templates/<model>.json` exists for the model passed to `patch-qcow2.sh`

## License

GPLv3 — see `LICENSE` for details.
