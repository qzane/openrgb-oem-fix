#!/usr/bin/env bash
# Kingston Fury DDR4/DDR5 RGB driver: raw SMBus register writes.
#
# Register map, transaction framing ("FURY" signature, 0x08 = begin/end) and
# the static-mode parameter set follow OpenRGB's KingstonFuryDRAMController
# (GPL-2.0-or-later, by Adam Honse, Geofrey Mon, Milan Cermak). This driver
# exists because packaged OpenRGB builds (e.g. 0.9 from Ubuntu) reject some
# model codes, notably 0x13 used by HP OEM Fury Beast sticks.
#
# Controller address = RGB base + DIMM slot index, base 0x60 for DDR5 and
# 0x58 for DDR4. Every candidate address is verified to answer with the
# "FURY" signature before a single register is written.

KF_BASE_DDR5=0x60
KF_BASE_DDR4=0x58
KF_REG_APPLY=0x08
KF_REG_MODE=0x09
KF_REG_INDEX=0x0B
KF_REG_DIRECTION=0x0C
KF_REG_DELAY=0x0D
KF_REG_SPEED=0x0E
KF_REG_BRIGHTNESS=0x20
KF_REG_SLOTS=0x27
KF_REG_NUM_COLORS=0x30
KF_REG_COLOR_R=0x31
KF_REG_COLOR_G=0x32
KF_REG_COLOR_B=0x33
KF_BEGIN=0x53
KF_END=0x44
KF_MODE_STATIC=0x00
KF_DIRECTION_UP=0x01
KF_DELAY_S=0.02
KF_SIG_HEX=46555259

KF_BUS=${KF_BUS:-1}
KF_FAIL=0

kf_sleep() { sleep "$KF_DELAY_S"; }

# kf_write ADDR REG VALUE
kf_write() {
    local addr=$1 reg=$2 val=$3 attempt
    for attempt in 1 2 3; do
        if i2cset -y "$KF_BUS" "$addr" "$reg" "$val" b >/dev/null 2>&1; then
            kf_sleep
            return 0
        fi
        sleep 0.1
    done
    warn "kingston: write failed (bus $KF_BUS addr $addr reg $reg)"
    KF_FAIL=$((KF_FAIL + 1))
    return 1
}

# kf_read_byte ADDR REG -> prints the data byte
kf_read_byte() {
    local addr=$1 reg=$2 raw attempt
    for attempt in 1 2 3; do
        if raw=$(i2cget -y "$KF_BUS" "$addr" "$reg" w 2>/dev/null); then
            printf '%d\n' $(( (raw >> 8) & 0xFF ))
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# kf_is_fury ADDR — does the chip there answer with the "FURY" signature?
kf_is_fury() {
    local addr=$1 i byte sig="" rc=0
    kf_write "$addr" "$KF_REG_APPLY" "$KF_BEGIN" || return 1
    for i in 1 2 3 4; do
        if byte=$(kf_read_byte "$addr" "$i"); then
            sig+=$(printf '%02x' "$byte")
            kf_sleep
        else
            rc=1
            break
        fi
    done
    kf_write "$addr" "$KF_REG_APPLY" "$KF_END"
    (( rc == 0 )) || return 1
    [[ $sig == "$KF_SIG_HEX" ]]
}

# kf_off SPD_ADDR... — turn off RGB on every Fury controller on KF_BUS.
# Slot count written to the controller is the number of DIMMs, not the number
# of sticks that happened to answer.
kf_off() {
    local spd=("$@") base addr idx cand targets=() slot_count

    (( ${#spd[@]} > 0 )) || { warn "kingston: no SPD slots found on the SMBus"; return 1; }
    slot_count=${#spd[@]}

    for base in "$KF_BASE_DDR5" "$KF_BASE_DDR4"; do
        targets=()
        for addr in "${spd[@]}"; do
            idx=$(( addr - 0x50 ))
            cand=$(printf '0x%02x' $(( base + idx )))
            if kf_is_fury "$cand"; then
                targets+=("$cand")
            fi
        done
        if (( ${#targets[@]} > 0 )); then
            if [[ $base == "$KF_BASE_DDR5" ]]; then
                info "kingston: DDR5 controllers: ${targets[*]}"
            else
                info "kingston: DDR4 controllers: ${targets[*]}"
            fi
            break
        fi
    done
    (( ${#targets[@]} > 0 )) || { warn "kingston: no Fury RGB controller answered"; return 1; }

    for addr in "${targets[@]}"; do
        kf_write "$addr" "$KF_REG_APPLY" "$KF_BEGIN"
    done
    for addr in "${targets[@]}"; do
        kf_write "$addr" "$KF_REG_INDEX" "$KF_MODE_STATIC"
        kf_write "$addr" "$KF_REG_MODE" "$KF_MODE_STATIC"
        kf_write "$addr" "$KF_REG_DIRECTION" "$KF_DIRECTION_UP"
        kf_write "$addr" "$KF_REG_DELAY" 0
        kf_write "$addr" "$KF_REG_SPEED" 0
        kf_write "$addr" "$KF_REG_NUM_COLORS" 1
        kf_write "$addr" "$KF_REG_COLOR_R" 0
        kf_write "$addr" "$KF_REG_COLOR_G" 0
        kf_write "$addr" "$KF_REG_COLOR_B" 0
        kf_write "$addr" "$KF_REG_BRIGHTNESS" 0
        kf_write "$addr" "$KF_REG_SLOTS" "$slot_count"
    done
    for addr in "${targets[@]}"; do
        kf_write "$addr" "$KF_REG_APPLY" "$KF_END"
    done

    if (( KF_FAIL > 0 )); then
        warn "kingston: $KF_FAIL register write(s) failed"
        return 1
    fi
    info "kingston: static black applied"
    return 0
}
