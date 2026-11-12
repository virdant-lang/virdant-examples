#!/usr/bin/env python3
"""Verify the 8XY6/8XYE/8XY7 test ROM run from a Virdant VCD trace.

usage: check_vcd_shift.py <trace.vcd> <flash-image>

Checks, for the all-ok path:
  1. loader byte-exact (same as check_vcd.py)
  2. instruction stream follows the ok path
  3. 8006 commit: V0 gets 0x78 (right shift with 0 in, VF = 0)
  4. 800E commit: V0 gets 0x1E (left shift with 0 in, VF = 0)
  5. 8027 commit: V0 gets 0x03 and VF gets 1 (8XY7 flag fix)
  6. one DXYN box drawn at (8..15, 8..10); any of the failure
     markers (32,16) / (36,20) / (40,24) are reported
"""
import sys

vcd_path, img_path = sys.argv[1], sys.argv[2]
img = open(img_path, 'rb').read()
BASE = 0x200
rom = img[BASE:4096]

FETCH, EXEC, WRITEVF, DRAW = '0000001', '0000010', '0000100', '0001000'

WANT = {
    'load_write', 'load_addr', 'load_data',
    'cpu_state', 'inst_hi', 'inst_lo',
    'execute_writes_v', 'v_write_data', 'flag_bit',
    'draw_x', 'draw_y',
}

id_to_name, ids = {}, set()
with open(vcd_path) as f:
    for line in f:
        if line.startswith('$var'):
            p = line.split()
            ids.add(p[3])
            if p[4] in WANT:
                id_to_name[p[3]] = p[4]
        elif line.startswith('$enddefinitions'):
            break
    idlist = sorted(ids, key=len, reverse=True)
    state, batches, t, pending = {}, [], 0, False
    for line in f:
        line = line.strip()
        if not line:
            continue
        if line[0] == '#':
            if pending:
                batches.append(dict(state))
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
            for ident in idlist:
                if line[1:] == ident:
                    n = id_to_name.get(ident)
                    if n:
                        state[n] = line[0]
                    break
    if pending:
        batches.append(dict(state))

oks, failures = [], []
def check(cond, msg):
    (oks if cond else failures).append(msg)
def bits(s): return s and set(s) <= set('01')
def u(s): return int(s, 2)

# ---- 1) loader ----
strobes, errs, prev = 0, 0, '0'
for st in batches:
    s = st.get('load_write')
    if s == '1' and prev != '1':
        a, d = st.get('load_addr'), st.get('load_data')
        if a and d and bits(a) and bits(d):
            strobes += 1
            a, d = u(a), u(d)
            if BASE <= a < 4096 and rom[a - BASE] != d:
                errs += 1
    if s:
        prev = s
check(strobes == 4096, f'loader: {strobes} strobes (want 4096)')
check(errs == 0, f'loader: {errs} data mismatches')

# ---- 2) instruction stream on the ok path ----
seen = []
for st in batches:
    if st.get('cpu_state') == EXEC and bits(st.get('inst_hi', '')) and bits(st.get('inst_lo', '')):
        pair = (u(st['inst_hi']), u(st['inst_lo']))
        if not seen or seen[-1] != pair:
            seen.append(pair)

okpath = [(0x00,0xE0),(0xA2,0x40),(0x60,0xF0),(0x80,0x06),(0x40,0x78),
          (0x12,0x12),(0x12,0x14),(0x60,0x0F),(0x80,0x0E),(0x40,0x1E),
          (0x12,0x22),(0x12,0x24),(0x60,0x05),(0x62,0x08),(0x80,0x27),
          (0x4F,0x01),(0x12,0x34),(0x12,0x36),(0x61,0x08),(0x62,0x08),
          (0xD1,0x23),(0x12,0x3C)]
n = min(len(seen), len(okpath))
mis = next(((i, w, g) for i, (w, g) in enumerate(zip(okpath, seen)) if w != g), None)
check(mis is None, f'execute: ok-path mismatch at #{mis}' if mis else
      f'execute: ok path followed ({n} instrs)')
if mis:
    failures.append(f'execute: first divergence: got ({seen[mis[0]][0]:02x},{seen[mis[0]][1]:02x}) '
                    f'want ({mis[1][0]:02x},{mis[1][1]:02x}) at step {mis[0]}')

# ---- 3..5) committed register values at the Execute cycles ----
commits = {}   # (hi,lo) -> latest (v_write_data, flag_bit) committed
for st in batches:
    if st.get('cpu_state') == EXEC and st.get('execute_writes_v') == '1' \
            and bits(st.get('inst_hi', '')) and bits(st.get('inst_lo', '')):
        pair = (u(st['inst_hi']), u(st['inst_lo']))
        commits[pair] = (st.get('v_write_data'), st.get('flag_bit'))

def flagval(fb):
    # flag_bit is a 1-bit vector or scalar
    if fb in ('0', '1'):
        return int(fb)
    return u(fb)

v, fb = commits.get((0x80, 0x06), (None, None))
check(v is not None and u(v) == 0x78, f'8XY6: V0 commit {u(v):#04x} (want 0x78)' if v else '8XY6: commit not observed')
v, fb = commits.get((0x80, 0x0E), (None, None))
check(v is not None and u(v) == 0x1E, f'8XYE: V0 commit {u(v):#04x} (want 0x1E)' if v else '8XYE: commit not observed')
v, fb = commits.get((0x80, 0x27), (None, None))
check(v is not None and u(v) == 0x03, f'8XY7: V0 commit {u(v):#04x} (want 0x03)' if v else '8XY7: commit not observed')
# flag_bit latches at the END of the 8027 Execute cycle; sample it in
# the next WriteVf cycle (where VF is committed from it).
fbvf = None
for i, st in enumerate(batches):
    if st.get('cpu_state') == EXEC and bits(st.get('inst_hi', '')) \
            and (u(st['inst_hi']), u(st['inst_lo'])) == (0x80, 0x27):
        for st2 in batches[i+1:i+8]:
            if st2.get('cpu_state') == WRITEVF:
                fbvf = st2.get('flag_bit')
                break
        break
check(fbvf is not None and flagval(fbvf) == 1,
      f'8XY7: VF latched {flagval(fbvf)} (want 1)' if fbvf is not None else '8XY7: WriteVf after 8027 not observed')

# ---- 6) boxes drawn ----
coords = []
for st in batches:
    if st.get('cpu_state') == DRAW:
        dx, dy = st.get('draw_x'), st.get('draw_y')
        if bits(dx) and bits(dy):
            e = (u(dx), u(dy))
            if not coords or coords[-1] != e:
                coords.append(e)
# split the coordinate walk into contiguous 24-px boxes
boxes = []
for i in range(0, len(coords) - 23, 24):
    boxes.append(coords[i:i+24])
def box_origin(c24):
    return c24[0]
origins = [box_origin(b) for b in boxes]
markers = {(32,16): '8XY6 shift-in-1', (36,20): '8XYE shift-in-1', (40,24): '8XY7 VF'}
bad_markers = [m for m in origins if m in markers]
check(origins == [(8,8)], f'draw: boxes drawn at {origins} (want [(8,8)])')
if bad_markers:
    for m in bad_markers:
        failures.append(f'draw: FAILURE MARKER {m} ({markers[m]}) was drawn!')

print(f'PASS {len(oks)}')
for m in oks: print('  ok :', m)
if failures:
    print(f'FAIL {len(failures)}')
    for m in failures: print('  FAIL:', m)
    sys.exit(1)
print('ALL CHECKS PASSED')
