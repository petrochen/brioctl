#!/usr/bin/env python3
"""Make the camera fixtures that are not a real camera, from tests/mxbrio-1.1.394.snap (run: make fixtures).

  generic-uvc.snap        1234:5678 "Generic UVC": the MX Brio's descriptor without any extension unit, and only the
                          standard registers
  generic-uvc-extra.snap  the same camera, declaring more standard controls (hue, gamma, iris, roll, privacy, hue auto)
                          and with the ranges of a less Logitech-like camera
  brio500-sim.snap        046d:0943 "Brio 500": the MX Brio's descriptor and registers, only the device line is changed
                          (it is what a Brio 500 should look like for brioctl, not a snapshot of one)

Standard library only. The outputs are committed; run this after the MX Brio snapshot changes.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "mxbrio-1.1.394.snap")

DESC_INTERFACE, DESC_CS_INTERFACE = 0x04, 0x24
VC_HEADER, VC_INPUT_TERMINAL, VC_OUTPUT_TERMINAL, VC_PROCESSING_UNIT, VC_EXTENSION_UNIT = 1, 2, 3, 5, 6
U_CT, U_PU = 1, 3  # unit ids in the MX Brio descriptor


def walk(desc):
    """Yield (offset, bytes) for every descriptor."""
    i = 0
    while i < len(desc):
        n = desc[i]
        if n < 2 or i + n > len(desc):
            raise SystemExit("bad descriptor at %d" % i)
        yield i, desc[i:i + n]
        i += n


def strip_extension_units(desc):
    """The descriptor without the extension units of the VideoControl interface, lengths and wiring fixed."""
    removed, in_vc, items = set(), False, []
    for _, d in walk(desc):
        if d[1] == DESC_INTERFACE:
            in_vc = d[5] == 0x0e and d[6] == 1
        elif in_vc and d[1] == DESC_CS_INTERFACE and d[2] == VC_EXTENSION_UNIT:
            removed.add(d[3])
            continue
        items.append([d[1], in_vc, bytearray(d)])
    pu = [d[3] for t, vc, d in items if vc and t == DESC_CS_INTERFACE and d[2] == VC_PROCESSING_UNIT][0]
    total = 0
    for t, vc, d in items:
        if vc and t == DESC_CS_INTERFACE:
            total += len(d)
            if d[2] == VC_OUTPUT_TERMINAL and d[7] in removed:
                d[7] = pu  # the picture now comes straight from the processing unit
    for t, vc, d in items:
        if vc and t == DESC_CS_INTERFACE and d[2] == VC_HEADER:
            d[5], d[6] = total & 0xff, total >> 8
    out = b"".join(bytes(d) for _, _, d in items)
    return out[:2] + bytes([len(out) & 0xff, len(out) >> 8]) + out[4:]


def declare(desc, ct_bits=(), pu_bits=()):
    """Set bits in the bmControls of the camera terminal and the processing unit."""
    out = bytearray(desc)
    in_vc = False
    for off, d in walk(desc):
        if d[1] == DESC_INTERFACE:
            in_vc = d[5] == 0x0e and d[6] == 1
        elif in_vc and d[1] == DESC_CS_INTERFACE and d[2] == VC_INPUT_TERMINAL and d[4] | d[5] << 8 == 0x0201:
            for b in ct_bits:
                assert b // 8 < d[14], "camera terminal bmControls too short"
                out[off + 15 + b // 8] |= 1 << b % 8
        elif in_vc and d[1] == DESC_CS_INTERFACE and d[2] == VC_PROCESSING_UNIT:
            for b in pu_bits:
                assert b // 8 < d[7], "processing unit bmControls too short"
                out[off + 8 + b // 8] |= 1 << b % 8
    return bytes(out)


def read_snapshot(path):
    snap = {"regs": [], "other": []}
    for line in open(path).read().splitlines():
        word = line.split(" ", 1)[0]
        if line.startswith("#") or word in ("device", "name", "serial"):
            continue
        if word == "descriptor":
            snap["descriptor"] = bytes.fromhex(line.split()[1])
        elif word == "reg":
            f = line.split()
            snap["regs"].append(((int(f[1]), int(f[2])), line))
        else:
            snap["other"].append(line)
    return snap


def write_snapshot(name, comment, vid, pid, camera, desc, regs, other):
    lines = ["# brioctl snapshot 1, " + comment, "device %04x %04x" % (vid, pid), "name " + camera,
             "serial 000000000000", "descriptor " + desc.hex()] + other + [line for _, line in regs]
    with open(os.path.join(HERE, name), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote tests/" + name)


def replace_regs(regs, new):
    """Put the register lines of new ({(unit, sel): line}) in regs, in place if the register is there."""
    new, out = dict(new), []
    for key, line in regs:
        out.append((key, new.pop(key, line)))
    return out + [(k, v) for k, v in new.items()]


def main():
    mx = read_snapshot(SRC)
    standard = [(k, l) for k, l in mx["regs"] if k[0] in (U_CT, U_PU)]
    generic = strip_extension_units(mx["descriptor"])
    note = "from tests/mxbrio-1.1.394.snap by tests/make-fixtures.py"

    write_snapshot("generic-uvc.snap", "a generic UVC camera, " + note, 0x1234, 0x5678, "Generic UVC", generic,
                   standard, [])

    # What the extra camera declares: iris (CT D7), roll (CT D13), privacy (CT D18); hue (PU D2), gamma (PU D5),
    # hue auto (PU D11).
    extra_desc = declare(generic, ct_bits=(7, 13, 18), pu_bits=(2, 5, 11))
    extra = replace_regs(standard, {
        (U_CT, 2): "reg 1 2 info 03 cur 02 res 03 def 02",                  # manual or auto (2), not aperture priority
        (U_CT, 9): "reg 1 9 info 03 cur 0001 min 0001 max 4001 res 0100 def 0001",       # iris
        (U_CT, 15): "reg 1 15 info 03 cur 0000 min 4cff max b400 res 0100 def 0000",     # roll, -180...180
        (U_CT, 17): "reg 1 17 info 01 cur 00 min 00 max 01 res 01 def 00",               # privacy: read-only
        (U_PU, 2): "reg 3 2 info 03 cur 0000 min c0ff max 4000 res 0100 def 0000",       # brightness -64...64
        (U_PU, 5): "reg 3 5 info 03 cur 01 min 00 max 03 res 01 def 02",                 # off, 50, 60, auto
        (U_PU, 6): "reg 3 6 info 03 cur 0000 min 18fc max e803 res 0100 def 0000",       # hue -1000...1000
        (U_PU, 9): "reg 3 9 info 03 cur 6400 min 6400 max 2c01 res 0100 def 6400",       # gamma 100...300
        (U_PU, 16): "reg 3 16 info 03 cur 00 def 00",                                    # hue auto
    })
    write_snapshot("generic-uvc-extra.snap", "a generic UVC camera with more controls, " + note, 0x1234, 0x5678,
                   "Generic UVC", extra_desc, extra, [])

    write_snapshot("brio500-sim.snap", "a Brio 500 as brioctl sees one: the MX Brio with another device line, " + note,
                   0x046d, 0x0943, "Brio 500", mx["descriptor"], mx["regs"], mx["other"])


if __name__ == "__main__":
    sys.exit(main())
