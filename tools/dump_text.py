import struct

with open('zig-out/bin/zinux-aarch64', 'rb') as f:
    data = f.read()

eh = struct.unpack('<16BHHIQQQIHHHHHH', data[0:64])
e_shoff = eh[21]
e_shentsize = eh[26]
e_shnum = eh[27]
e_shstrndx = eh[28]

sections = []
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    name, stype, flags, addr, offset, size = struct.unpack('<IIQQQQ', data[off:off + 40])
    sections.append((name, stype, flags, addr, offset, size))

strtab = sections[e_shstrndx]
strbase = strtab[4]


def getname(ni):
    end = data.index(b'\x00', strbase + ni)
    return data[strbase + ni:end].decode()


for name, stype, flags, addr, offset, size in sections:
    print(hex(addr), hex(size), getname(name))

text = [s for s in sections if getname(s[0]) == '.text'][0]
_, _, _, addr, offset, size = text
blob = data[offset:offset + size]
print('text words:')
for i in range(0, len(blob), 4):
    print(hex(addr + i), blob[i:i + 4].hex())
