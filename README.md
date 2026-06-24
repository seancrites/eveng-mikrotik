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

## Directory Structure

```console
eveng-mikrotik/
├── build-mikrotik-json.sh      # Generate per-model JSON from MikroTik model name
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

As of Eve-NG v6.2.0-4, the only additional dependencies are `jq` and `expect`.

Install required system packages:

```bash
apt install qemu-system-x86 expect netcat curl jq unzip grep awk sed diffutils
```

### Local Usage

Clone this repository to `/usr/local/bin` so the scripts are on your system `PATH`:

> **⚠️ Case sensitivity matters.** The model name is case-sensitive across all scripts. Whatever case you use when creating a JSON file with `build-mikrotik-json.sh` must be used **exactly** when building the QEMU image with `build-mikrotik-qemu.sh`. There is no case folding — `CCR2004-16G-2S+` and `ccr2004-16g-2s+` are treated as different models. Pick a convention and stick with it.
>
> Additionally, the `+` character in model names is automatically expanded to the word `plus` in all filenames and directory names (e.g. `CCR2004-16G-2S+` → `CCR2004-16G-2Splus.json`). This is because `+` conflicts with Eve-NG's naming conventions and will cause templates to be unselectable. The `+` is preserved only in the human-readable `description` and OEM `model` fields inside the JSON.

```bash
sudo git clone https://github.com/seancrites/eveng-mikrotik.git /usr/local/bin/eveng-mikrotik
```

Then navigate into the directory:

```bash
cd /usr/local/bin/eveng-mikrotik
```

Make the scripts executable if needed, then proceed to the steps below.

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

### 2. Optional: Generate per-model JSON (from MikroTik model name)

This step is **not required** — several pre-built JSON templates for common CCR, CRS, and RDS models are already included in `templates/`. Feel free to use those as-is, or generate your own with longer/variant-specific model names using this script.

The script parses a MikroTik model name to extract the interface count and port types, then writes a JSON definition file. **Each model variant** (e.g., `CCR2004-16G-2S+` vs. `CCR2004-1G-12S+2XS`) produces its own JSON file, so variant-specific port mappings are not lost.

Physical mounting suffixes (`-RM`, `-IN`, `-OUT`, `-PC`) are stripped automatically from the output filename since they do not affect network performance or port layout.

```bash
./build-mikrotik-json.sh CRS510-8XS-2XQ
./build-mikrotik-json.sh CRS326-24G-2S+RM
./build-mikrotik-json.sh CRS326-24S+2Q+RM
./build-mikrotik-json.sh CCR2004-1G-12S+2XS
./build-mikrotik-json.sh CCR2004-16G-2S+
```

Port spec abbreviations recognized:

| Abbrev | RouterOS Root | Notes |
| -------- | -------------- | ----- |
| `xs` | `sfp28` | SFP28, 25 Gbps |
| `xq` | `qsfp28` | QSFP28, 100 Gbps; lane 1 used only |
| `s` / `s+` | `sfp-sfpplus` | SFP/SFP+, 1 / 10 Gbps |
| `q` / `q+` | `qsfp28` / `qsfpplus` | 100 / 40 Gbps; lane 1 used only |
| `gf` / `g` / `g+` | `ether` | 1 Gbps copper |
| `c` / `c+` | `combo` | Combo port |
| `p` / `p+` / `xg` / `xp` / `fi` / `fr` / `fp` / `f` | `ether` | Copper ethernet variants |

Output: `templates/MODEL_BASE.json`

Examples of generated filenames:

| Full Model Name | Output File |
|-----------------|-------------|
| `CCR2004-16G-2S+` | `templates/CCR2004-16G-2Splus.json` |
| `CCR2004-1G-12S+2XS` | `templates/CCR2004-1G-12Splus2XS.json` |
| `CRS326-24G-2S+RM` | `templates/CRS326-24G-2Splus.json` |
| `CRS326-24S+2Q+RM` | `templates/CRS326-24Splus2Qplus.json` |
| `CRS326-4C+20G+2Q+RM` | `templates/CRS326-4Cplus20Gplus2Qplus.json` |
| `CRS510-8XS-2XQ` | `templates/CRS510-8XS-2XQ.json` |

These JSON files are referenced by `build-mikrotik-qemu.sh` during template generation.

**Note:** Models without a port specification in their name (e.g., `hEX`, `rb5009`) should have their JSON file created manually in `templates/`. The script only auto-generates JSON for models starting with **CCR**, **CRS**, or **RDS**. For all other models (RB, RBM, hAP, etc.), see [`so-what-know.md`](so-what-know.md) for a step-by-step guide on creating a JSON template by hand. An commented example is also available at [`templates/example.json`](templates/example.json).

### 3. Patch qcow2 Image (apply RouterOS config)

This step is not necessary, `build-mikrotik-qemu.sh` already handles this process. If you want to update the configuration of a CHR outside of the initial deployment process, this is for you. This script does not handle config deconfliction when running the same 'set' command a second time. CHR will give errors on the CLI but we won't check or report them.

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

The base RSC (model specific interface names, setting hostname and removing the dhcp-client) is generated on-the-fly from `templates/<model>.json`. Additional optional files are applied in layered order. Missing files are silently skipped.

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
