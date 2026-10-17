"""Reads an Ogg Opus file as a player would, independently of the Swift that wrote it: every page and its checksum, the
OpusHead, each packet decoded with the real libopus, the pre-skip dropped and the end trimmed to the last granule.
Then compares the sound with the tone the test fed in (0.3 x sin at 997 Hz; the right side a quarter-cycle later) and
prints what it found as JSON.

    python check-ogg-opus.py <file.opus> <libopus library>
"""
import ctypes, json, math, struct, sys

path, library = sys.argv[1], sys.argv[2]
data = open(path, 'rb').read()

table = []
for i in range(256):
    r = i << 24
    for _ in range(8):
        r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else (r << 1)
    table.append(r & 0xFFFFFFFF)

def crc(b):
    c = 0
    for x in b:
        c = ((c << 8) & 0xFFFFFFFF) ^ table[((c >> 24) ^ x) & 0xFF]
    return c

pages, at, problems = [], 0, []
while at < len(data):
    if data[at:at + 4] != b'OggS':
        problems.append('no capture pattern at %d' % at)
        break
    flags = data[at + 5]
    granule = struct.unpack_from('<q', data, at + 6)[0]
    serial, sequence, stored = struct.unpack_from('<III', data, at + 14)
    n = data[at + 26]
    lacing = data[at + 27:at + 27 + n]
    body = at + 27 + n
    end = body + sum(lacing)
    copy = bytearray(data[at:end])
    copy[22:26] = b'\0\0\0\0'
    packets, current, p = [], b'', body
    for l in lacing:
        current += data[p:p + l]
        p += l
        if l < 255:
            packets.append(current)
            current = b''
    pages.append(dict(flags=flags, granule=granule, serial=serial, sequence=sequence, crc_ok=crc(copy) == stored,
                      packets=packets, continued=len(current) > 0))
    at = end

head = pages[0]['packets'][0]
channels = head[9]
pre_skip = struct.unpack_from('<H', head, 10)[0]
tags_ok = pages[1]['packets'][0][:8] == b'OpusTags'

opus = ctypes.CDLL(library)
opus.opus_decoder_create.restype = ctypes.c_void_p
opus.opus_decode_float.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32, ctypes.POINTER(ctypes.c_float),
                                   ctypes.c_int, ctypes.c_int]
err = ctypes.c_int(0)
decoder = opus.opus_decoder_create(48000, channels, ctypes.byref(err))
pcm = []
buffer = (ctypes.c_float * (5760 * channels))()
for page in pages[2:]:
    for packet in page['packets']:
        got = opus.opus_decode_float(decoder, packet, len(packet), buffer, 5760, 0)
        if got < 0:
            problems.append('decode error %d' % got)
            continue
        pcm.extend(buffer[:got * channels])
frames_decoded = len(pcm) // channels
last = pages[-1]['granule']
playable = last - pre_skip
sound = pcm[pre_skip * channels:(pre_skip + playable) * channels]
frames = len(sound) // channels

def tone(n, side):
    return 0.3 * math.sin(2 * math.pi * 997 * n / 48000 - (math.pi / 2 if side else 0))

def expected(n):
    if channels == 1:
        return (tone(n, 0) + tone(n, 1)) * 0.5
    return None

# Where the decoded sound lines up with the tone best (0 when the pre-skip was declared rightly), and how well.
def score(lag, side):
    num = den_a = den_b = 0.0
    for n in range(2000, frames - 2000, 3):
        a = sound[n * channels + side]
        m = n + lag
        b = expected(m) if channels == 1 else tone(m, side)
        num += a * b
        den_a += a * a
        den_b += b * b
    return num / math.sqrt(den_a * den_b) if den_a > 0 and den_b > 0 else 0.0

best = max(range(-40, 41), key=lambda lag: score(lag, 0))
corr = score(best, 0)
rms = math.sqrt(sum(sound[n * channels] ** 2 for n in range(2000, frames - 2000)) / max(1, frames - 4000))
want = math.sqrt(sum((expected(n) if channels == 1 else tone(n, 0)) ** 2 for n in range(2000, frames - 2000)) / max(1, frames - 4000))
print(json.dumps(dict(
    pages=len(pages), crc_ok=all(p['crc_ok'] for p in pages), sequences_ok=[p['sequence'] for p in pages] == list(range(len(pages))),
    one_serial=len(set(p['serial'] for p in pages)) == 1, bos_first=pages[0]['flags'] == 2,
    eos_last=pages[-1]['flags'] == 4, eos_only_last=all(p['flags'] & 4 == 0 for p in pages[:-1]),
    no_continued=not any(p['continued'] for p in pages), tags_ok=tags_ok, channels=channels, pre_skip=pre_skip,
    frames_decoded=frames_decoded, frames=frames, lag=best, corr=round(corr, 5),
    level_db=round(20 * math.log10(rms / want), 3) if rms > 0 else -999, problems=problems)))
