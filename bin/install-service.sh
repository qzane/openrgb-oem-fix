#!/usr/bin/env bash
# Install a boot service plus a suspend/resume hook that re-applies
# "RAM RGB off" after every power cycle and every sleep.
#
#   /usr/local/lib/openrgb-oem-fix/            copy of this repository
#   /etc/systemd/system/openrgb-oem-fix.service   runs rgb-off.sh at boot
#   /usr/lib/systemd/system-sleep/openrgb-oem-fix  runs rgb-off.sh pre/post sleep
#
# Re-runnable. Needs root.
# Uninstall: sudo bin/install-service.sh --uninstall
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/smbus.sh
. "$SCRIPT_DIR/../lib/smbus.sh"

LIB_DIR=/usr/local/lib/openrgb-oem-fix
UNIT=/etc/systemd/system/openrgb-oem-fix.service
HOOK=/usr/lib/systemd/system-sleep/openrgb-oem-fix

require_root

if [[ "${1:-}" == "--uninstall" ]]; then
    systemctl disable --now openrgb-oem-fix.service >/dev/null 2>&1
    rm -f "$UNIT" "$HOOK"
    rm -rf "$LIB_DIR"
    systemctl daemon-reload
    log "uninstalled"
    exit 0
fi

command -v systemctl >/dev/null 2>&1 || die "systemd is required"

mkdir -p "$LIB_DIR" "$(dirname -- "$HOOK")"
cp -a "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/drivers" "$LIB_DIR/"
chmod 0755 "$LIB_DIR"/bin/*.sh
log "installed scripts in $LIB_DIR"

cat > "$UNIT" <<EOF
[Unit]
Description=Turn RAM RGB off (openrgb-oem-fix)
Documentation=https://github.com/qzane/openrgb-oem-fix
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/modprobe i2c-piix4
ExecStartPre=-/usr/sbin/modprobe i2c-i801
ExecStartPre=/usr/sbin/modprobe i2c-dev
ExecStart=$LIB_DIR/bin/rgb-off.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$HOOK" <<EOF
#!/bin/sh
# openrgb-oem-fix: re-apply "RAM RGB off" around suspend/hibernate.
# \$1 is pre|post, so this fires both on the way in and after resume.
case "\$1" in
    pre|post)
        for i in 1 2 3; do
            "$LIB_DIR/bin/rgb-off.sh" >/dev/null 2>&1 && break
            sleep 0.5
        done
        ;;
esac
EOF
chmod 0755 "$HOOK"

systemctl daemon-reload
systemctl enable openrgb-oem-fix.service >/dev/null 2>&1
systemctl restart openrgb-oem-fix.service
log ""
log "installed $UNIT"
log "installed $HOOK"
systemctl --no-pager --lines=0 status openrgb-oem-fix.service || true
