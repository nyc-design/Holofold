#!/usr/bin/env python3
"""Tells whether .cia files are decrypted enough for Azahar/Bifold to install.

    python3 scripts/tools/ciacheck.py game1.cia [game2.cia ...]

Azahar only installs CIAs whose contents are fully decrypted. Two layers are checked for every
NCCH content in the CIA:
  1. CIA layer: the TMD content chunk's "encrypted" bit (title-key AES-CBC) must be clear.
  2. NCCH layer: the NCCH header's NoCrypto flag (flags[7] & 0x04) must be set, and the ExeFS
     header must be readable plaintext (its first file name is ".code" for a program).
Exit code 0 = every file is usable, 1 = at least one is not.
"""
import struct
import sys

MEDIA_UNIT = 0x200


def align(x, a=64):
    return (x + a - 1) // a * a


SIG_SIZES = {0x10000: 0x200, 0x10001: 0x100, 0x10002: 0x3C,
             0x10003: 0x200, 0x10004: 0x100, 0x10005: 0x3C}


def sig_block(sigtype):
    """Size of a signature block: type (4) + signature, padded to a 0x40 boundary."""
    return align(4 + SIG_SIZES[sigtype], 0x40)


def check(path):
    with open(path, "rb") as f:
        hdr_size, _, _, cert, tik, tmd, _, _ = struct.unpack("<IHHIIIIQ", f.read(0x20))
        off_tmd = align(align(align(hdr_size) + cert) + tik)
        off_content = align(off_tmd + tmd)

        f.seek(off_tmd)
        body = off_tmd + sig_block(struct.unpack(">I", f.read(4))[0])
        f.seek(body + 0x4C)
        title_id = f.read(8).hex().upper()
        f.seek(body + 0x9E)
        count = struct.unpack(">H", f.read(2))[0]
        f.seek(body + 0xC4 + 64 * 0x24)
        chunks = []
        for _ in range(count):
            chunks.append(struct.unpack(">IHHQ", f.read(0x10)))
            f.read(0x20)  # SHA-256 of the content

        ok = True
        lines = []
        pos = off_content
        for content_id, index, ctype, size in chunks:
            cia_enc = bool(ctype & 1)
            if cia_enc:
                lines.append(f"  content {index}: encrypted at the CIA layer (title key)")
                ok = False
                pos += align(size, 64)
                continue
            f.seek(pos + 0x100)
            if f.read(4) != b"NCCH":
                lines.append(f"  content {index}: no NCCH header (unreadable, probably encrypted as a whole)")
                ok = False
                pos += align(size, 64)
                continue
            f.seek(pos + 0x188)
            flags = f.read(8)
            nocrypto = bool(flags[7] & 0x04)
            f.seek(pos + 0x1A0)
            exefs_off = struct.unpack("<I", f.read(4))[0] * MEDIA_UNIT
            exefs_name = b""
            if exefs_off:
                f.seek(pos + exefs_off)
                exefs_name = f.read(8).rstrip(b"\0")
            plain = exefs_off == 0 or exefs_name.isascii() and exefs_name[:1] in (b".", b"b", b"i", b"l")
            state = "decrypted" if nocrypto and plain else "NCCH still encrypted"
            if state != "decrypted":
                ok = False
            lines.append(f"  content {index}: {state} (NoCrypto={'yes' if nocrypto else 'no'}, "
                         f"first ExeFS file={exefs_name!r})")
            pos += align(size, 64)

    verdict = "✅ usable: decrypted, ready to import" if ok else "❌ still encrypted inside: Azahar will refuse to install it"
    print(f"{path}\n  Title ID {title_id}, {count} content(s) → {verdict}")
    print("\n".join(lines))
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    results = []
    for p in sys.argv[1:]:
        try:
            results.append(check(p))
        except Exception as e:  # malformed file
            print(f"{p}\n  ❌ cannot parse: {e}")
            results.append(False)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
