#!/usr/bin/env bash
# Install the OS-level fixes that make the DIMM SMBus usable by OpenRGB:
#
#   1. kernel parameter acpi_enforce_resources=lax, so i2c-piix4/i2c-i801 bind
#      even though the firmware declares the SMBus I/O range in an ACPI
#      OpRegion (HP/Dell/Lenovo OEM boards typically do this)
#   2. remove an empty /etc/udev/rules.d/60-openrgb.rules that masks the
#      packaged OpenRGB rules
#   3. load the SMBus and i2c-dev modules at boot
#
# Re-runnable. Needs root. Reboot afterwards.
# Revert: sudo bin/setup.sh --revert
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/smbus.sh
. "$SCRIPT_DIR/../lib/smbus.sh"

DROPIN=/etc/default/grub.d/99-openrgb-oem-fix.cfg
GRUB_DEFAULT=/etc/default/grub
UDEV_RULE=/etc/udev/rules.d/60-openrgb.rules
MODLOAD=/etc/modules-load.d/openrgb-oem-fix.conf
BACKUP_DIR=/var/backups/openrgb-oem-fix
PARAM=acpi_enforce_resources=lax

require_root

case "${1:-}" in
    --revert)
        rm -f "$DROPIN" "$MODLOAD"
        if [[ -e $BACKUP_DIR/60-openrgb.rules && ! -e $UDEV_RULE ]]; then
            cp -a "$BACKUP_DIR/60-openrgb.rules" "$UDEV_RULE"
            log "restored $UDEV_RULE"
        fi
        if [[ -e $BACKUP_DIR/grub.bak ]]; then
            cp -a "$BACKUP_DIR/grub.bak" "$GRUB_DEFAULT"
            log "restored $GRUB_DEFAULT"
        fi
        command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null
        command -v udevadm >/dev/null 2>&1 && { udevadm control --reload-rules; udevadm trigger; }
        log "reverted. Reboot to apply."
        exit 0
        ;;
    -h|--help)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *) die "unknown option: $1 (try --help)" ;;
esac

mkdir -p "$BACKUP_DIR"

# 1. kernel parameter ------------------------------------------------------
if grep -qw "$PARAM" /proc/cmdline; then
    ok "kernel parameter already active"
else
    if grep -qs 'grub\.d/\*\.cfg' "$GRUB_DEFAULT"; then
        printf '%s\n' \
            "# Managed by openrgb-oem-fix: let the SMBus driver bind despite" \
            "# the firmware ACPI OpRegion claiming the same I/O range." \
            "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $PARAM\"" \
            > "$DROPIN"
        log "wrote $DROPIN"
    else
        # Older distributions do not source /etc/default/grub.d/*.cfg
        if [[ ! -e $BACKUP_DIR/grub.bak ]]; then
            cp -a "$GRUB_DEFAULT" "$BACKUP_DIR/grub.bak"
            log "backed up $GRUB_DEFAULT -> $BACKUP_DIR/grub.bak"
        fi
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"$|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $PARAM\"|" \
            "$GRUB_DEFAULT"
        log "patched $GRUB_DEFAULT"
    fi
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1 || warn "update-grub failed"
        if grep -qs "$PARAM" /boot/grub/grub.cfg; then
            ok "$PARAM is in /boot/grub/grub.cfg (active after reboot)"
        else
            warn "$PARAM did not reach /boot/grub/grub.cfg — check it by hand"
        fi
    else
        warn "update-grub not found; regenerate the boot config by hand"
    fi
fi

# 2. udev rules masking ----------------------------------------------------
if [[ -e $UDEV_RULE && ! -s $UDEV_RULE ]]; then
    cp -a "$UDEV_RULE" "$BACKUP_DIR/60-openrgb.rules"
    rm -f "$UDEV_RULE"
    log "moved empty $UDEV_RULE aside (backup in $BACKUP_DIR)"
elif [[ -e $UDEV_RULE ]]; then
    warn "$UDEV_RULE exists and is not empty — left untouched, review it by hand"
else
    ok "no masking udev rule"
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null
    udevadm trigger 2>/dev/null
fi

# 3. modules at boot -------------------------------------------------------
printf '%s\n' i2c-piix4 i2c-i801 i2c-dev > "$MODLOAD"
log "wrote $MODLOAD"

log ""
log "done. Reboot, then: sudo bin/rgb-off.sh"
log "verify with: sudo bin/diagnose.sh"
