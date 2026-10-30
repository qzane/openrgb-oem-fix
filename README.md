# openrgb-oem-fix

Turn RAM RGB off on Linux desktops where OpenRGB sees nothing at all.

Built for OEM consumer machines (HP / Dell / Lenovo), where the firmware
declares the DIMM SMBus in an ACPI OpRegion, so the kernel SMBus driver never
binds and OpenRGB has no RAM device to talk to. Includes a raw SMBus fallback
for Kingston Fury sticks that packaged OpenRGB builds reject.

## What actually gets in the way

There are four independent layers. Most guides only mention the last one, which
is why they do not work on OEM machines.

| # | Layer | Who is to blame | Fix in this repo |
|---|-------|-----------------|------------------|
| 1 | Firmware ACPI OpRegion claims the SMBus I/O range, `i2c-piix4` / `i2c-i801` refuses to bind, no `/dev/i2c-*` for the DIMMs, OpenRGB lists zero devices | OEM firmware (HP/Dell/Lenovo) | `bin/setup.sh` — adds `acpi_enforce_resources=lax` |
| 2 | An empty `/etc/udev/rules.d/60-openrgb.rules` masks the packaged rules, so non-root access is refused | left-over local file | `bin/setup.sh` |
| 3 | Packaged OpenRGB (0.9) only accepts Kingston Fury model codes `0x10 0x11 0x12 0x15`; sticks reporting `0x13` are dropped, usually just one of the two modules | OpenRGB + vendor | `drivers/kingston-fury.sh` — raw register writes |
| 4 | The RGB comes back after a full power cycle or a suspend | RGB controller firmware | `bin/install-service.sh` — boot service + sleep hook |

Layer 1 and 2 are vendor independent. Layer 3 is Kingston specific. Layer 4 is
unavoidable: nothing on the DIMM remembers its state across power loss.

## Requirements

- Linux with an SMBus host controller the kernel can drive (`i2c-piix4` on AMD,
  `i2c-i801` on Intel)
- `i2c-tools` — `sudo apt install i2c-tools`
- `openrgb` for the generic path (optional, the Kingston fallback does not need it)
- root for everything that touches hardware

## Quick start

```sh
# 1. find out which layer is blocking you (read-only)
sudo ./bin/diagnose.sh

# 2. install the OS-level fixes, then reboot
sudo ./bin/setup.sh
sudo reboot

# 3. try it
sudo ./bin/rgb-off.sh --dry-run     # print the plan first
sudo ./bin/rgb-off.sh               # actually write

# 4. keep it off across boots and suspends
sudo ./bin/install-service.sh
```

## Drivers

`bin/rgb-off.sh` runs two drivers, in order:

- **openrgb** (generic) — asks `openrgb --list-devices` for every DRAM device
  and sets it to `static`, colour `000000`, brightness `0`. Works for any vendor
  OpenRGB supports: Corsair, Gigabyte, TeamGroup, Fury, and so on.
- **kingston** (fallback) — writes the Fury register protocol over SMBus
  directly, for sticks the installed OpenRGB does not recognise.

Force one of them with `--driver openrgb` or `--driver kingston`.

## How the Kingston fallback works

- The controller sits on the same SMBus as the SPD EEPROMs: `SPD = 0x50 + slot`,
  `RGB = 0x60 + slot` for DDR5 (`0x58 + slot` for DDR4).
- Every candidate address is verified first: begin a transaction by writing
  `0x53` to register `0x08`, read registers `1..4`, expect the ASCII string
  `FURY`, then write `0x44` to `0x08` to end it. Anything that does not answer
  is skipped — this is what keeps the fallback safe on non-Kingston hardware.
- The off state is static mode with one colour, black, brightness `0`:
  `0x09=0x00` (static), `0x31..0x33=0` (black), `0x20=0` (brightness),
  `0x27=slot count`.
- Write failures are counted and make the script exit non-zero, so a half-applied
  state is never reported as success.

Register semantics come from OpenRGB's `KingstonFuryDRAMController`
(GPL-2.0-or-later). This repository is an independent re-implementation with a
different licensing scope, see *Credits*.

## Caveats

- `acpi_enforce_resources=lax` lets Linux and the firmware share the SMBus I/O
  range. On HP boards the ACPI OpRegion (`\_SB.SBSN`) exists so firmware can read
  FRU/serial data. Sharing it is the documented OpenRGB workaround, but if
  `dmidecode`, fan readings or sensor values ever misbehave, this is the reason.
  `sudo ./bin/setup.sh --revert` undoes it.
- Writing registers on a RAM module is not risk-free in principle; SPD data
  (`0x50+N`) is never touched. Detection does send the Fury transaction framing
  bytes (`0x53`/`0x44` to register `0x08`) to candidate addresses, exactly like
  OpenRGB's own detector, but no configuration register is written unless the
  `FURY` signature matched. Same risk profile as OpenRGB itself.
- `bin/install-service.sh` needs `systemd`. The sleep hook calls the script on
  both `pre` and `post` because some firmware re-initialises the lighting on the
  way into sleep, others on the way out.
- Only tested with the hardware listed below. The layered design is meant to be
  ported: add a file under `drivers/` for another vendor protocol and call it
  from `bin/rgb-off.sh`.

## Tested on

| Item | Value |
|------|-------|
| Machine | HP OMEN MAX 45L Gaming Desktop GT23-0xxx |
| Board / BIOS | HP 8E55, F.10 |
| OS | Ubuntu 26.04, kernel 7.0.0-42-generic |
| CPU platform | AMD (FCH SMBus, `i2c-piix4`) |
| RAM | Kingston Fury Beast KF560C36-32 (retail, model `0x10`) + HP OEM HP60U40D8HA-32FRE (model `0x13`) |
| OpenRGB | 0.9+git20251009 (Ubuntu package) |

## Uninstall

```sh
sudo ./bin/install-service.sh --uninstall   # service + sleep hook + copied scripts
sudo ./bin/setup.sh --revert                # kernel parameter + udev rule
sudo reboot
```

## Tests

```sh
./tests/run-tests.sh
```

No hardware, no root: `i2cset`/`i2cget`/`openrgb` are faked, so the suite checks
the register sequence (static mode, black, brightness 0, DIMM count), the DDR4
`0x58+N` fallback, the signature gate on non-Kingston chips and that failing
writes are reported as failures.

## Layout

```
bin/diagnose.sh         layered read-only diagnosis
bin/setup.sh            kernel parameter, udev rule, modules (with --revert)
bin/rgb-off.sh          apply "off" via the drivers (with --dry-run)
bin/install-service.sh  boot service + sleep hook (with --uninstall)
lib/smbus.sh            adapter discovery, SPD enumeration, logging
drivers/openrgb.sh      generic driver via the OpenRGB CLI
drivers/kingston-fury.sh raw SMBus driver for Fury DDR4/DDR5
tests/run-tests.sh      offline tests with fake i2c/openrgb tools
```

## Credits

- [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) — the Kingston Fury
  protocol and the `acpi_enforce_resources=lax` approach originate there. The
  driver in this repository is written from its documented register map, not
  copied: OpenRGB is GPL-2.0-or-later, this repository is MIT. If you need a
  single license for both, use OpenRGB's.
- Everyone who filed "OpenRGB shows no RAM on my HP/Dell/Lenovo" reports.

## License

MIT, see [LICENSE](LICENSE).
