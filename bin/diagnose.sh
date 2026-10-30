#!/usr/bin/env bash
# Layered diagnosis: find out which layer is blocking RAM RGB control.
#
#   L1 privileges        root / i2c group / /dev/i2c-* permissions
#   L2 SMBus adapter     kernel refused to bind the SMBus (ACPI OpRegion)
#   L3 udev rules        a rules file masking OpenRGB's packaged rules
#   L4 OpenRGB           installed? sees DRAM devices? model codes accepted?
#   L5 persistence       boot / resume service installed?
#
# Read-only. Runs as a normal user (root adds the SPD model check).
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/smbus.sh
. "$SCRIPT_DIR/../lib/smbus.sh"
# shellcheck source=../drivers/openrgb.sh
. "$SCRIPT_DIR/../drivers/openrgb.sh"

PROBLEMS=0

bad()  { printf '[fail] %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '[note] %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

head_ "L1 privileges"
if is_root; then
    ok "running as root"
elif id -nG 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
    ok "user is in group 'i2c'"
else
    bad "user $(id -un) is not in group 'i2c'"
    note "OpenRGB/i2c tools need root or group i2c: sudo usermod -aG i2c $(id -un), then log in again"
fi

head_ "L2 SMBus adapter"
BUS=""
if BUS=$(smbus_find_bus); then
    ok "DIMM SMBus at /dev/i2c-$BUS ($(cat "/sys/bus/i2c/devices/i2c-$BUS/name"))"
    SPD=()
    while IFS= read -r addr; do
        [[ -n $addr ]] && SPD+=("$addr")
    done < <(smbus_list_spd "$BUS")
    if (( ${#SPD[@]} > 0 )); then
        ok "DIMM SPD slots: ${SPD[*]}"
    else
        bad "no SPD EEPROM found on /dev/i2c-$BUS"
    fi
else
    bad "no DIMM SMBus adapter in /sys/bus/i2c/devices"
    if grep -qw 'acpi_enforce_resources=lax' /proc/cmdline; then
        note "kernel cmdline already has acpi_enforce_resources=lax"
        note "modules: $(lsmod | awk '$1 ~ /^(i2c_piix4|i2c_i801)$/ { printf "%s ", $1 }')"
    else
        note "acpi_enforce_resources=lax is not set"
        if command -v journalctl >/dev/null 2>&1 &&
           journalctl -k -b --no-pager 2>/dev/null | grep -qi 'conflicts with OpRegion'; then
            opregion=$(journalctl -k -b --no-pager 2>/dev/null |
                sed -n 's/.*conflicts with OpRegion[^(]*(\([^)]*\)).*/\1/p' | tail -n 1)
            note "firmware ACPI OpRegion ${opregion:-?} claims the SMBus I/O range"
            note "this is an OEM firmware quirk (HP/Dell/Lenovo); the driver cannot bind"
        fi
        note "fix: sudo bin/setup.sh   (installs the kernel parameter + udev fix)"
    fi
fi

head_ "L3 udev rules"
pkg_rules=/usr/lib/udev/rules.d/60-openrgb.rules
etc_rules=/etc/udev/rules.d/60-openrgb.rules
if [[ -e $pkg_rules ]]; then
    ok "packaged rules present: $pkg_rules"
else
    note "no packaged OpenRGB rules found (openrgb package not installed?)"
fi
if [[ -e $etc_rules ]]; then
    if [[ -s $etc_rules ]]; then
        bad "$etc_rules is a local override — verify it keeps the packaged rules"
    else
        bad "$etc_rules is empty and masks the packaged rules"
        note "fix: sudo bin/setup.sh   (moves the empty file aside)"
    fi
fi

head_ "L4 OpenRGB"
priv_ok=0
if is_root || id -nG 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
    priv_ok=1
fi
if or_available; then
    ok "openrgb: $(or_version)"
    if ids=$(or_dram_devices); then
        ok "OpenRGB reports DRAM device id(s): $(echo "$ids" | tr '\n' ' ')"
    elif (( priv_ok == 1 )); then
        bad "OpenRGB sees no DRAM device"
        note "expected when L2 is failing; otherwise the model may be unsupported"
    else
        note "OpenRGB sees no DRAM device, but it cannot reach /dev/i2c-* as this user"
        note "fix L1 first, or just run this script with sudo"
    fi
else
    note "openrgb not installed — only the Kingston fallback driver is available"
    note "sudo apt install openrgb"
fi

if [[ -n $BUS ]] && (( ${#SPD[@]} > 0 )) && is_root; then
    model_ok=" 0x10 0x11 0x12 0x15 "
    for addr in "${SPD[@]}"; do
        part=$(smbus_spd_part "$BUS" "$addr" 2>/dev/null)
        model=$(smbus_spd_byte "$BUS" "$addr" 579 2>/dev/null)   # SPD 0x243
        [[ -n $model ]] || continue
        printf '       DIMM %s: %-24s model 0x%02x\n' "$addr" "${part:-?}" "$model"
        if [[ $model_ok == *" $(printf '0x%02x' "$model") "* ]]; then
            continue
        fi
        note "model 0x$(printf '%02x' "$model") is rejected by packaged OpenRGB 0.9 builds"
        note "the Kingston fallback driver (--driver kingston) covers it"
    done
elif [[ -n $BUS ]] && ! is_root; then
    note "SPD model check skipped (needs root: sudo bin/diagnose.sh)"
fi

head_ "L5 persistence"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled openrgb-oem-fix.service >/dev/null 2>&1; then
        ok "openrgb-oem-fix.service is enabled at boot"
    else
        note "no boot service — the RGB comes back on the next power cycle"
        note "fix: sudo bin/install-service.sh"
    fi
    if [[ -x /usr/lib/systemd/system-sleep/openrgb-oem-fix ]]; then
        ok "resume hook installed"
    else
        note "no resume hook — the RGB may come back after suspend"
    fi
else
    note "systemd not available, skipping"
fi

log ""
if (( PROBLEMS > 0 )); then
    err "$PROBLEMS blocking problem(s) found — see the fix hints above"
    exit 1
fi
log "no blocking problems found"
exit 0
