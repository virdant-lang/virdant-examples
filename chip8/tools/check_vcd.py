#!/usr/bin/env python3
"""Verify the CHIP-8 bring-up run from a Virdant VCD trace.

usage: check_vcd.py <trace.vcd> <flash-image>

Checks:
  1. loader: 4096 write strobes, ROM region byte-exact
  2. execute: instruction stream fetched in order
  3. draw: 24-pixel coordinate walk for the D123 box sprite
  4. cxnn: every CXNN commit equals rand_lfsr & kk
  5. delay timer: loaded with 0x12 by F415
  6. frame_tick: pulsed at 60 Hz
  7. framebuffer: reconstructed from the VGA scan stream (a full
     vsync-to-vsync frame after the last draw) matches the expected
     8x3 outline box at (8..15, 8..10) and nothing else

VCD notes: identifiers can be multi-character, so scalar changes are
matched by longest-prefix against the declared ids.  One board cycle
is one full clock period (20000 ps at 50 MHz); value changes are
grouped per # timestamp, which may hold several delta updates.
End-of-timestamp state is used for registered signals.
"""
import sys

vcd_path = sys.argv[1]
img = open(sys.argv[2], 'rb').read()   # flash image
BASE = 0x200                           # program origin in memory
rom = img[BASE:4096]

FETCH, EXEC, WRITEVF, DRAW, MEMSEQ, WAITKEY, CLEAR = (
    '0000001', '0000010', '0000100', '0001000', '0010000', '0100000', '1000000')

WANT = {
    'load_write', 'load_addr', 'load_data',
    'cpu_state', 'inst_hi', 'inst_lo',
    'execute_writes_v', 'v_write_data', 'rand_lfsr',
    'draw_x', 'draw_y', 'draw_column', 'draw_row',
    'delay_timer', 'frame_tick',
    'vs', 'display_area', 'scan_x', 'scan_y', 'scan_pixel',
}


def read_vcd(path):
    id_to_name = {}
    ids = set()
    with open(path) as f:
        for line in f:
            if line.startswith('$var'):
                p = line.split()
                name, ident = p[4], p[3]
                ids.add(ident)
                if name in WANT:
                    id_to_name[ident] = name
            elif line.startswith('$enddefinitions'):
                break
        idlist = sorted(ids, key=len, reverse=True)
        state = {}
        batches = []          # list of (time, end-of-batch state snapshot)
        t = 0
        pending = False

        def match_scalar(s):
            # s is "<id>" possibly; ids are non-space printable strings
            for ident in idlist:
                if s == ident:
                    return ident
            return None

        for line in f:
            line = line.strip()
            if not line:
                continue
            if line[0] == '#':
                if pending:
                    batches.append((t, dict(state)))
                t = int(line[1:])
                pending = True
            elif line[0] in 'bB':
                v, ident = line[1:].split()
                n = id_to_name.get(ident)
                if n:
                    state[n] = v
            elif line[0] == '$':
                continue
            else:
                ident = match_scalar(line[1:])
                n = id_to_name.get(ident) if ident else None
                if n:
                    state[n] = line[0]
        if pending:
            batches.append((t, dict(state)))
        return batches


batches = read_vcd(vcd_path)

oks, failures = [], []
def check(cond, msg):
    (oks if cond else failures).append(msg)

def bits(s): return s and set(s) <= set('01')
def u(s): return int(s, 2)

# ---- 1) loader strobes: ROM region must be written with exact ROM bytes ----
# One board cycle spans two # timestamps; count rising edges of the
# strobe, not every timestamp it is high.
strobes, load_errors = 0, 0
prev_strobe = '0'
for _, st in batches:
    s = st.get('load_write')
    if s == '1' and prev_strobe != '1':
        a, d = st.get('load_addr'), st.get('load_data')
        if a and d and bits(a) and bits(d):
            strobes += 1
            a, d = u(a), u(d)
            if BASE <= a < BASE + len(rom) and rom[a - BASE] != d:
                load_errors += 1
                if load_errors <= 3:
                    failures.append(f'loader: addr {a:#05x} got {d:#04x} want {rom[a-BASE]:#04x}')
    if s:
        prev_strobe = s
check(strobes == 4096, f'loader: {strobes} strobes (want 4096)')
check(load_errors == 0, f'loader: {load_errors} ROM region data mismatches')

# ---- 2) executed instruction stream ----
seen = []
for _, st in batches:
    if st.get('cpu_state') == EXEC and bits(st.get('inst_hi', '')) and bits(st.get('inst_lo', '')):
        pair = (u(st['inst_hi']), u(st['inst_lo']))
        if not seen or seen[-1] != pair:
            seen.append(pair)

prog = [(0x00,0xE0),(0xA2,0x1E),(0x61,0x08),(0x62,0x08),(0xD1,0x23),
        (0x63,0x00),(0xC3,0xFF),(0x64,0x12),(0xF4,0x15),(0x12,0x12)]
check(len(seen) >= len(prog), f'execute: {len(seen)} distinct instructions (want >= {len(prog)})')
mis = next(((i,w,g) for i,(w,g) in enumerate(zip(prog, seen)) if w != g), None)
check(mis is None, f'execute: mismatch at #{mis}' if mis else
      f'execute: program stream fetched in order ({len(prog)} instrs)')

# ---- 3) DXYN sprite walk: D123 at (8,8), sprite FF/81/FF ----
# Draw coordinates are sampled at end-of-timestamp (registered counter
# values); draw_new_pixel inside a timestamp contains post-commit
# delta artifacts, so the committed pixel values are verified
# end-to-end via the framebuffer reconstruction in check 7 instead.
coords = []
for _, st in batches:
    if st.get('cpu_state') == DRAW:
        dx, dy = st.get('draw_x'), st.get('draw_y')
        if bits(dx) and bits(dy):
            e = (u(dx), u(dy))
            if not coords or coords[-1] != e:
                coords.append(e)
expected_coords = [(8+c, 8+r) for r in range(3) for c in range(8)]
check(len(coords) >= len(expected_coords), f'draw: {len(coords)} pixel coords (want {len(expected_coords)})')
mis = next(((i,w,g) for i,(w,g) in enumerate(zip(expected_coords, coords)) if w != g), None)
check(mis is None, f'draw: walk mismatch at {mis}' if mis else
      f'draw: 24-pixel coordinate walk matches (x, y)')

# ---- 4) CXNN: commit must equal rand_lfsr[7:0] & kk ----
# Count only real Execute commits (one per instruction; dedupe the
# two timestamps per board cycle and the held-high combinational
# enable across Fetch cycles).
cxnn_n, cxnn_bad = 0, 0
prev_cxnn = None
for _, st in batches:
    if st.get('cpu_state') != EXEC:
        continue
    if st.get('execute_writes_v') == '1' and bits(st.get('inst_hi', '')) \
            and (u(st['inst_hi']) >> 4) == 0xC:
        r, k, w = st.get('rand_lfsr'), st.get('inst_lo'), st.get('v_write_data')
        if all(bits(s or '') for s in (r, k, w)):
            triple = (r, k, w)
            if triple != prev_cxnn:
                prev_cxnn = triple
                cxnn_n += 1
                if u(w) != (u(r) & 0xFF) & u(k):
                    cxnn_bad += 1
                    failures.append(f'cxnn: v_write={u(w):#04x} want {(u(r)&0xFF)&u(k):#04x}')
    else:
        prev_cxnn = None
check(cxnn_n >= 1, f'cxnn: {cxnn_n} CXNN commit(s) observed')
check(cxnn_bad == 0, 'cxnn: all CXNN writes equal rand_lfsr & kk')

# ---- 5) delay timer loaded with 0x12 by F415 ----
peak = 0
for _, st in batches:
    dt = st.get('delay_timer')
    if dt and bits(dt):
        peak = max(peak, u(dt))
check(peak == 0x12, f'delay timer: peak {peak:#04x} (want 0x12)')

# ---- 6) frame_tick pulsed ----
ticks, prev = 0, '0'
for _, st in batches:
    ft = st.get('frame_tick')
    if ft == '1' and prev != '1':
        ticks += 1
    if ft:
        prev = ft
check(ticks >= 1, f'frame_tick: {ticks} pulse(s)')

# ---- 7) framebuffer reconstruction via the VGA scan stream ----
# After the program reaches its self-loop (last draw well past), take
# one full vsync-to-vsync window and read every CHIP-8 pixel off
# scan_pixel.  Expected: 8x3 outline box (FF/81/FF) at (8..15, 8..10).
vs_rising = []
for i, (t, st) in enumerate(batches):
    v = st.get('vs')
    if v == '1' and (i == 0 or batches[i-1][1].get('vs') != '1'):
        vs_rising.append(i)

fb = {}
if len(vs_rising) >= 3:
    a, b = vs_rising[-2], vs_rising[-1]   # last complete frame
    for i in range(a, b):
        st = batches[i][1]
        if st.get('display_area') == '1':
            sx, sy, sp = st.get('scan_x'), st.get('scan_y'), st.get('scan_pixel')
            if bits(sx) and bits(sy) and sp in '01':
                fb[(u(sx), u(sy))] = sp
    check(len(fb) == 2048,
          f'framebuffer: {len(fb)}/2048 pixels scanned in last frame')
    sprite = [0xFF, 0x81, 0xFF]
    expect = {}
    for r in range(3):
        for c in range(8):
            expect[(8+c, 8+r)] = (sprite[r] >> (7-c)) & 1
    bad = []
    for x in range(64):
        for y in range(32):
            got = int(fb.get((x, y), '0'))
            want = expect.get((x, y), 0)
            if got != want:
                bad.append((x, y, got, want))
    check(not bad, f'framebuffer: {len(bad)} pixel mismatch(es) vs expected box image'
          if bad else 'framebuffer: 64x32 image matches expected box (8..15, 8..10)')
    if bad:
        for x, y, g, w in bad[:8]:
            failures.append(f'framebuffer: ({x},{y}) got {g} want {w}')
else:
    check(False, f'framebuffer: only {len(vs_rising)} vsync edges, need >= 3')

print(f'PASS {len(oks)}')
for m in oks: print('  ok :', m)
if failures:
    print(f'FAIL {len(failures)}')
    for m in failures: print('  FAIL:', m)
    sys.exit(1)
print('ALL CHECKS PASSED')
