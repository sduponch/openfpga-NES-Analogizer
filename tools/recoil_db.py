#!/usr/bin/env python3
"""Build recoil_db.bin, the recoil database of the NES Analogizer core (data slot "Recoil DB", id 25, read by
analogizer/recoil_db.sv and run by analogizer/mem_recoil.sv), from recoil_db.json.

The recoil then comes from the game's memory instead of the gun's trigger: rules on the CPU's writes into its internal
RAM say when the game really fires (a shot counter one less), so there is no kick shooting with no shot left, between
rounds, on a title screen or in the attract mode's demo; state variables (a demo flag, the game's phase, the weapon in
use) say when a rule holds and how long the pulse is.

recoil_db.json:
  {"games": [
    {"name": "Laser Invasion (USA)",
     "rom": "e2b5c8e4 00040010",                the ROM's key: its fingerprint and size in bytes (--key-of game.nes)
     "states": ["0069:b:02:00", "0080:b"],      up to 4: address:b[:mask:value] (hex); state i's condition "si" is
                                                (last value written & mask) == value; its value can pick a pulse
     "table": [40, 60, 80, 35, 25, 30, 80, 40], 8 pulse lengths (ms), for "pulse": "table:si" (index = value & 7)
     "rules": [                                 up to 9
       {"on": "dec", "at": "068C:b", "player": 1, "pulse": 40, "if": ["s0"], "ifnot": []},
       {"on": "trigger", "player": 1, "if": ["s0", "s1"]}
     ]}
  ]}
Events ("on"):
  dec      the value at "at" one less, from more than 0: a shot (not an empty gun, nor a reload)
  digit    a decimal digit (0..9) one less, 0 -> 9 included (the units of a count kept as digits)
  bcd      a BCD byte one less (30 -> 29)
  becomes  the value written is "value" (hex), and was not before
  trigger  no address: while its conditions hold, the gun's trigger makes the recoil (an unlimited weapon)
A player with a rule other than trigger gets its recoil from the memory only, except while a trigger rule holds.
Addresses: the CPU's internal RAM (0000-07FF), bytes. Player 1 is the JVS gun 1 (the Zapper).

The key: h = rotl32(h, 5) + word (mod 2^32; a xor would cancel the same change 32 words apart) over the file's 32-bit
big-endian words (the bridge's order, the iNES header included, the last word padded with zeros), from h = the first
word; and the file's size rounded up to 4 bytes. An iNES header has no checksum, so the whole file is the game's
identity.

Entry layout (16 pairs of big-endian words, 128 bytes; up to 32 entries in 4 KB; a key word 0 of 0 ends the list):
  pairs 0, 1 the key {fingerprint, size}, {0, 0}; pairs 2..5 states {flags, address}, {mask, value} (flags bit 1 used,
  bit 0 word); pair 6 the table; pairs 7..15 rules {flags, address}, {event[31:28], player[27], pulse from the
  table[26], its state[25:24], pulse ms[23:16], required true[15:12], required false[11:8], value[7:0]}.

Usage:
  recoil_db.py recoil_db.json -o recoil_db.bin
  recoil_db.py --key-of "Duck Hunt (World).nes"
"""
import argparse
import json
import struct
import sys

MAX_ENTRIES, SIZE, ENTRY = 32, 4096, 128
EVENTS = {"dec": 1, "digit": 2, "bcd": 3, "becomes": 4, "trigger": 5}


def rom_key(path):
    b = open(path, "rb").read()
    b += bytes(-len(b) % 4)
    words = struct.unpack(f">{len(b) // 4}I", b)
    h = words[0]
    for w in words[1:]:
        h = ((h << 5 | h >> 27) + w) & 0xFFFFFFFF
    return h, len(b)


def address(spec, what):
    f = spec.split(":")
    a = int(f[0], 16)
    if len(f) < 2 or f[1] != "b":
        sys.exit(f"{what}: \"address:b\" (the NES writes bytes), got {spec!r}")
    if not 0 <= a <= 0x7FF:
        sys.exit(f"{what}: not in the CPU's internal RAM (0000-07FF)")
    return 0x02 << 24 | a


def conds(names, what):
    m = 0
    for n in names or []:
        if len(n) != 2 or n[0] != "s" or n[1] not in "0123":
            sys.exit(f"{what}: a condition is s0..s3, got {n!r}")
        m |= 1 << int(n[1])
    return m


def entry(g):
    name = g.get("name", "?")
    fp, size = (int(x, 16) for x in g["rom"].split())
    if fp == 0:
        sys.exit(f"{name}: a fingerprint of 0 would end the list")
    out = struct.pack(">4I", fp, size, 0, 0)
    states = g.get("states", [])
    if len(states) > 4:
        sys.exit(f"{name}: 4 states at most")
    for k in range(4):
        if k >= len(states):
            out += bytes(8)
            continue
        f = states[k].split(":")
        mask, value = (int(f[2], 16), int(f[3], 16)) if len(f) >= 4 else (0, 0)
        if value & ~mask & 0xFFFF:
            sys.exit(f"{name} s{k}: the value has bits outside the mask")
        out += struct.pack(">IHH", address(":".join(f[:2]), f"{name} s{k}"), mask, value)
    table = g.get("table", [50] * 8)
    if len(table) != 8 or not all(1 <= p <= 255 for p in table):
        sys.exit(f"{name}: table is 8 pulse lengths of 1..255 ms")
    out += bytes(table)
    rules = g.get("rules", [])
    if len(rules) > 9:
        sys.exit(f"{name}: 9 rules at most")
    for k in range(9):
        if k >= len(rules):
            out += bytes(8)
            continue
        r, what = rules[k], f"{name} rule {k}"
        ev = EVENTS.get(r.get("on"))
        if ev is None:
            sys.exit(f"{what}: \"on\" is one of {', '.join(EVENTS)}")
        at = 0x02 << 24 if ev == 5 else address(r["at"], what)
        pl = r.get("player", 1)
        if pl not in (1, 2):
            sys.exit(f"{what}: player 1 or 2")
        pulse, tbl, tst = r.get("pulse", 50), 0, 0
        if isinstance(pulse, str):
            if not pulse.startswith("table:s") or pulse[7:] not in ("0", "1", "2", "3"):
                sys.exit(f"{what}: pulse is 1..255 (ms) or \"table:s0\"..\"table:s3\"")
            tbl, tst, pulse = 1, int(pulse[7:]), 0
        elif not 1 <= pulse <= 255:
            sys.exit(f"{what}: pulse is 1..255 ms")
        b = (ev << 28 | (pl - 1) << 27 | tbl << 26 | tst << 24 | pulse << 16 | conds(r.get("if"), what) << 12
             | conds(r.get("ifnot"), what) << 8 | int(r.get("value", "0"), 16) & 0xFF)
        out += struct.pack(">II", at, b)
    assert len(out) == ENTRY
    return out


def build(games):
    if len(games) > MAX_ENTRIES:
        sys.exit(f"{len(games)} games: {MAX_ENTRIES} at most")
    out = b"".join(entry(g) for g in games)
    return out + bytes(SIZE - len(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("json", nargs="?")
    ap.add_argument("-o", "--output")
    ap.add_argument("--key-of", metavar="ROM")
    a = ap.parse_args()
    if a.key_of:
        h, size = rom_key(a.key_of)
        print(f"{h:08x} {size:08x}")
        return
    if not a.json or not a.output:
        ap.error("recoil_db.json and -o recoil_db.bin")
    games = json.load(open(a.json))["games"]
    open(a.output, "wb").write(build(games))
    print(f"{a.output}: {len(games)} games")


if __name__ == "__main__":
    main()
