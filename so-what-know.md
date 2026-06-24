# So, What Now? — Creating a MikroTik JSON Template by Hand

## When Do You Need This?

`build-mikrotik-json.sh` only auto-generates JSON for models starting with **CCR**, **CRS**, or **RDS** (Cloud Router, Cloud Smart Switch, ROSE Data server). But MikroTik has other product lines:

| Prefix | Product Line | Example |
|--------|-------------|---------|
| **RB** | RouterBOARD | RB5009, RB4011 |
| **RBM** | RouterBOARD M (Metal) | RBM11G |
| **mAP** | Micro Access Point | mAP lite |
| **wAP** | Wireless Access Point | wAP R |
| **hAP** | Home Access Point | hAP ax² |
| **cAP** | Ceiling Access Point | cAP ax |
| **sAP** | Sector Access Point | sAP ax |
| and more… | | |

For these, the script won't auto-generate a JSON file. You need to create one manually. This guide walks you through it. We can't really emulate RF yet in common tools, maybe someday.

## What the JSON File Does

An Eve-NG MikroTik template uses a JSON file to tell the build system:

- How many network ports the device has
- What each port is named in RouterOS
- How much RAM and CPU to allocate in QEMU

Without a JSON file, `build-mikrotik-qemu.sh` won't find your model.

## JSON File Schema

```jsonc
{
  // REQUIRED: The identifier used in filenames and QEMU directory names.
  // Use the model variant without physical mount suffixes (RM/IN/OUT/PC).
  // Replace "+" with "plus" for filesystem compatibility.
  // Example: "RB5009UPrplusSplus" for RB5009UP+SP+
  "name": "RB5009UGplusSplus",

  // REQUIRED: The full official MikroTik model name for display.
  // Copy from MikroTik's website or router banner.
  "model": "RB5009UG+S+",

  // REQUIRED: Human-friendly name shown in Eve-NG's node list.
  "description": "MikroTik RB5009",

  // REQUIRED: Number of CPU cores to assign to QEMU.
  // Most MikroTik devices are 1 CPU. Check your device spec.
  "num_cpu": 1,

  // REQUIRED: RAM in megabytes.
  // Check MikroTik specs for your device's RAM.
  // CHR licenses also affect available RAM (free=512MB, paid=unlimited).
  "ram": 256,

  // REQUIRED: Total number of network interfaces.
  // This must match the length of "ether_ports" below.
  "ether_ports": 9,

  // REQUIRED: Ordered list of RouterOS interface names.
  // These must match the names the device uses natively.
  // The build script renames interfaces to match these at first boot.
  "ether_names": [
    "ether1",
    "ether2",
    "ether3",
    "ether4",
    "ether5",
    "ether6",
    "ether7",
    "ether8",
    "sfp-sfpplus1"
  ]
}
```

## Finding the Right Interface Names

1. **MikroTik Wiki** — The most reliable source. Each model's wiki page lists its ports:
   - <https://mikrotik.com/products/matrix/list> (find your model)
   - <https://wiki.mikrotik.com/wiki/Manual:Interface>

2. **RouterOS CLI** — If you have (or can demo) the device:

   ```
   [admin@device] /interface print
   ```

   The `name` column shows the exact interface identifiers.

3. **CHR with default config** — Download a CHR and boot it:

   ```
   [admin@chr] /interface ethernet print
   ```

   This shows the default names before any renaming.

## Port Type Reference

RouterOS uses different interface name prefixes depending on the hardware:

| Hardware Type | RouterOS Name Pattern | Example |
|--------------|----------------------|---------|
| 100 Mbps copper | `etherN` | `ether1` |
| 1 Gbps copper | `etherN` | `ether2` |
| 1 Gbps SFP | `sfp-sfpplusN` | `sfp-sfpplus1` |
| 10 Gbps SFP+ | `sfp-sfpplusN` | `sfp-sfpplus2` |
| 25 Gbps SFP28 | `sfp28-N` | `sfp28-1` |
| 40 Gbps QSFP+ | `qsfpplusN-1` | `qsfpplus1-1` |
| 100 Gbps QSFP28 | `qsfp28-N-1` | `qsfp28-1-1` |
| Combo (copper + SFP) | `comboN` | `combo1` |

**Important:** QSFP+ and QSFP28 ports use `-1` because they have internal lanes. We can
only emulate lane 1 in Eve-NG, so always use `qsfpplus1-1` or `qsfp28-1-1` format.

## Step-by-Step Guide

### Step 1: Gather specs from MikroTik's website

Go to <https://mikrotik.com/products> and find your device. Note:

- Number of each port type
- RAM amount
- CPU count (almost always 1)
- The exact RouterOS interface names

### Step 2: Create the JSON file

Save it as `templates/<name>.json` where `<name>` follows these naming rules:

1. Start with the model name (case preserved as you typed it)
2. Replace `+` with `plus`
3. Strip physical mount suffixes: `-RM`, `-IN`, `-OUT`, `-PC`

**Examples:**

| Full Model | JSON Filename |
|-----------|--------------|
| `RB5009UPr+S+IN` | `templates/RB5009UPrplusSplus.json` |
| `RB4011iGS+RM` | `templates/RB4011iGSplus.json` |
| `RB960PGS` | `templates/RB960PGS.json` |
| `hAP ax²` | `templates/hAPax2.json` |

### Step 3: Write the content

Use the example below as a template. For a complete commented example, see `templates/example.json`.

### Step 4: Reference it from Eve-NG

Use the `<model>` value (matching your filename, without `.json`) when building:

```bash
./build-mikrotik-qemu.sh RB5009UPr+S+ 7.20.1
```

## Troubleshooting

**"Error: Model 'XXX' not supported. JSON file is missing."**

- The JSON file must be in `templates/` with the exact name
- The `name` field in the JSON must match the filename (without `.json`)
- Check for typos in the filename or case mismatches

**Ports show up as `etherX` instead of the correct type**

- Verify the `ether_names` array uses the correct RouterOS prefixes from the table above
- Make sure `ether_ports` count matches the array length

**QEMU image won't boot / template grayed out**

- Check that the directory was created under `/opt/unetlab/addons/qemu/`
- Run `/opt/unetlab/wrappers/unl_wrapper -a fixpermissions` after building
- Check Eve-NG logs: `/var/log/unetlab/`

## Getting Help

If your model still doesn't work after creating a JSON file:

1. Check existing templates in `templates/` for similar models as examples
2. Verify interface names on the MikroTik wiki
3. Open an issue with your model's specs and the JSON you created (<https://github.com/seancrites/eveng-mikrotik/issues>)
