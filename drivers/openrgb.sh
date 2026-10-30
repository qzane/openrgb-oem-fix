#!/usr/bin/env bash
# Generic driver: drive every device OpenRGB reports as DRAM over the CLI.
# Works for any vendor OpenRGB supports (Corsair, Gigabyte, TeamGroup, ...).
# Sourced by bin/rgb-off.sh.

OPENRGB_BIN=${OPENRGB_BIN:-openrgb}
OR_DRY_RUN=${OR_DRY_RUN:-0}

or_available() { command -v "$OPENRGB_BIN" >/dev/null 2>&1; }

or_version() {
    "$OPENRGB_BIN" --version 2>/dev/null | awk -F'\t+' '/Version:/ { print $2; exit }' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Print OpenRGB device indices whose Type is DRAM.
or_dram_devices() {
    local list line cur="" cur_dram=0 ids=()
    list=$("$OPENRGB_BIN" --noautoconnect --list-devices 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ $line =~ ^([0-9]+):[[:space:]] ]]; then
            if [[ $cur_dram -eq 1 && -n $cur ]]; then
                ids+=("$cur")
            fi
            cur=${BASH_REMATCH[1]}
            cur_dram=0
        elif [[ $line =~ ^[[:space:]]*Type:[[:space:]]+DRAM[[:space:]]*$ ]]; then
            cur_dram=1
        fi
    done <<< "$list"
    if [[ $cur_dram -eq 1 && -n $cur ]]; then
        ids+=("$cur")
    fi
    (( ${#ids[@]} > 0 )) || return 1
    printf '%s\n' "${ids[@]}"
}

# Set every DRAM device to static black. Returns 0 if at least one worked.
or_apply_off() {
    local ids id ok=0
    ids=$(or_dram_devices) || return 1
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        if [[ $OR_DRY_RUN == 1 ]]; then
            info "would run: $OPENRGB_BIN --device $id --mode static --color 000000 --brightness 0"
            ok=$((ok + 1))
            continue
        fi
        if "$OPENRGB_BIN" --noautoconnect --device "$id" --mode static \
                --color 000000 --brightness 0 >/dev/null 2>&1 ||
           "$OPENRGB_BIN" --noautoconnect --device "$id" --mode static \
                --color 000000 >/dev/null 2>&1; then
            info "openrgb device $id: static black"
            ok=$((ok + 1))
        else
            warn "openrgb device $id: failed to set static black"
        fi
    done <<< "$ids"
    (( ok > 0 ))
}
