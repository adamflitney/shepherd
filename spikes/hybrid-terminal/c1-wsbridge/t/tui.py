import os, signal, sys, time, struct, fcntl, termios
def size():
    sz = os.get_terminal_size(1); return sz.lines, sz.columns
n = 0
def frame(full=False):
    r, c = size()
    out = ['\x1b[?2026h']
    if full: out.append('\x1b[2J')
    out.append('\x1b[H')
    for i in range(r):
        label = f' row {i:02d} ' + ('#' * (c - 12) if i % 5 == 0 else '.' * (c - 12))
        out.append(f'\x1b[{i+1};1H\x1b[{31 + i % 6}m{label[:c]}\x1b[0m')
    out.append(f'\x1b[{r};1H\x1b[7m frame {n:07d} size {c}x{r} \x1b[0m\x1b[K\x1b[?2026l')
    sys.stdout.write(''.join(out)); sys.stdout.flush()
sys.stdout.write('\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h'); sys.stdout.flush()
signal.signal(signal.SIGWINCH, lambda *a: frame(True))
frame(True)
while True:
    n += 1; frame(); time.sleep(0.004)
