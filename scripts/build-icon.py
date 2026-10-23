#!/usr/bin/env python3
"""Package existing PNG representations into the standard ICNS container."""
import struct
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:3])
sizes = [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png')]
chunks=[]
for kind, name in sizes:
    data=(source/name).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    chunks.append(kind.encode('ascii')+struct.pack('>I',len(data)+8)+data)
payload=b''.join(chunks)
destination.write_bytes(b'icns'+struct.pack('>I',len(payload)+8)+payload)
