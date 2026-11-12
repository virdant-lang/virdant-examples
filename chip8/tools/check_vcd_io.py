#!/usr/bin/env python3
"""Verify the FX0A and beep test runs from Virdant VCD traces.

usage: check_vcd_io.py fx0a <trace.vcd> <flash-image>
       check_vcd_io.py mem  <trace.vcd> <flash-image>
       check_vcd_io.py beep <trace.vcd> <flash-image>

The trace is parsed in a single streaming pass: one end-of-timestamp
state snapshot at a time, never a list of snapshots (a 1.7M-cycle trace
has 3.4M timestamps; materializing a dict per timestamp needs several
GB).  Scalar changes are `<value><id>` with the id running to the end
of the line, so they are resolved with an exact dict lookup.

VCD timing: `$timescale 1ps`; the 50 MHz board clock has a 20000 ps
period, rising edges at 10000 + 20000*k, so a board cycle spans two
`#` timestamps and cycle = t // 20000.
"""
import sys

mode, vcd_path, img_path = sys.argv[1], sys.argv[2], sys.argv[3]
img = open(img_path, 'rb').read()
BASE = 0x200
rom = img[BASE:4096]
PS_PER_CYCLE = 20000

FETCH, EXEC, WRITEVF, DRAW, MEMSEQ, WAITKEY, CLEAR = (
    '0000001', '0000010', '0000100', '0001000', '0010000', '0100000', '1000000')

WANT = {
    'load_write', 'load_addr', 'load_data',
    'cpu_state', 'inst_hi', 'inst_lo',
    'draw_x', 'draw_y', 'clear_counter', 'key', 'reg_x', 'waitkey_key',
    'sound_timer', 'beep', 'vs', 'display_area', 'scan_x', 'scan_y', 'scan_pixel',
}


def snapshots(path):
    """Yield (time_ps, state) with the state at the end of each timestamp.

    `state` is one live dict updated in place; consumers copy what
    they keep.
    """
    id_to_name = {}
    with open(path) as f:
        for line in f:
            if line.startswith('$var'):
                p = line.split()
                if p[4] in WANT:
                    id_to_name[p[3]] = p[4]
            elif line.startswith('$enddefinitions'):
                break
        state, t, pending = {}, 0, False
        for line in f:
            line = line.strip()
            if not line:
                continue
            c = line[0]
            if c == '#':
                if pending:
                    yield t, state
                t = int(line[1:])
                pending = True
            elif c in 'bB':
                v, ident = line[1:].split()
                n = id_to_name.get(ident)
                if n:
                    state[n] = v
            elif c == '$':
                continue
            else:
                n = id_to_name.get(line[1:])
                if n:
                    state[n] = c
        if pending:
            yield t, state


oks, failures = [], []
def check(cond, msg):
    (oks if cond else failures).append(msg)
def bits(s): return bool(s) and set(s) <= set('01')
def u(s): return int(s, 2)
def cyc(t): return t // PS_PER_CYCLE

# loader byte-exact (one strobe = rising edge of load_write)
strobes, load_errors, prev_load_write = 0, 0, '0'
def check_loader(st):
    global strobes, load_errors, prev_load_write
    s = st.get('load_write')
    if s == '1' and prev_load_write != '1':
        a, d = st.get('load_addr'), st.get('load_data')
        if bits(a) and bits(d):
            strobes += 1
            a, d = u(a), u(d)
            if BASE <= a < 4096 and rom[a - BASE] != d:
                load_errors += 1
    if s:
        prev_load_write = s

class TraceSummary:
    """Everything the fx0a and mem checks need, from one streaming pass."""

    def __init__(self, path):
        self.waitkey_samples = 0
        self.waitkey_first = self.waitkey_last = None    # cycles
        self.draw_first = self.draw_last = None
        self.exec_stream = []        # distinct consecutive (hi, lo)
        self.coords = []             # distinct consecutive (x, y) while drawing
        self.key_events = []         # (cycle, key value, cpu_state)
        self.commits = []            # (cycle, reg_x, waitkey_key) at WaitKey→Fetch
        self.clear_runs = []         # highest clear_counter seen per Clear run
        self.memseq_runs = 0         # MemSeq entries (FX33/FX55/FX65)
        self.vs_rising = 0
        self.last_frame = None       # last complete vsync-to-vsync frame
        self.last_frame_start = None # cycle of its opening vsync edge
        self.last_t = 0
        prev_key, prev_vs, prev_cs = None, None, None
        frame = frame_start = None
        for t, st in snapshots(path):
            self.last_t = t
            check_loader(st)
            cs = st.get('cpu_state')
            if cs == WAITKEY:
                self.waitkey_samples += 1
                if self.waitkey_first is None:
                    self.waitkey_first = cyc(t)
                self.waitkey_last = cyc(t)
            elif cs == EXEC:
                hi, lo = st.get('inst_hi'), st.get('inst_lo')
                if bits(hi) and bits(lo):
                    pair = (u(hi), u(lo))
                    if not self.exec_stream or self.exec_stream[-1] != pair:
                        self.exec_stream.append(pair)
            elif cs == DRAW:
                if self.draw_first is None:
                    self.draw_first = cyc(t)
                self.draw_last = cyc(t)
                dx, dy = st.get('draw_x'), st.get('draw_y')
                if bits(dx) and bits(dy):
                    e = (u(dx), u(dy))
                    if not self.coords or self.coords[-1] != e:
                        self.coords.append(e)
            elif cs == CLEAR:
                if prev_cs != CLEAR:
                    self.clear_runs.append(0)
                c = st.get('clear_counter')
                if bits(c):
                    self.clear_runs[-1] = max(self.clear_runs[-1], u(c))
            elif cs == MEMSEQ and prev_cs != MEMSEQ:
                self.memseq_runs += 1
            # FX0A commit: the regfile write site fires at the
            # WaitKey→Fetch exit edge with pre-edge values; inst_hi and
            # waitkey_key are both stable across that edge, so sampling
            # them (post-edge, end of timestamp) yields the committed
            # register index and key.  Must run before prev_cs is
            # updated below.
            if cs == FETCH and prev_cs == WAITKEY:
                rx, kd = st.get('reg_x'), st.get('waitkey_key')
                self.commits.append((cyc(t), u(rx) if bits(rx) else None,
                                     u(kd) if bits(kd) else None))
            if cs:
                prev_cs = cs
            k = st.get('key')
            if bits(k) and k != prev_key:
                self.key_events.append((cyc(t), u(k), cs))
                prev_key = k
            v = st.get('vs')
            if v == '1' and prev_vs != '1':
                self.vs_rising += 1
                if frame is not None:
                    self.last_frame, self.last_frame_start = frame, frame_start
                frame, frame_start = {}, cyc(t)
            prev_vs = v
            if frame is not None and st.get('display_area') == '1':
                sx, sy, sp = st.get('scan_x'), st.get('scan_y'), st.get('scan_pixel')
                if bits(sx) and bits(sy) and sp in ('0', '1'):
                    frame[(u(sx), u(sy))] = sp

    def stream_hex(self):
        return [f'{h:02X}{l:02X}' for h, l in self.exec_stream]


def check_framebuffer(tag, trace, lit):
    """The last complete frame shows exactly the pixels in `lit`, and it
    was scanned entirely after the last Draw cycle."""
    frame = trace.last_frame
    if frame is None:
        check(False, f'{tag}: only {trace.vs_rising} vsync edges')
        return
    check(len(frame) == 2048, f'{tag}: framebuffer {len(frame)}/2048 scanned')
    bad = [(x, y, int(frame.get((x, y), '0')), int((x, y) in lit))
           for y in range(32) for x in range(64)
           if int(frame.get((x, y), '0')) != int((x, y) in lit)]
    check(not bad, f'{tag}: {len(bad)} framebuffer mismatches' if bad else
          f'{tag}: last complete frame matches ({len(lit)} lit pixels)')
    for x, y, g, w in bad[:6]:
        failures.append(f'{tag}: fb ({x},{y}) got {g} want {w}')
    check(trace.draw_last is not None and trace.draw_last < trace.last_frame_start,
          f'{tag}: reconstructed frame starts at cycle {trace.last_frame_start}, '
          f'after the last Draw cycle {trace.draw_last}')


if mode == 'fx0a':
    trace = TraceSummary(vcd_path)
    exec_stream, coords = trace.exec_stream, trace.coords
    waitkey_samples, waitkey_first, waitkey_last = (
        trace.waitkey_samples, trace.waitkey_first, trace.waitkey_last)
    key_events, commits, draw_first = trace.key_events, trace.commits, trace.draw_first

    check(strobes == 4096, f'loader: {strobes} strobes (want 4096)')
    check(load_errors == 0, f'loader: {load_errors} data mismatches')

    prog = [(0x00, 0xE0), (0xF2, 0x0A), (0xA2, 0x1E), (0x61, 0x08),
            (0xD1, 0x23), (0x12, 0x0A)]
    check(exec_stream[:len(prog)] == prog,
          f'fx0a: program stream fetched in order ({len(prog)} instrs)'
          if exec_stream[:len(prog)] == prog else
          f'fx0a: program stream {[f"{h:02X}{l:02X}" for h, l in exec_stream[:8]]}')

    # FX0A must stall in WaitKey (two snapshots per board cycle)
    check(waitkey_samples >= 100,
          f'fx0a: WaitKey held for {waitkey_samples} samples, cycles '
          f'{waitkey_first}..{waitkey_last} (want >= 100 samples)')

    # stimulus self-check (tools/fx0a_keys.py): exactly one key-5 press
    # and one release, both while the core is waiting, and the draw
    # only starts after the wait
    presses = [e for e in key_events if e[1] != 0 and e[2] == WAITKEY]
    releases = [e for e in key_events if e[1] == 0 and e[2] == WAITKEY]
    check(len(presses) == 1 and presses[0][1] == 1 << 5 and len(releases) == 1,
          f'fx0a: key 5 pressed at cycle {presses[0][0]} and released at cycle '
          f'{releases[0][0]}, both during WaitKey'
          if len(presses) == 1 and len(releases) == 1 else
          f'fx0a: stimulus is not one key-5 press+release inside WaitKey; '
          f'key events (cycle, key, cpu_state) {key_events}')
    check(len(commits) == 1 and commits[0][1] == 2 and commits[0][2] == 5,
          f'fx0a: V{commits[0][1]} := key {commits[0][2]} committed once at the '
          f'WaitKey→Fetch edge (cycle {commits[0][0]})'
          if commits else 'fx0a: no FX0A commit (no WaitKey→Fetch edge observed)')
    check(draw_first is not None and waitkey_last is not None and draw_first > waitkey_last,
          f'fx0a: draw starts at cycle {draw_first}, after WaitKey exit')

    # draw walk after release: one 8x3 box at (8, V2 = key 5)
    expect = [(8+c, 5+r) for r in range(3) for c in range(8)]
    mis = next(((i, w, g) for i, (w, g) in enumerate(zip(expect, coords)) if w != g), None)
    check(len(coords) == len(expect) and mis is None,
          f'fx0a: box walk mismatch at {mis}' if mis else
          f'fx0a: 24-pixel box walk at (8..15, 5..7) after FX0A released'
          if len(coords) == len(expect) else
          f'fx0a: box walk has {len(coords)} pixels (want {len(expect)})')

    # framebuffer reconstruction over the last complete frame
    sprite = [0xFF, 0x81, 0xFF]
    check_framebuffer('fx0a', trace, {(8 + c, 5 + r) for r in range(3) for c in range(8)
                                      if (sprite[r] >> (7 - c)) & 1})
    print(f'trace ends at cycle {cyc(trace.last_t)} ({trace.last_t / 1e9:.3f} ms); '
          f'{trace.vs_rising} vsync rising edges')
    print(f'key events (cycle, key, cpu_state): {key_events}')
elif mode == 'mem':
    # roms/test_mem.flash (tools/make_test_mem.py): 00E0 Clear edge,
    # FX33, FX55/FX65 self-checks, then a success-path 2NNN/00EE
    # subroutine roundtrip (oksub at 0x264 draws the ok marker, sets
    # V8 = 0x88 and returns; the caller checks V8).  Every `3XNN`
    # check skips its `2270` (call fail) on success, so the passing
    # run executes exactly this stream and calls the fail subroutine
    # never — a broken call_stack push or pop would derail the stream
    # after the 2264 call.
    trace = TraceSummary(vcd_path)
    check(strobes == 4096, f'loader: {strobes} strobes (want 4096)')
    check(load_errors == 0, f'loader: {load_errors} data mismatches')
    prog = ['00E0', 'A278', '6000', 'D001', '6138', '621F', 'D121', '00E0',
            '6A00', '6B14',
            '65FE', 'A300', 'F533', 'F265', '3002', '3105', '3204',
            '6011', '6122', '6233', '6344', 'A310', 'F355',
            '6000', '6100', '6200', '6300', '6455', 'F365',
            '3011', '3122', '3233', '3344', '3455',
            'A314', 'F065', '3000',
            '2264', 'A278', '601C', '610E', 'D011', '6888', '00EE',
            '3888', '1262']
    got = trace.stream_hex()
    check(got == prog, f'mem: program stream fetched in order ({len(prog)} instrs, '
          f'no check failed)' if got == prog else
          f'mem: program stream differs (a 3XNN check failed?): {got}')
    calls = [i for i in got if i == '2270']
    check(not calls, f'mem: fail subroutine never called' if not calls else
          f'mem: fail subroutine called {len(calls)} times')
    check(trace.memseq_runs == 5, f'mem: {trace.memseq_runs} MemSeq runs '
          f'(want 5: F533 F265 F355 F365 F065)')
    check(trace.clear_runs == [2047, 2047],
          f'mem: two 00E0 Clear walks reached clear_counter 2047 {trace.clear_runs}')
    expect = ([(c, 0) for c in range(8)] + [(56 + c, 31) for c in range(8)]
              + [(28 + c, 14) for c in range(8)])
    check(trace.coords == expect,
          'mem: draw walks (0..7,0), (56..63,31) before the Clear, ok marker '
          '(28..35,14) after' if trace.coords == expect else
          f'mem: draw walk {trace.coords}')
    # Clear edge: pixel 0 and pixel 2047 were lit before the second
    # 00E0; only the ok marker may remain
    check_framebuffer('mem', trace, {(28 + c, 14) for c in range(8)})
    print(f'trace ends at cycle {cyc(trace.last_t)} ({trace.last_t / 1e9:.3f} ms); '
          f'{trace.vs_rising} vsync rising edges')
else:
    # beep: sound_timer loads 1 and beep follows it exactly
    peak, bad_beep, prev_timer, last_timer = 0, 0, None, None
    for t, st in snapshots(vcd_path):
        check_loader(st)
        dt, bp = st.get('sound_timer'), st.get('beep')
        if bits(dt):
            peak = max(peak, u(dt))
            cur = u(dt) != 0
            if bp in ('0', '1') and prev_timer is not None:
                if bool(cur) != (bp == '1'):
                    bad_beep += 1
            prev_timer = cur
            last_timer = u(dt)
    check(strobes == 4096, f'loader: {strobes} strobes (want 4096)')
    check(load_errors == 0, f'loader: {load_errors} data mismatches')
    check(peak >= 1, f'beep: sound_timer peak {peak} (want >= 1)')
    check(bad_beep == 0, f'beep: {bad_beep} beep/sound_timer mismatches'
          if bad_beep else 'beep: audio.beep follows sound_timer != 0')
    # and it must have decayed back to zero (beep deasserted at some point)
    check(last_timer == 0, f'beep: sound_timer ends at {last_timer} (want 0, decayed)')

print(f'PASS {len(oks)}')
for m in oks: print('  ok :', m)
if failures:
    print(f'FAIL {len(failures)}')
    for m in failures: print('  FAIL:', m)
    sys.exit(1)
print('ALL CHECKS PASSED')
