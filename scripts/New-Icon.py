from pathlib import Path
import struct

size = 64
pixels = bytearray()
for y in range(size - 1, -1, -1):
    for x in range(size):
        letter = (15 <= x < 25 and 13 <= y < 50) or (15 <= x < 49 and 40 <= y < 50)
        pixels.extend((20, 17, 16, 255) if letter else (89, 255, 214, 255))
mask = bytes(size * 8)
bitmap = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, len(pixels), 0, 0, 0, 0)
image = bitmap + pixels + mask
directory = struct.pack("<HHHBBBBHHII", 0, 1, 1, size, size, 0, 0, 1, 32, len(image), 22)
output = Path(__file__).resolve().parents[1] / "assets" / "Larp.ico"
output.write_bytes(directory + image)
