#!/usr/bin/env bash
# Shared helpers for openrgb-oem-fix: logging, SMBus adapter discovery and
# SPD slot enumeration. Sourced by bin/* scripts, not run standalone.

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
err()  { printf 'error: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
require_root() { is_root || die "this step needs root, re-run with sudo"; }

require_cmds() {
    local c missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) || die "missing command(s): ${missing[*]} — install with: sudo apt install i2c-tools"
}

# Kernel SMBus adapters that carry DIMM SPD and RAM RGB controllers.
# Matched by name because /dev/i2c-N numbering changes between boots.
smbus_patterns() {
    cat <<'EOF'
SMBus PIIX4 adapter port 0 at *
SMBus I801 adapter at *
SMBus nForce2 adapter at *
SMBus AMD SMN adapter at *
EOF
}

# Print the /dev/i2c-N number of the primary DIMM SMBus adapter.
smbus_find_bus() {
    local d name pat
    while IFS= read -r pat; do
        for d in /sys/bus/i2c/devices/i2c-*; do
            [[ -r $d/name ]] || continue
            name=$(<"$d/name")
            # shellcheck disable=SC2053
            if [[ $name == $pat ]]; then
                printf '%s\n' "${d##*/i2c-}"
                return 0
            fi
        done
    done < <(smbus_patterns)
    return 1
}

# Print SPD EEPROM addresses (0x50..0x57) present on a bus, one per line.
smbus_list_spd() {
    local bus=$1 d name addr found=0
    for d in /sys/bus/i2c/devices/"$bus"-00[5-7]?; do
        [[ -r $d/name ]] || continue
        name=$(<"$d/name")
        case $name in
            spd5118|ee1004) ;;
            *) continue ;;
        esac
        addr=${d##*-00}
        printf '0x%s\n' "$addr"
        found=1
    done
    (( found == 1 )) && return 0
    # Nothing bound yet: probe the standard SPD range.
    command -v i2cdetect >/dev/null 2>&1 || return 1
    i2cdetect -y -r "$bus" 0x50 0x57 2>/dev/null |
        awk 'NR > 1 { for (i = 2; i <= NF; i++) if ($i != "--" && $i != "UU") print "0x"$i }'
}

# Read one SPD byte (root only, SPD EEPROMs are 0444 root:root).
smbus_spd_byte() {
    local bus=$1 addr=$2 offset=$3 d
    d=/sys/bus/i2c/devices/"$bus"-00${addr#0x}
    [[ -r $d/eeprom ]] || return 1
    dd if="$d/eeprom" bs=1 skip="$offset" count=1 status=none 2>/dev/null |
        od -An -tu1 | tr -d ' \n'
}

# Read the module part number from SPD: 0x209 for DDR5 (spd5118), 0x145 for
# DDR4 (ee1004). Returns the trimmed ASCII string.
smbus_spd_part() {
    local bus=$1 addr=$2 d name offset
    d=/sys/bus/i2c/devices/"$bus"-00${addr#0x}
    [[ -r $d/eeprom ]] || return 1
    name=""
    [[ -r $d/name ]] && name=$(<"$d/name")
    case $name in
        ee1004) offset=325 ;;   # 0x145, JEDEC DDR4 part number
        *)      offset=521 ;;   # 0x209, DDR5 SPD manufacturer area
    esac
    dd if="$d/eeprom" bs=1 skip="$offset" count=30 status=none 2>/dev/null |
        tr -d '\0' | sed 's/[[:space:]]*$//'
}
