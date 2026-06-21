# eveng-mikrotik

Drop a vanilla CHR into Eve-NG and you get four `ether` interfaces — fine for a quick test drive, but useless for building a real network. To lab a proof of concept, mimic a production topology, or validate a config before touching hardware, you need interfaces that match the real thing. Manually adding ports in Eve-NG and renaming them inside the CHR is tedious, fragile, and often doesn't survive a reboot.

This project aims to fix that. It downloads official MikroTik CHR images, generates Eve-NG QEMU templates with per-model interface mappings (correct port counts, types, and names), and patches the disk image with a RouterOS configuration that renames interfaces to match their physical hardware equivalents. The result: a CHR that looks and acts like a CCR2004, CRS309, RB5009, or any supported model — so the config you build in the lab can be copied to production hardware with minimal edits.

## Features

- **Download CHR images** directly from MikroTik's official server (`download.mikrotik.com`)
- **Generate Eve-NG templates** with CPU, RAM, Ethernet port, and interface definitions per model
- **Patch qcow2 images** by booting in QEMU, applying per-model RouterOS configuration via serial console, then shutting down cleanly
- **Supports both legacy and modern CHR login flows** (pre-7.23 `MikroTik Login:` and 7.23+ `CHR Login:`)
- **Layered RSC configuration** — generated model default + global custom + model-specific custom applied in order
- **Proxy support** for restricted network environments

## Supported Models

`ccr2004`, `ccr2216`, `crs309`, `crs326`, `crs520`, `rb5009`

Configuration details (interface names, etc.) are defined in `templates/<model>.json`.

### Interface Naming Reference

MikroTik product codes encode the interface types and counts in their model name. The following table decodes the naming convention.

| Connector | Model Suffix | Speed | Interface Type | Used On |
| ----------- | ------------- | ------- | --------------- | --------- |
| `ether` | — | 1 Gbps | Copper RJ45 | RB5009, CRS326 |
| `sfp-sfpplus` | `S+` | 1 / 10 Gbps | SFP / SFP+ | CCR2004, CRS309, CRS326, RB5009 |
| `sfp28` | `S28` | 25 Gbps | SFP28 | CCR2004, CCR2216, CRS520 |
| `qsfpplus` | `Q+` | 40 Gbps | QSFP+ | CCR2216, CRS326 |
| `qsfp28` | `Q28` | 100 Gbps | QSFP28 | CRS520 |

### Interface Inventory by Model

| Full Model Code | 1G RJ45 | SFP+ (1 / 10G) | SFP28 (25G) | QSFP+ (40G) | QSFP28 (100G) |
| ----------------- | --------- | --------------- | ------------- | ------------- | --------------- |
| `CCR2004-1G-12S+2XS` | 1 | 12 | 2 | — | — |
| `CCR2216-1G-12S+2XS+2Q` | 1 | — | 12 | 2 | — |
| `CRS309-1G-8S+` | 1 | 8 | — | — | — |
| `CRS326-24G-2S+RM` | 24 | 2 | — | — | — |
| `CRS520-4XS-16XQ-RM` | — | — | 4 | — | 16 |
| `RB5009UG+S+IN` | 8 | 1 | — | — | — |

## Directory Structure

```console
eveng-mikrotik/
├── build-mikrotik-qemu.sh      # Main download + template-generation script
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
apt install qemu-system-x86 expect netcat curl jq unzip grep awk sed diffutils
```

### 1. Create Eve-NG Template (download CHR + generate YAML)

```bash
./build-mikrotik-qemu.sh crs309 7.23.1
```

Arguments:

- `MODEL` — model name (e.g. `crs309`, `crs520`, `ccr2004`)
- `VERSION` — MikroTik RouterOS version (e.g. `7.23.1`)

Options:

- `--verbose` — show detailed step-by-step output
- `--force` — overwrite existing file/directory without prompting
- `--debug` — preserve generated `/tmp` debug files
- `--log` — write build output to `/tmp/build-mikrotik-qemu-YYYYMMDD-HHMMSS.log`
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

## RSC Customization

The base RSC is generated on-the-fly from `templates/<model>.json`. Additional optional files are applied in layered order. Missing files are silently skipped.

| Priority | File | Scope | Source |
| ---------- | ------ | ------- | -------- |
| 1 | | Model baseline (generated) | `mikrotik-template.rsc` + `<model>.json` |
| 2 | `templates/global-custom.rsc` | Global defaults for all models | User-defined (gitignored) |
| 3 | `templates/<model>-custom.rsc` | Model-specific overrides | User-defined (gitignored) |

### Login Flow Handling

| CHR Version | Login Prompt | Password Prompt | Post-Login |
| ------------- | ------------- | ----------------- | ------------ |
| Pre-7.23    | `MikroTik Login:` | blank | skip password-change |
| 7.23+       | `CHR Login:`      | blank | skip password-change |

## Customization

Create optional files to extend or override the generated model config:

- `templates/global-custom.rsc` — commands applied to every model after its baseline
- `templates/<model>-custom.rsc` — commands applied only to a specific model, overriding earlier files

## License

GPLv3 — see `LICENSE` for details.
