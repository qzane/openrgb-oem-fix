#!/usr/bin/env bash
# Offline tests: no hardware, no root. Fakes i2cset/i2cget and openrgb.
#
#   ./tests/run-tests.sh
set -uo pipefail

REPO=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {   # check DESCRIPTION EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then
        printf '[ ok ] %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '[fail] %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

# --- fake tools ------------------------------------------------------------
mkdir -p "$WORK/bin"

cat > "$WORK/bin/i2cget" <<'EOF'
#!/bin/sh
# i2cget -y BUS ADDR REG w — answer the "FURY" signature where it belongs
addr=$3
reg=$4
case "$addr" in
    0x61|0x63)
        case "$reg" in
            1) echo 0x4600 ;;   # 'F'
            2) echo 0x5500 ;;   # 'U'
            3) echo 0x5200 ;;   # 'R'
            4) echo 0x5900 ;;   # 'Y'
            *) echo 0x0000 ;;
        esac
        ;;
    *) echo 0xffff ;;
esac
EOF

cat > "$WORK/bin/i2cset" <<'EOF'
#!/bin/sh
# i2cset -y BUS ADDR REG VALUE b — record writes
printf '%s %s %s\n' "$3" "$4" "$5" >> "$I2C_LOG"
EOF

chmod +x "$WORK/bin/i2cget" "$WORK/bin/i2cset"

cat > "$WORK/bin/openrgb" <<'EOF'
#!/bin/sh
cat <<'LIST'
0: Kingston Fury DDR5 DRAM
  Type:           DRAM
  Description:    Kingston Fury Beast/Renegade DDR4/5 DRAM Device
  Location:       I2C: /dev/i2c-0, addresses [0x61]
  Modes: [Direct] Static Rainbow

1: Aura Addressable Header
  Type:           Motherboard
  Description:    ASUS Aura
  Modes: [Direct]
2: Some GPU
  Type:           GPU
  Description:    NVIDIA
LIST
EOF
chmod +x "$WORK/bin/openrgb"

export PATH="$WORK/bin:$PATH"

# --- openrgb driver: only DRAM devices are selected -----------------------
# shellcheck source=../drivers/openrgb.sh
. "$REPO/drivers/openrgb.sh"
OPENRGB_BIN="$WORK/bin/openrgb"
info() { :; }
warn() { :; }

check "openrgb list parsed to DRAM device ids" "0" "$(or_dram_devices | tr '\n' ' ' | sed 's/ $//')"
check "openrgb version trimmed" "" "$(or_version)"

# --- kingston driver: signature gate + off sequence ----------------------
# shellcheck source=../drivers/kingston-fury.sh
. "$REPO/drivers/kingston-fury.sh"
warn() { printf 'warn: %s\n' "$*" >&2; }

export I2C_LOG="$WORK/writes.log"
: > "$I2C_LOG"
KF_BUS=0 KF_DELAY_S=0
kf_off 0x51 0x53 >/dev/null 2>&1
check "kf_off exits 0 with two Fury controllers" "0" "$?"

check "static mode written (0x09=0x00)" "yes" "$(grep -qx '0x61 0x09 0x00' "$I2C_LOG" && echo yes || echo no)"
check "brightness written (0x20=0)" "yes" "$(grep -qx '0x61 0x20 0' "$I2C_LOG" && echo yes || echo no)"
check "colour written (0x31..0x33=0)" "yes" \
    "$(grep -qx '0x61 0x31 0' "$I2C_LOG" && grep -qx '0x61 0x32 0' "$I2C_LOG" &&
       grep -qx '0x61 0x33 0' "$I2C_LOG" && echo yes || echo no)"
check "dimm count written (0x27=2, not the number of hits)" "yes" \
    "$(grep -qx '0x61 0x27 2' "$I2C_LOG" && echo yes || echo no)"
check "second stick addressed too" "yes" \
    "$(grep -qx '0x63 0x09 0x00' "$I2C_LOG" && echo yes || echo no)"
check "no writes to unrelated addresses" "0" "$(grep -vc '^0x6[13] ' "$I2C_LOG" | tr -d ' ')"

: > "$I2C_LOG"
kf_off 0x51 >/dev/null 2>&1
check "single-stick run writes 0x27=1" "yes" \
    "$(grep -qx '0x61 0x27 1' "$I2C_LOG" && echo yes || echo no)"

# --- non-Fury hardware must be skipped -----------------------------------
# The Fury probe needs begin/end framing writes (as OpenRGB's detector does),
# so assert that no *configuration* register is ever written.
cat > "$WORK/bin/i2cget" <<'EOF'
#!/bin/sh
echo 0xffff
EOF
chmod +x "$WORK/bin/i2cget"
: > "$I2C_LOG"
kf_off 0x51 0x53 >/dev/null 2>&1
check "non-Fury controller: exit 1" "1" "$?"
check "non-Fury controller: no config register written" "0" \
    "$(grep -vc ' 0x08 ' "$I2C_LOG" | tr -d ' ')"

# --- DDR4 Fury: controller at 0x58+N --------------------------------------
cat > "$WORK/bin/i2cget" <<'EOF'
#!/bin/sh
addr=$3
reg=$4
if [ "$addr" = 0x59 ]; then
    case "$reg" in
        1) echo 0x4600 ;; 2) echo 0x5500 ;; 3) echo 0x5200 ;; 4) echo 0x5900 ;;
        *) echo 0x0000 ;;
    esac
else
    echo 0xffff
fi
EOF
chmod +x "$WORK/bin/i2cget"
cat > "$WORK/bin/i2cset" <<'EOF'
#!/bin/sh
printf '%s %s %s\n' "$3" "$4" "$5" >> "$I2C_LOG"
EOF
chmod +x "$WORK/bin/i2cset"
: > "$I2C_LOG"
kf_off 0x51 >/dev/null 2>&1
check "DDR4 controller found at 0x59" "yes" \
    "$(grep -qx '0x59 0x09 0x00' "$I2C_LOG" && echo yes || echo no)"

# --- failing writes must not be reported as success ----------------------
cat > "$WORK/bin/i2cset" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK/bin/i2cset"
KF_FAIL=0
kf_off 0x51 >/dev/null 2>&1
check "failing bus: exit 1" "1" "$?"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
