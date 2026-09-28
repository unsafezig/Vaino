import sys

with open('zig-out/bin/zinux-aarch64', 'rb') as f:
    data = f.read()

needle = bytes([0x00, 0x00, 0x1E, 0xD4])
idx = 0
n = 0
while True:
    i = data.find(needle, idx)
    if i < 0:
        break
    n += 1
    print('HLT found at file offset', hex(i))
    lo = max(0, i - 48)
    chunk = data[lo:i + 8]
    for off in range(0, len(chunk), 4):
        word = chunk[off:off + 4]
        if len(word) < 4:
            break
        addr = lo + off
        print(hex(addr), word.hex())
    idx = i + 4
print('total', n)
