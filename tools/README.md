# tools

Two small programs for watching an MX Brio (USB `046d:0944`): what the camera reports when video starts, when the
resolution changes, or when the camera is tilted to the desk. Both are **read-only**: nothing is ever written to the
camera.

```bash
cd tools && make
```

They are meant for finding out how the camera behaves and for filing a useful bug report. `brioctl` itself does not
need them.

## hidmon

Listens to the camera's HID interface. At start it prints the device, its usage pairs and a summary of the report
descriptor: for every report ID the usage page, the direction (input, output or feature), the size in bytes without
the ID byte, and the usages. Then it prints the time, the report ID and the hex bytes of every input report until
Ctrl-C.

```bash
./hidmon          # until Ctrl-C
./hidmon -t 30    # 30 seconds
```

The device's serial number is masked: it is printed as the same number of `X` characters, so the output is safe to
post in a bug report.

The device is opened without seizing it (`kIOHIDOptionsTypeNone`), so drivers and other programs keep seeing it.
Output and feature reports are never sent, and GET_REPORT is never requested. If the device cannot be opened (for
example `0xe00002e2`, which means the terminal has no Input Monitoring permission), the tool prints the error code and
what to do about it.

## uvcwatch

Polls `GET_CUR` of the chosen UVC controls every `MS` milliseconds (500 by default). It first prints all values, then
prints a line with the time only when something changes: the new value, the old one, and the numbers of the bytes that
changed.

```bash
./uvcwatch                         # default set, see below
./uvcwatch -i 100 stats:1 videopipe:8 ct:11
./uvcwatch -t 10 2c49d16a:3 6:10:16
```

A control is given as `UNIT:SEL[:LEN]`:

- `UNIT` is a unit id (as printed by `brioctl dump`), the start of an extension unit's GUID, or a name: `ct`, `pu`,
  `videopipe`, `peripheral`, `info`, `stats` (Video Statistics), `appsettings` (App Settings, the RightSight block).
- `SEL` is the selector, decimal or `0x..`.
- `LEN` is the size in bytes. It defaults to `GET_LEN` for extension units and to the size from the UVC specification
  for `ct` and `pu`.

With no arguments it watches `stats:1`, `peripheral:9`, `peripheral:15`, `peripheral:12`, `peripheral:18`,
`peripheral:24`, `videopipe:2`, `videopipe:4`, `videopipe:8`, `videopipe:9`, `videopipe:10`, `videopipe:11`,
`videopipe:12` and `appsettings:1`.

The requests are the same as in `brioctl` (`DeviceRequestTO` without opening the device), but only `GET_CUR` and
`GET_LEN` are sent. There is no `SET_CUR` in the code. A read error is printed as `error 0x...` (for example
`0xe000404f` means the camera does not support that control).

What the registers mean is described in [../docs/registers.md](../docs/registers.md).
