"""Dump dialog, menu and string-table text from a PE file's resources (read-only)."""
import struct, sys

data = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', data, 0x3c)[0]
nsec = struct.unpack_from('<H', data, pe + 6)[0]
optsz = struct.unpack_from('<H', data, pe + 20)[0]
magic = struct.unpack_from('<H', data, pe + 24)[0]
dd = pe + 24 + (96 if magic == 0x10b else 112)
rsrc_rva, _ = struct.unpack_from('<II', data, dd + 2 * 8)
secs = [struct.unpack_from('<8sIIII', data, pe + 24 + optsz + i * 40) for i in range(nsec)]
def off(rva):
    for _, vs, va, rs, rp in secs:
        if va <= rva < va + max(vs, rs): return rva - va + rp
base = off(rsrc_rva)

def ustr(o):
    n = struct.unpack_from('<H', data, o)[0]
    return data[o + 2:o + 2 + 2 * n].decode('utf-16le')

def entries(o):
    nn, ni = struct.unpack_from('<HH', data, o + 12)
    for i in range(nn + ni):
        name, target = struct.unpack_from('<II', data, o + 16 + 8 * i)
        key = ustr(base + (name & 0x7fffffff)) if name & 0x80000000 else name
        yield key, target

def leaves(t):
    out = []
    for name, t2 in entries(base + (t & 0x7fffffff)):
        for lang, t3 in entries(base + (t2 & 0x7fffffff)):
            rva, size = struct.unpack_from('<II', data, base + t3)[:2]
            out.append((name, lang, data[off(rva):off(rva) + size]))
    return out

types = dict(entries(base))

def sz_or_ord(b, o):
    if struct.unpack_from('<H', b, o)[0] == 0xFFFF: return o + 4, '#%d' % struct.unpack_from('<H', b, o + 2)[0]
    e = o
    while struct.unpack_from('<H', b, e)[0]: e += 2
    return e + 2, b[o:e].decode('utf-16le')

CLASSES = {0x80: 'Button', 0x81: 'Edit', 0x82: 'Static', 0x83: 'ListBox', 0x84: 'ScrollBar', 0x85: 'ComboBox'}
def dialog(b):
    ex = struct.unpack_from('<HH', b, 0) == (1, 0xFFFF)
    if ex:
        _, _, _, _, style, n, x, y, cx, cy = struct.unpack_from('<HHIIIHhhhh', b, 0); o = 26
    else:
        style, _, n, x, y, cx, cy = struct.unpack_from('<IIHhhhh', b, 0); o = 18
    o, menu = sz_or_ord(b, o); o, cls = sz_or_ord(b, o); o, title = sz_or_ord(b, o)
    if style & 0x40:
        o += 2 + (4 if ex else 0); o, _ = sz_or_ord(b, o)
    lines = ['  "%s" %dx%d' % (title, cx, cy)]
    for _ in range(n):
        o = (o + 3) & ~3
        if ex: _, _, _, x, y, w, h, cid = struct.unpack_from('<IIIhhhhI', b, o); o += 24
        else: _, _, x, y, w, h, cid = struct.unpack_from('<IIhhhhH', b, o); o += 18
        if struct.unpack_from('<H', b, o)[0] == 0xFFFF:
            c = CLASSES.get(struct.unpack_from('<H', b, o + 2)[0], '?'); o += 4
        else: o, c = sz_or_ord(b, o)
        o, text = sz_or_ord(b, o)
        extra = struct.unpack_from('<H', b, o)[0]; o += 2 + extra
        if text and not text.startswith('#'):
            lines.append('    %-12s %-40s @%d,%d %dx%d' % (c[:12], repr(text)[1:-1][:40], x, y, w, h))
        elif c not in ('Button', 'Static', 'Edit'):
            lines.append('    %-12s %-40s @%d,%d %dx%d' % (c[:12], '', x, y, w, h))
    return '\n'.join(lines)

def menu(b):
    out, o, depth = [], 4, 0
    if struct.unpack_from('<H', b, 0)[0] == 1: return '  (extended menu)'
    while o < len(b):
        flags = struct.unpack_from('<H', b, o)[0]; o += 2
        if not flags & 0x10: o += 2
        e = o
        while struct.unpack_from('<H', b, e)[0]: e += 2
        text = b[o:e].decode('utf-16le'); o = e + 2
        out.append('  ' + '  ' * depth + (text or '----'))
        if flags & 0x10: depth += 1
        if flags & 0x80:
            depth = max(0, depth - 1)
    return '\n'.join(out)

for name, lang, b in leaves(types[5]):
    if lang in (1033, 0):
        try: print('DIALOG %s\n%s' % (name, dialog(b)))
        except Exception as ex: print('DIALOG %s parse error %s' % (name, ex))
for name, lang, b in leaves(types[4]):
    if lang in (1033, 0): print('MENU %s\n%s' % (name, menu(b)))
