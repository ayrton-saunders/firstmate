"""Bounded Jarvis v1 stdin framing. Treat every byte as data."""
import hashlib
import io
import json
import os
import re
import select
import struct
import time
import zipfile
import zlib

K = 1024
M = K * K
MANIFEST = 24 * K
FILE = 8 * M
TOTAL = 16 * M


class Refusal(Exception):
    pass


def require(ok, reason='invalid'):
    if not ok:
        raise Refusal(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode()


def object_pairs(pairs):
    obj = dict(pairs)
    require(len(obj) == len(pairs))
    return obj


def parse(data):
    try:
        obj = json.loads(data.decode(), object_pairs_hook=object_pairs)
        require(type(obj) is dict)
        return obj
    except (ValueError, RecursionError):
        raise Refusal('invalid') from None


class Reader:
    def __init__(self):
        self.deadline = time.monotonic() + 60
        self.count = 0
        self.hash = hashlib.sha256()

    def read(self, size):
        ready, _, _ = select.select([0], [], [], max(0, min(10, self.deadline - time.monotonic())))
        require(ready and time.monotonic() < self.deadline)
        data = os.read(0, min(size, 65536))
        self.count += len(data)
        self.hash.update(data)
        return data

    def bounded(self, limit, exact=False):
        result = bytearray()
        while len(result) < limit + (not exact):
            chunk = self.read(limit + (not exact) - len(result))
            if not chunk:
                break
            result.extend(chunk)
        require(len(result) == limit if exact else len(result) <= limit)
        return bytes(result)

    def frame(self, maximum, expected=None):
        n, = struct.unpack('>I', self.bounded(4, exact=True))
        require(0 < n <= maximum and (expected is None or n == expected))
        return self.bounded(n, exact=True)


def text(value, limit):
    require(type(value) is str and value.strip() and all(ord(c) >= 32 or c in '\t\r\n' for c in value))
    require(len(value.encode()) <= limit)
    return value


def plain_zip(data):
    # Inspect headers only. No entry is decompressed, decrypted or extracted.
    require(data.startswith((b'PK\x03\x04', b'PK\x05\x06')))
    end = data.rfind(b'PK\x05\x06', max(0, len(data) - 65557))
    require(end >= 0 and end + 22 <= len(data))
    disk, cd_disk, here, count, size, offset, comment = struct.unpack_from('<4H2IH', data, end + 4)
    require(not disk and not cd_disk and here == count and offset + size == end
            and end + 22 + comment == len(data))
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        require(len(entries) == count and min((e.header_offset for e in entries), default=offset) == 0)
        entries.sort(key=lambda e: e.header_offset)
        for i, e in enumerate(entries):
            limit = entries[i+1].header_offset if i+1 < len(entries) else offset
            p = e.header_offset
            require(e.volume == 0 and 0 <= p <= offset - 30 and data[p:p+4] == b'PK\x03\x04')
            flags, method = struct.unpack_from('<HH', data, p + 6)
            require(flags == e.flag_bits and not flags & (1 | 0x40 | 0x2000)
                    and method == e.compress_type
                    and (method != 0 or e.file_size == e.compress_size))
            crc, size, expanded, name_len, extra_len = struct.unpack_from('<IIIHH', data, p+14)
            name_end = p+30+name_len
            end_data = name_end+extra_len+e.compress_size
            require(end_data <= limit <= offset and name_len > 0)
            name = data[p+30:name_end]
            require(b'\0' not in name and name.decode('utf-8' if flags & 0x800 else 'cp437') == e.orig_filename)
            expected = (e.CRC, e.compress_size, e.file_size)
            if flags & 8:
                require(all(x in (0, y) for x, y in zip((crc, size, expanded), expected)))
                if data[end_data:end_data+4] == b'PK\x07\x08' and end_data+16 <= limit:
                    end_data += 4
                require(end_data+12 <= limit and struct.unpack_from('<III', data, end_data) == expected)
            else:
                require((crc, size, expanded) == expected)


def png(data):
    require(data.startswith(b'\x89PNG\r\n\x1a\n'))
    p = 8
    image = False
    while p+12 <= len(data):
        n, kind = struct.unpack_from('>I4s', data, p)
        end = p+8+n
        require(end+4 <= len(data) and re.fullmatch(rb'[A-Za-z]{4}', kind))
        require(zlib.crc32(memoryview(data)[p+4:end]) == struct.unpack_from('>I', data, end)[0])
        if p == 8:
            require(kind == b'IHDR' and n == 13)
            w, h, depth, color, compression, filtering, interlace = struct.unpack_from('>IIBBBBB', data, p+8)
            require(0 < w < 2**31 and 0 < h < 2**31 and compression == filtering == 0 and interlace in (0, 1))
            require(depth in {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                              4: (8, 16), 6: (8, 16)}.get(color, ()))
        else:
            require(kind != b'IHDR')
        if kind == b'IEND':
            require(image and n == 0 and end+4 == len(data))
            return
        image |= kind == b'IDAT' and n > 0
        p = end+4
    require(False)


def webp(data):
    require(data.startswith(b'RIFF') and data[8:12] == b'WEBP'
            and int.from_bytes(data[4:8], 'little') == len(data)-8
            and data[12:16] in (b'VP8 ', b'VP8L', b'VP8X'))
    p = 12
    image = False
    while p+8 <= len(data):
        kind, n = struct.unpack_from('<4sI', data, p)
        end = p+8+n
        require(end+(n & 1) <= len(data) and (not n & 1 or data[end] == 0))
        if kind == b'VP8X':
            require(p == 12 and n == 10)
        if kind in (b'VP8 ', b'VP8L', b'ANMF'):
            require(n >= {b'VP8 ': 10, b'VP8L': 5, b'ANMF': 24}[kind])
            image = True
        p = end+(n & 1)
    require(image and p == len(data))


JPEG_MARKER = re.compile(rb'\xff+([^\xff\x00\xd0-\xd7])')
JPEG_SCAN_MARKER = re.compile(rb'(?<!\xff)' + JPEG_MARKER.pattern)


def jpeg(data):
    require(data.startswith(b'\xff\xd8'))
    p = 2
    frame = scan = False
    while p < len(data):
        m = JPEG_MARKER.match(data, p)
        require(m)
        kind = m[1][0]
        p = m.end()
        if kind == 0xd9:
            require(scan and p == len(data))
            return
        require(kind == 1 or 0xc0 <= kind <= 0xfe and kind != 0xd8)
        if kind == 1:
            continue
        require(p+2 <= len(data))
        n, = struct.unpack_from('>H', data, p)
        require(n >= 2 and p+n <= len(data))
        if 0xc0 <= kind <= 0xcf and kind not in (0xc4, 0xc8, 0xcc):
            require(n >= 11 and data[p+7] > 0 and n == 8+3*data[p+7])
            frame = True
        if kind == 0xda:
            require(frame and n >= 8 and data[p+2] > 0 and n == 6+2*data[p+2])
            scan = True
            following = JPEG_SCAN_MARKER.search(data, p+n)
            require(following and following.start() > p+n)
            p = following.start()
        else:
            p += n
    require(False)


PDF_TRAILER = re.compile(rb'(?:\r\n?|\n)startxref[\t ]*[\r\n]+([0-9]{1,8})[\t \r\n]+%%EOF[\t \r\n]*\Z')
PDF_SUBSECTION = re.compile(rb'[\r\n\t ]*([0-9]{1,10})[\t ]+([0-9]{1,8})[\t ]*(?:\r\n?|\n)')
PDF_ENTRY = re.compile(rb'([0-9]{10}) [0-9]{5} ([nf])(?: \r| \n|\r\n)')
PDF_XREF_STREAM = re.compile(rb'[0-9]+[\t ]+[0-9]+[\t ]+obj\s*<<(.+?)>>\s*stream(?:\r\n|\n)', re.S)


def pdf(data):
    require(re.match(rb'%PDF-[12]\.[0-9][\r\n]', data))
    tail = PDF_TRAILER.search(data)
    require(tail)
    p = int(tail[1])
    require(9 <= p < tail.start())
    if data[p:p+4] != b'xref':
        stream = PDF_XREF_STREAM.match(data, p, tail.start())
        require(stream and re.search(rb'/Type\s*/XRef\b', stream[1])
                and re.search(rb'/W\s*\[\s*[0-9]+\s+[0-9]+\s+[0-9]+\s*\]', stream[1]))
        length = re.search(rb'/Length\s+([0-9]{1,8})\b', stream[1])
        require(length)
        end = stream.end()+int(length[1])
        require(end <= tail.start() and re.match(rb'\s*endstream\s+endobj\b', data[end:tail.start()]))
        return
    p += 4
    seen = False
    while (section := PDF_SUBSECTION.match(data, p, tail.start())):
        count = int(section[2])
        p = section.end()
        require(0 < count <= (tail.start()-p)//20)
        for _ in range(count):
            entry = PDF_ENTRY.match(data, p, tail.start())
            require(entry and (entry[2] == b'f' or 9 <= int(entry[1]) < tail.start()))
            p = entry.end()
        seen = True
    require(seen and re.match(rb'\s*trailer\s*<<', data[p:tail.start()]))


def signature(data, mime):
    if mime == 'application/zip':
        plain_zip(data)
        return
    require(not zipfile.is_zipfile(io.BytesIO(data)))
    {'image/png': png, 'image/jpeg': jpeg, 'image/webp': webp, 'application/pdf': pdf}[mime](data)


MIME = {'png': 'image/png', 'jpeg': 'image/jpeg', 'jpg': 'image/jpeg', 'webp': 'image/webp',
        'pdf': 'application/pdf', 'zip': 'application/zip'}


def envelope(reader):
    m = parse(reader.frame(MANIFEST))
    require(set(m) in ({'v', 'text'}, {'v', 'text', 'files'}) and type(m['v']) is int and m['v'] == 1)
    body = text(m['text'], 16*K)
    files = m.get('files', [])
    require(type(files) is list and len(files) <= 4)
    blobs, total = [], 0
    for f in files:
        require(type(f) is dict and set(f) == {'name', 'mime', 'length', 'sha256'})
        name = f['name']
        require(type(name) is str and name and not name.startswith('.')
                and all(c.isprintable() and c not in '/\\:' for c in name))
        name = re.sub(r'[^A-Za-z0-9._-]', '_', name)
        require('.' in name)
        stem, ext = name.rsplit('.', 1)
        require(type(f['mime']) is str and MIME.get(ext.lower()) == f['mime'])
        f['name'] = stem[:127-len(ext)] + '.' + ext
        n = f['length']
        require(type(n) is int and 0 < n <= FILE and total + n <= TOTAL)
        total += n
        blob = reader.frame(FILE, n)
        require(digest(blob) == f['sha256'])
        signature(blob, f['mime'])
        blobs.append(blob)
    reader.bounded(0)
    return body, files, blobs, reader.hash.hexdigest()
