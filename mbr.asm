;======================================
; File name: mbr.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: главная загрузочная запись (MBR) для ferrix.img и ISO
;======================================
; Переносит себя в 0000:0600, читает первый сектор раздела №1 (LBA из таблицы разделов,
; геометрия от BIOS int 13h/08h, CHS) в 0000:7C00 и передаёт ему управление с DL = диск
; и DS:SI -> запись раздела. Таблицу разделов (446..509) и подпись записывает mkdisk.py/mkiso.py.
[bits 16]
[org 0x0600]
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov si, 0x7C00
    mov di, 0x0600
    mov cx, 256
    rep movsw
    jmp 0x0000:.go
.go:
    mov [drive], dl
    mov ah, 0x08                    ; геометрия (на CD с HDD-эмуляцией BIOS берёт её из таблицы разделов)
    int 0x13
    jc .geo
    and cx, 0x3F
    jz .geo
    mov [spt], cx
    xor ax, ax
    mov al, dh
    inc ax
    mov [heads], ax
.geo:
    mov si, 0x0600 + 446            ; раздел №1
    mov ax, [si + 8]                ; LBA начала
    mov dx, [si + 10]
    div word [spt]
    mov cl, dl
    inc cl
    xor dx, dx
    div word [heads]
    mov dh, dl
    mov ch, al
    shl ah, 6
    or cl, ah
    mov bp, 3
.read:
    mov dl, [drive]
    mov bx, 0x7C00
    mov ax, 0x0201
    int 0x13
    jnc .ok
    xor ah, ah
    int 0x13
    dec bp
    jnz .read
    jmp .err
.ok:
    cmp word [0x7DFE], 0xAA55
    jne .err
    mov dl, [drive]
    jmp 0x0000:0x7C00
.err:
    mov si, msg
    mov ah, 0x0E
    xor bh, bh
.pr:
    lodsb
    test al, al
    jz $
    int 0x10
    jmp .pr
msg:    db "MBR: cannot load boot sector", 0
drive:  db 0
spt:    dw 63
heads:  dw 16
times 446-($-$$) db 0
times 64 db 0                       ; таблица разделов
dw 0xAA55
