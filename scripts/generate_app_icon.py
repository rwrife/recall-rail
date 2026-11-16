#!/usr/bin/env python3
import pathlib
import struct
import zlib
import json
root = pathlib.Path(__file__).resolve().parents[1] / 'RecallRail/Assets.xcassets'
folder = root / 'AppIcon.appiconset'; folder.mkdir(parents=True, exist_ok=True)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
rows = bytearray()
for y in range(1024):
    rows.append(0)
    for x in range(1024):
        # Navy field, two cream rails and golden recall cards.
        color = (18, 34, 57)
        if 250 <= x <= 290 or 734 <= x <= 774:
            if 190 <= y <= 834: color = (235, 239, 230)
        if 280 <= x <= 744 and any(a <= y <= a + 44 for a in [244, 468, 692]): color = (235, 239, 230)
        if 354 <= x <= 670 and 320 <= y <= 640: color = (246, 183, 65)
        if 400 <= x <= 624 and 386 <= y <= 416: color = (18, 34, 57)
        if 400 <= x <= 576 and 452 <= y <= 482: color = (18, 34, 57)
        rows.extend(color)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1024, 1024, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
(folder/'AppIcon.png').write_bytes(png)
(folder/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}], 'info':{'author':'xcode','version':1}}, indent=2)+'\n')
(root/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
