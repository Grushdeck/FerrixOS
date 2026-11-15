#!/bin/bash
set -e
nasm -f bin boot.asm -o boot.bin
nasm -f bin kernel.asm     -o kernel.bin
stat -c%s kernel.bin
# внешние программы (.FAP) из apps/
mkdir -p build
for src in apps/*.asm; do
    name=$(basename "${src%.asm}" | tr a-z A-Z)
    nasm -f bin -I. -Iapps/ "$src" -o "build/$name.FAP"
done
# Образ: по умолчанию жёсткий диск 32 МБ FAT16 (hd.img); ./build.sh floppy — дискета 1,44 МБ FAT12 (os.img).
# Ядро работает с 1 сектором на кластер, поэтому mkfs.fat вызывается с -s 1.
if [ "$1" = floppy ]; then
    IMG=os.img
    dd if=/dev/zero of=$IMG bs=512 count=2880 status=none
    mkfs.fat -F 12 -s 1 -n "FERRIX_OS" $IMG
    QDRIVE="-fda $IMG -boot a"
else
    IMG=hd.img
    dd if=/dev/zero of=$IMG bs=512 count=65520 status=none
    mkfs.fat -F 16 -s 1 -r 512 -h 0 -n "FERRIX_OS" $IMG
    QDRIVE="-drive file=$IMG,format=raw,if=ide -boot c"
fi
# KERNEL.SYS должен лежать в корне (его ищет загрузчик);
# всё остальное системное — в /SYSTEM, программы — в /SYSTEM/SYSAPPS
mcopy -i $IMG kernel.bin   ::KERNEL.SYS
mmd   -i $IMG ::SYSTEM ::SYSTEM/SYSAPPS
for fap in build/*.FAP; do
    mcopy -i $IMG "$fap" "::SYSTEM/SYSAPPS/$(basename "$fap")"
done
[ -f autoexec.sh ] && mcopy -i $IMG autoexec.sh ::SYSTEM/AUTOEXEC.SH
# исходники программ (для iron) — в /SYSTEM/SRC (имена в верхнем регистре, 8.3)
mmd -i $IMG ::SYSTEM/SRC
for src in fapi.inc apps/*.asm apps/*.inc; do
    name=$(basename "$src"); name=${name%.*}; ext=${src##*.}
    mcopy -i $IMG "$src" "::SYSTEM/SRC/$(echo "${name:0:8}.$ext" | tr a-z A-Z)"
done
# ferpy: примеры и тест компилятора -> frasm (build/PY*.ASM, в образ — в корень; в системе: iron /PYHELLO.ASM /H.FAP)
for fp in examples/*.fpy tests/*.fpy; do
    [ -f "$fp" ] || continue
    name=$(basename "${fp%.fpy}"); name=$(echo "PY${name:0:6}" | tr a-z A-Z)
    [ "$fp" = tests/ferpy_test.fpy ] && name=PYTEST
    python3 tools/fpy.py "$fp" -o "build/$name.ASM" >/dev/null
    mcopy -i $IMG "build/$name.ASM" "::$name.ASM"
done
# примеры: исходники frasm для iron, ROM для micro, песня для synth — в корень
for ex in examples/*; do
    case "$ex" in *.fpy) continue;; esac      # .fpy уже скомпилированы выше
    [ -f "$ex" ] && mcopy -i $IMG "$ex" "::$(basename "$ex")"
done
# загрузочный сектор: код из boot.bin, BPB — от mkfs.fat
dd if=boot.bin of=$IMG bs=1 count=3 conv=notrunc status=none
dd if=boot.bin of=$IMG bs=1 skip=62 seek=62 conv=notrunc status=none
# запуск: PC speaker + Sound Blaster 16 (play/ferramp) + Intel HD Audio (play ... hda, synth)
qemu-system-i386 $QDRIVE -audiodev alsa,id=snd0 -machine pcspk-audiodev=snd0 \
    -device sb16,audiodev=snd0 \
    -device intel-hda -device hda-output,audiodev=snd0
