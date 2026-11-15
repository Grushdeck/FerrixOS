#!/usr/bin/env python3
"""mkdisk.py — собрать образ диска Ferrix OS без mtools (FAT12 дискета или FAT16 жёсткий диск).

  python3 tools/mkdisk.py OUT.img --boot boot.bin --kernel kernel.bin [--hd|--floppy] [--size MB]
                          [--sysapps DIR] [--root FILE...] [--src DIR] [--docs FILE...]

Том: 512-байтные секторы, 1 сектор на кластер (так устроено ядро). Дискета — 2880 секторов,
FAT12, корень 224 записи. Диск — до 32 МБ (65 520 секторов), FAT16, корень 512 записей,
без таблицы разделов (superfloppy): BIOS/QEMU грузит сектор 0 напрямую.
В загрузочный сектор (boot.bin) подставляется BPB тома; остальной код загрузчика общий.
"""
import argparse, os, struct, sys

SEC = 512

def parse():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--boot", required=True)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--hd", action="store_true", help="FAT16 жёсткий диск (по умолчанию — дискета)")
    ap.add_argument("--size", type=int, default=32, help="размер диска, МБ (1..32)")
    ap.add_argument("--sysapps", default=None, help="каталог с *.FAP -> /SYSTEM/SYSAPPS")
    ap.add_argument("--src", default=None, help="каталог исходников -> /SYSTEM/SRC (8.3, верхний регистр)")
    ap.add_argument("--root", nargs="*", default=[], help="файлы в корень")
    ap.add_argument("--autoexec", default=None, help="скрипт -> /SYSTEM/AUTOEXEC.SH")
    ap.add_argument("--label", default="FERRIX OS")
    return ap.parse_args()

class Vol:
    def __init__(self, hd, size_mb):
        if hd:
            total = min(size_mb, 32) * 2048
            total = min(total, 65520)          # CHS 16x63 в QEMU/BIOS; >65535 не адресуется 16 битами
            self.root_nent = 512
            self.nfats = 2
            self.reserved = 1
            self.media = 0xF8
            self.spt, self.heads = 63, 16
        else:
            total = 2880
            self.root_nent = 224
            self.nfats = 2
            self.reserved = 1
            self.media = 0xF0
            self.spt, self.heads = 18, 2
        self.total = total
        self.root_secs = self.root_nent * 32 // SEC
        # подобрать размер FAT: кластеры = total - reserved - nfats*spf - root_secs
        data = total - self.reserved - self.root_secs
        self.fat16 = data >= 4085 + 2 * 16  # грубо; уточним после расчёта spf
        for _ in range(3):
            bits = 16 if self.fat16 else 12
            spf = -(-((data + 2) * bits // 8) // SEC)  # вверх
            clusters = total - self.reserved - self.nfats * spf - self.root_secs
            self.fat16 = clusters >= 4085
            if self.fat16 and clusters > 65524:
                raise SystemExit("too many clusters for FAT16 with 512-byte clusters")
        self.spf = spf
        self.nclus = clusters
        self.fat_lba = self.reserved
        self.root_lba = self.reserved + self.nfats * spf
        self.data_lba = self.root_lba + self.root_secs
        self.img = bytearray(SEC * total)
        self.fat = bytearray(spf * SEC)
        self.eoc = 0xFFFF if self.fat16 else 0xFFF
        self.setfat(0, 0xFF00 | self.media if self.fat16 else 0xF00 | self.media)
        self.setfat(1, self.eoc)
        self.nextc = 2

    def setfat(self, c, v):
        if self.fat16:
            struct.pack_into("<H", self.fat, c * 2, v & 0xFFFF)
        else:
            o = c * 3 // 2
            if c & 1:
                self.fat[o] = (self.fat[o] & 0x0F) | ((v << 4) & 0xF0); self.fat[o + 1] = (v >> 4) & 0xFF
            else:
                self.fat[o] = v & 0xFF; self.fat[o + 1] = (self.fat[o + 1] & 0xF0) | ((v >> 8) & 0x0F)

    def write_cluster(self, c, chunk):
        lba = self.data_lba + c - 2
        self.img[lba * SEC: lba * SEC + len(chunk)] = chunk

    def alloc(self, data, minsecs=1):
        n = max(minsecs, (len(data) + SEC - 1) // SEC)
        first = self.nextc
        if first + n > self.nclus + 2:
            raise SystemExit("disk full")
        for i in range(n):
            c = first + i
            self.setfat(c, self.eoc if i == n - 1 else c + 1)
            self.write_cluster(c, data[i * SEC:(i + 1) * SEC])
        self.nextc += n
        return first

    def bpb_patch(self, boot):
        b = bytearray(boot)
        struct.pack_into("<HBHBHHBHHHII", b, 11, SEC, 1, self.reserved, self.nfats, self.root_nent,
                         self.total if self.total < 65536 else 0, self.media, self.spf,
                         self.spt, self.heads, 0, 0 if self.total < 65536 else self.total)
        b[36] = 0x80 if self.media == 0xF8 else 0x00
        b[54:62] = (b"FAT16   " if self.fat16 else b"FAT12   ")
        return bytes(b)

def ent(name, attr, cl, size):
    if name in (".", ".."): n, e = name, ""
    else: n, _, e = name.partition(".")
    return struct.pack("<8s3sB10sHHHI", n.ljust(8).encode(), e.ljust(3).encode(), attr, b"\0" * 10, 0, 0, cl, size)

def build_dir(vol, files, subdirs, parent_cl, self_cl):
    """files: [(NAME, bytes)], subdirs: {NAME: (files, subdirs)}. Возвращает байты каталога."""
    entries = b""
    if self_cl is not None:
        entries += ent(".", 0x10, self_cl, 0) + ent("..", 0x10, parent_cl, 0)
    for name, (sf, ss) in subdirs.items():
        # сначала выделяем первый кластер подкаталога (нужен для его "." и ".." у детей)
        cl = vol.nextc; vol.nextc += 1
        vol.setfat(cl, vol.eoc)
        d = build_dir(vol, sf, ss, 0 if self_cl is None else self_cl, cl)
        n = (len(d) + SEC - 1) // SEC
        vol.write_cluster(cl, d[:SEC])
        prev = cl
        for i in range(1, n):
            c = vol.alloc(d[i * SEC:(i + 1) * SEC])
            vol.setfat(prev, c); prev = c
        entries += ent(name, 0x10, cl, 0)
    for name, data in files:
        cl = vol.alloc(data) if data else 0
        entries += ent(name, 0x20, cl, len(data))
    return entries

def name83(fn):
    base, _, ext = fn.rpartition(".")
    if not base: base, ext = ext, ""
    return (base[:8] + ("." + ext[:3] if ext else "")).upper()

def main():
    a = parse()
    vol = Vol(a.hd, a.size)
    boot = open(a.boot, "rb").read()
    assert len(boot) == 512 and boot[510:512] == b"\x55\xAA", "bad boot sector"
    kernel = open(a.kernel, "rb").read()
    rootfiles = [("KERNEL.SYS", kernel)]
    for f in a.root:
        rootfiles.append((name83(os.path.basename(f)), open(f, "rb").read()))
    sysfiles = []
    if a.autoexec and os.path.isfile(a.autoexec):
        sysfiles.append(("AUTOEXEC.SH", open(a.autoexec, "rb").read()))
    syssub = {}
    if a.sysapps:
        faps = [(f.upper(), open(os.path.join(a.sysapps, f), "rb").read())
                for f in sorted(os.listdir(a.sysapps)) if f.upper().endswith(".FAP")]
        syssub["SYSAPPS"] = (faps, {})
    if a.src:
        srcs = []
        seen = set()
        for f in sorted(os.listdir(a.src)):
            if f.endswith((".asm", ".inc")):
                n = name83(f)
                if n in seen: continue
                seen.add(n)
                srcs.append((n, open(os.path.join(a.src, f), "rb").read()))
        syssub["SRC"] = (srcs, {})
    subdirs = {"SYSTEM": (sysfiles, syssub)}
    root = ent(a.label[:11].ljust(11), 0x08, 0, 0) + build_dir(vol, rootfiles, subdirs, 0, None)
    if len(root) > vol.root_secs * SEC:
        raise SystemExit("root directory full")
    vol.img[0:SEC] = vol.bpb_patch(boot)
    for i in range(vol.nfats):
        o = (vol.fat_lba + i * vol.spf) * SEC
        vol.img[o:o + len(vol.fat)] = vol.fat
    vol.img[vol.root_lba * SEC: vol.root_lba * SEC + len(root)] = root
    open(a.out, "wb").write(vol.img)
    used = vol.nextc - 2
    print(f"{a.out}: {'FAT16' if vol.fat16 else 'FAT12'}, {vol.total} sectors, {vol.nclus} clusters, "
          f"used {used} ({used // 2} KB), FAT {vol.spf} sectors, root at {vol.root_lba}, data at {vol.data_lba}")

if __name__ == "__main__":
    main()
