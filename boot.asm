;======================================
; File name: boot.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Bootloader
;======================================
; Загружает KERNEL.SYS в 0x1000:0000 и передаёт управление. Понимает FAT12
; (дискета 1,44 МБ) и FAT16 (жёсткий диск / флешка до 32 МБ, 1 сектор на кластер):
; расположение FAT, корня и данных считается из BPB, тип FAT — по числу кластеров,
; FAT читается по мере надобности по два сектора (12-битная запись может лежать на границе).
; Геометрию диска спрашивает у BIOS (int 13h/08h): на флешке в режиме
; USB-HDD она отличается от дискетной 18x2, и жёстко зашитые CHS грузят мусор.
; Ядро берёт геометрию и параметры тома из BPB загрузочного сектора (0x7C00+).

[bits 16]
[org 0x7c00]

jmp short start
nop

ROOT_SEG equ 0x2000                        ; корневой каталог (до 32 секторов)
FAT_SEG  equ 0x2400                        ; окно FAT (2 сектора)
KERN_SEG equ 0x1000

bdb_oem:                    db "FERRIX  "
bdb_bytes_per_sector:       dw 512
bdb_sectors_per_cluster:    db 1
bdb_reserved_sectors:       dw 1
bdb_fat_count:              db 2
bdb_dir_entries_count:      dw 224
bdb_total_sectors:          dw 2880
bdb_media_descriptor_type:  db 0xF0
bdb_sectors_per_fat:        dw 9
bdb_sectors_per_track:      dw 18          ; 0x7C18 — перезаписывается геометрией BIOS
bdb_heads:                  dw 2           ; 0x7C1A
bdb_hidden_sectors:         dd 0
bdb_large_sectors:          dd 0
ebr_drive_number:           db 0
                            db 0
ebr_signature:              db 0x29
ebr_volume_id:              dd 0x12345678
ebr_volume_label:           db "FERRIX OS  "
ebr_system_id:              db "FAT12   "

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; --- сохранить boot drive для ядра ---
    mov [0x0500], dl

    ; --- геометрия диска от BIOS ---
    push es
    mov ah, 0x08
    int 0x13
    pop es
    jc .geo_done
    and cx, 0x3F                    ; секторов на дорожку
    jz .geo_done
    mov [bdb_sectors_per_track], cx
    xor ax, ax
    mov al, dh
    inc ax                          ; головок
    mov [bdb_heads], ax
.geo_done:

    ; --- текстовый режим 3 явно (часть BIOS/USB-загрузок оставляет графику) ---
    mov ax, 0x0003
    int 0x10

    ; --- расположение тома из BPB ---
    ; fat_lba = reserved; root_lba = reserved + fats*spf; data_lba = root_lba + root_secs
    mov ax, [bdb_sectors_per_fat]
    mov cl, [bdb_fat_count]
    xor ch, ch
    mul cx
    add ax, [bdb_reserved_sectors]
    mov [root_lba], ax
    mov bx, [bdb_dir_entries_count]
    mov cx, bx
    shr bx, 4                       ; записей * 32 / 512
    mov [root_secs], bx
    add ax, bx
    mov [data_lba], ax
    ; число кластеров -> FAT12/FAT16
    mov dx, [bdb_total_sectors]
    test dx, dx
    jnz .ts16
    mov dx, [bdb_large_sectors]     ; младшее слово (том <= 32 МБ)
.ts16:
    sub dx, ax
    cmp dx, 4085
    jb .f12
    mov byte [fat16], 1
.f12:

    ; --- корневой каталог -> ROOT_SEG:0 ---
    mov ax, ROOT_SEG
    mov es, ax
    xor bx, bx
    mov ax, [root_lba]
    push cx
    mov cx, [root_secs]
    call read_sectors
    pop cx

    ; --- найти KERNEL.SYS (CX записей) ---
    xor di, di
.find:
    push cx
    push di
    mov si, kname
    mov cx, 11
    repe cmpsb
    pop di
    pop cx
    je .found
    add di, 32
    loop .find
    mov si, msg_nf
    call print
    jmp $

.found:
    mov ax, [es:di + 26]            ; первый кластер
    mov [cluster], ax
    mov ax, KERN_SEG
    mov es, ax
    xor bx, bx

.load:
    mov ax, [cluster]
    cmp ax, 0xFFF8                  ; FAT12-метки конца приводятся к FFF8+ ниже
    jae .run
    sub ax, 2
    add ax, [data_lba]              ; LBA = data_lba + кластер - 2 (1 сектор на кластер)
    mov cx, 1
    call read_sectors
    add bx, 512
    jnc .no_bump
    mov ax, es
    add ax, 0x1000
    mov es, ax
.no_bump:
    ; --- следующий кластер: смещение записи в FAT ---
    mov si, [cluster]
    cmp byte [fat16], 0
    je .off12
    shl si, 1                       ; FAT16: кластер * 2
    jmp .off_ok
.off12:
    mov ax, si
    shr ax, 1
    add si, ax                      ; FAT12: кластер * 3 / 2
.off_ok:
    ; сектор FAT = reserved + (off >> 9); читаем 2 сектора в FAT_SEG
    push es
    push bx
    mov ax, si
    mov cl, 9
    shr ax, cl
    add ax, [bdb_reserved_sectors]
    push ax
    mov ax, FAT_SEG
    mov es, ax
    pop ax
    xor bx, bx
    mov cx, 2
    call read_sectors
    and si, 511
    mov ax, [es:si]
    pop bx
    pop es
    cmp byte [fat16], 0
    jne .store
    test word [cluster], 1
    jz .even
    shr ax, 4
    jmp .chk
.even:
    and ax, 0x0FFF
.chk:
    cmp ax, 0x0FF8
    jb .store
    or ax, 0xF000                   ; конец цепочки FAT12 -> как у FAT16
.store:
    mov [cluster], ax
    jmp .load

.run:
    ; --- старт ядра ---
    jmp KERN_SEG:0x0000

; Чтение CX секторов начиная с LBA=AX в ES:BX (по одному, с 3 повторами)
read_sectors:
    pusha
.next:
    push ax
    push cx
    xor dx, dx
    div word [bdb_sectors_per_track]    ; AX = LBA / spt, DX = сектор-1
    mov cl, dl
    inc cl
    xor dx, dx
    div word [bdb_heads]                ; AX = цилиндр, DX = головка
    mov dh, dl
    mov ch, al
    shl ah, 6                           ; биты 8-9 цилиндра (для HDD-эмуляции)
    or cl, ah
    mov dl, [0x0500]
    mov bp, 3
.retry:
    mov ax, 0x0201
    int 0x13
    jnc .ok
    xor ah, ah                          ; сброс контроллера и повтор
    int 0x13
    dec bp
    jnz .retry
    mov si, msg_err
    call print
    jmp $
.ok:
    pop cx
    pop ax
    inc ax
    add bx, 512
    loop .next
    popa
    ret

print:                                  ; регистры не сохраняет (вызывается до загрузки и перед остановом)
    mov ah, 0x0e
    xor bh, bh
.ps_loop:
    lodsb
    test al, al
    jz .ps_done
    int 0x10
    jmp .ps_loop
.ps_done:
    ret

cluster:    dw 0
root_lba:   dw 0
root_secs:  dw 0
data_lba:   dw 0
fat16:      db 0
kname:      db "KERNEL  SYS"
msg_nf:     db "No KERNEL.SYS", 0
msg_err:    db "Disk error", 0

times 510-($-$$) db 0
dw 0xaa55
