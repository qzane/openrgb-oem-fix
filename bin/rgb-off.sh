#!/usr/bin/env bash
# Turn RAM RGB off (static black).
#
# Two drivers, tried in order:
#   openrgb   generic path, works for any DRAM device OpenRGB can control
#   kingston  raw SMBus fallback for Kingston Fury sticks OpenRGB rejects
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/smbus.sh
. "$SCRIPT_DIR/../lib/smbus.sh"
# shellcheck source=../drivers/openrgb.sh
. "$SCRIPT_DIR/../drivers/openrgb.sh"
# shellcheck source=../drivers/kingston-fury.sh
. "$SCRIPT_DIR/../drivers/kingston-fury.sh"

usage() {
    cat <<'EOF'
Usage: sudo rgb-off.sh [options]

Turn the RGB of every RAM module off (static black).

Options:
  --driver auto|openrgb|kingston   driver selection (default: auto,
                                   which runs openrgb first, then the
                                   Kingston fallback for anything left)
  --dry-run                        print the plan, touch no hardware
  -h, --help                       show this help

auto + kingston are idempotent: sticks that are already off stay off.
EOF
}

DRIVER=auto
DRY_RUN=0
while (( $# > 0 )); do
    case $1 in
        --dry-run) DRY_RUN=1; shift ;;
        --driver) DRIVER=${2:-}; shift 2 || die "--driver needs a value" ;;
        --driver=*) DRIVER=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

case $DRIVER in
    auto|openrgb|kingston) ;;
    *) die "--driver must be auto, openrgb or kingston" ;;
esac

(( DRY_RUN == 1 )) || require_root
require_cmds i2cset i2cget

BUS=$(smbus_find_bus) || die "no SMBus adapter found — run bin/diagnose.sh first"
SPD=()
while IFS= read -r addr; do
    [[ -n $addr ]] && SPD+=("$addr")
done < <(smbus_list_spd "$BUS")

log "SMBus: /dev/i2c-$BUS, DIMM slots: ${SPD[*]:-none}"

ok_openrgb=0
ok_kingston=0

if [[ $DRIVER == auto || $DRIVER == openrgb ]]; then
    if or_available; then
        OR_DRY_RUN=$DRY_RUN
        if or_apply_off; then
            ok_openrgb=1
        else
            warn "openrgb: no DRAM device handled"
        fi
    elif [[ $DRIVER == openrgb ]]; then
        die "openrgb driver requested but $OPENRGB_BIN is not installed"
    else
        warn "openrgb not installed, skipping the generic path"
    fi
fi

if [[ $DRIVER == auto || $DRIVER == kingston ]]; then
    if (( DRY_RUN == 1 )); then
        info "kingston dry-run: would probe ${#SPD[@]} slot(s) at 0x60+N (DDR5) / 0x58+N (DDR4)"
        ok_kingston=1
    elif KF_BUS=$BUS kf_off "${SPD[@]}"; then
        ok_kingston=1
    fi
fi

if (( DRY_RUN == 1 )); then
    log "dry-run finished, nothing was written"
    exit 0
fi

if (( ok_openrgb == 0 && ok_kingston == 0 )); then
    err "no RAM RGB controller could be switched off — run bin/diagnose.sh"
    exit 1
fi

log "done"
