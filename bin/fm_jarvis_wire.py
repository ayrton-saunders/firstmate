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
        require(len(entries) == count and (not entries or min(e.header_offset for e in entries) == 0))
        for e in entries:
            p = e.header_offset
            require(e.volume == 0 and 0 <= p <= offset - 30 and data[p:p+4] == b'PK\x03\x04')
            flags, method = struct.unpack_from('<HH', data, p + 6)
            require(flags == e.flag_bits and not flags & (1 | 0x40 | 0x2000)
                    and method == e.compress_type and method in (0, 8))


def signature(data, mime):
    if mime == 'application/zip':
        plain_zip(data)
        return
    require(not zipfile.is_zipfile(io.BytesIO(data)))
    if mime == 'image/png':
        require(data.startswith(b'\x89PNG\r\n\x1a\n\0\0\0\rIHDR') and data.endswith(b'\0\0\0\0IEND\xaeB`\x82'))
    elif mime == 'image/jpeg':
        require(data.startswith(b'\xff\xd8\xff') and data.endswith(b'\xff\xd9'))
    elif mime == 'image/webp':
        require(len(data) >= 20 and data[:4] == b'RIFF' and data[8:12] == b'WEBP'
                and data[12:16] in (b'VP8 ', b'VP8L', b'VP8X') and int.from_bytes(data[4:8], 'little') == len(data)-8)
    else:
        require(re.match(rb'%PDF-[12]\.[0-9][\r\n]', data) and data.rstrip().endswith(b'%%EOF'))


MIME = {'png': 'image/png', 'jpeg': 'image/jpeg', 'jpg': 'image/jpeg', 'webp': 'image/webp',
        'pdf': 'application/pdf', 'zip': 'application/zip'}


def envelope(reader):
    m = parse(reader.frame(MANIFEST))
    require(set(m) in ({'v', 'text'}, {'v', 'text', 'files'}) and type(m['v']) is int and m['v'] == 1)
    body = text(m['text'], 16*K)
    files = m.get('files', [])
    require(type(files) is list and len(files) <= 4)
    blobs, names, total = [], set(), 0
    for f in files:
        require(type(f) is dict and set(f) == {'name', 'mime', 'length', 'sha256'})
        name = f['name']
        require(type(name) is str and 0 < len(name) <= 128 and not name.startswith('.')
                and all(c.isprintable() and c not in '/\\:' for c in name))
        name = re.sub(r'[^A-Za-z0-9._-]', '_', name)
        require(name.lower() not in names and '.' in name)
        names.add(name.lower())
        f['name'] = name
        require(type(f['mime']) is str and MIME.get(name.rsplit('.', 1)[1].lower()) == f['mime'])
        n = f['length']
        require(type(n) is int and 0 < n <= FILE and total + n <= TOTAL)
        total += n
        blob = reader.frame(FILE, n)
        require(digest(blob) == f['sha256'])
        signature(blob, f['mime'])
        blobs.append(blob)
    reader.bounded(0)
    return body, files, blobs, reader.hash.hexdigest()
