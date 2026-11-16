#!/bin/bash
set -e
nasm -f bin boot.asm -o boot.bin
nasm -f bin mbr.asm  -o mbr.bin
nasm -f bin kernel.asm     -o kernel.bin
stat -c%s kernel.bin
# внешние программы (.FAP) из apps/
# утилиты оболочки (бывшие встроенные команды) — в подкаталог /SYSTEM/SYSAPPS/FSH
FSH_APPS="fetch cpu mem date time echo hex bin ascii matrix banner osinfo credits"
mkdir -p build/FSH
for src in apps/*.asm; do
    base=$(basename "${src%.asm}")
    name=$(echo "$base" | tr a-z A-Z)
    case " $FSH_APPS " in
        *" $base "*) out="build/FSH/$name.FAP" ;;
        *)           out="build/$name.FAP" ;;
    esac
    nasm -f bin -I. -Iapps/ "$src" -o "$out"
done
# Образ: по умолчанию жёсткий диск 32 МБ (ferrix.img): MBR + раздел №1 FAT16 с сектора 63;
# ./build-img.sh floppy — дискета 1,44 МБ FAT12 (os.img) без MBR.
# Ядро работает с 1 сектором на кластер, поэтому mkfs.fat вызывается с -s 1.
PART=63                     # начало раздела (hidden sectors в BPB; ядро и загрузчик прибавляют его к LBA)
if [ "$1" = floppy ]; then
    IMG=os.img
    dd if=/dev/zero of=$IMG bs=512 count=2880 status=none
    mkfs.fat -F 12 -s 1 -n "FERRIX_OS" $IMG
    QDRIVE="-fda $IMG -boot a"
else
    IMG=part.img            # том FAT16; в конце заворачивается в ferrix.img вместе с MBR
    # 65457 секторов: раздел с 63-го до конца 65-го цилиндра (CHS 16/63), чтобы конец раздела
    # в таблице был 64/15/63 — BIOS при загрузке с ISO (El Torito HDD) берёт геометрию именно оттуда
    dd if=/dev/zero of=$IMG bs=512 count=65457 status=none
    mkfs.fat -F 16 -s 1 -r 512 -h $PART -g 16/63 -n "FERRIX_OS" $IMG
    QDRIVE="-drive file=ferrix.img,format=raw,if=ide -boot c"
fi
# KERNEL.SYS должен лежать в корне (его ищет загрузчик);
# всё остальное системное — в /SYSTEM, программы — в /SYSTEM/SYSAPPS
mcopy -i $IMG kernel.bin   ::KERNEL.SYS
mmd   -i $IMG ::SYSTEM ::SYSTEM/SYSAPPS ::SYSTEM/SYSAPPS/FSH
for fap in build/*.FAP; do
    mcopy -i $IMG "$fap" "::SYSTEM/SYSAPPS/$(basename "$fap")"
done
for fap in build/FSH/*.FAP; do
    mcopy -i $IMG "$fap" "::SYSTEM/SYSAPPS/FSH/$(basename "$fap")"
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
if [ "$IMG" = part.img ]; then
    # MBR: код mbr.bin + таблица разделов (один активный раздел FAT16: LBA 63, 65457 секторов, конец CHS 64/15/63)
    { head -c 446 mbr.bin
      printf '\x80\x01\x01\x00\x06\x0f\x3f\x40\x3f\x00\x00\x00\xb1\xff\x00\x00'
      head -c 48 /dev/zero; printf '\x55\xaa'
      head -c $(( (PART-1)*512 )) /dev/zero
      cat part.img; } > ferrix.img
    rm -f part.img
    IMG=ferrix.img
fi
# запуск: PC speaker + Sound Blaster 16 (play/ferramp) + Intel HD Audio (play ... hda, synth)
# NORUN=1 ./build-img.sh — только собрать образ (так его вызывает build-iso.sh)
[ -n "$NORUN" ] && exit 0
qemu-system-i386 $QDRIVE -audiodev alsa,id=snd0 -machine pcspk-audiodev=snd0 \
    -device sb16,audiodev=snd0 \
    -device intel-hda -device hda-output,audiodev=snd0
