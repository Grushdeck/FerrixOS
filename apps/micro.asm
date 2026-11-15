;======================================
; File name: apps/micro.asm
; Project: FERRIX-OS
; Description: micro — эмулятор CHIP-8
;======================================
; Запуск: micro FILE.CH8 [-s N] [-c X] [-q] [-l] [-w]
;   -s N   скорость: инструкций на тик таймера (18.2 Гц), по умолчанию 40 (~730 инстр/с)
;   -c X   цвет пикселей (шестнадцатеричная цифра 0-F), по умолчанию A (ярко-зелёный)
;   -q     «сдвиговая» особенность: 8xy6/8xyE сдвигают VX, а не VY (нужна части игр)
;   -l     Fx55/Fx65 не изменяют I (поведение SCHIP)
;   -w     спрайты заворачиваются по краям экрана вместо обрезки
; Клавиатура CHIP-8 (16 клавиш):  1 2 3 C      1 2 3 4
;                                 4 5 6 D  ->  Q W E R
;                                 7 8 9 E      A S D F
;                                 A 0 B F      Z X C V
; Esc — выход, F5 — сброс, Space — пауза. Экран 64x32 рисуется полублоками в текстовом режиме
; (через сегмент из [0010h] — работает и в окне gui).
; Сборка: nasm -f bin -I. apps/micro.asm -o MICRO.FAP

%include "fapi.inc"

    FAPI_HEADER

SCR_X    equ 8                      ; левый столбец поля 64x16
SCR_Y    equ 4                      ; верхняя строка
KEYHOLD  equ 4                      ; тиков, пока нажатая клавиша считается удержанной

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    ; --- параметры ---
    mov word [speed], 40
    mov byte [color], 0x0A
    mov byte [q_shift], 0
    mov byte [q_load], 0
    mov byte [q_wrap], 0
    mov byte [rompath], 0
    mov si, 0x80
.arg:
    call skip_sp
    cmp byte [si], 0
    je .args_done
    cmp byte [si], '-'
    jne .file
    inc si
    lodsb
    cmp al, 's'
    je .opt_s
    cmp al, 'S'
    je .opt_s
    cmp al, 'c'
    je .opt_c
    cmp al, 'C'
    je .opt_c
    cmp al, 'q'
    je .opt_q
    cmp al, 'Q'
    je .opt_q
    cmp al, 'l'
    je .opt_l
    cmp al, 'L'
    je .opt_l
    cmp al, 'w'
    je .opt_w
    cmp al, 'W'
    je .opt_w
    jmp usage
.opt_s:
    call skip_sp
    call parse_dec                  ; -> AX
    test ax, ax
    jz usage
    mov [speed], ax
    jmp .arg
.opt_c:
    call skip_sp
    lodsb
    call hex_digit
    jc usage
    mov [color], al
    jmp .arg
.opt_q:
    mov byte [q_shift], 1
    jmp .arg
.opt_l:
    mov byte [q_load], 1
    jmp .arg
.opt_w:
    mov byte [q_wrap], 1
    jmp .arg
.file:
    mov di, rompath
.fc:
    lodsb
    cmp al, ' '
    je .fe
    test al, al
    jz .fe
    stosb
    jmp .fc
.fe:
    mov byte [di], 0
    dec si
    jmp .arg
.args_done:
    cmp byte [rompath], 0
    je usage
    ; --- загрузка ROM ---
    push ds
    pop es
    mov si, rompath
    mov di, c8mem + 0x200
    mov cx, 4096 - 0x200
    FAPI FAPI_READFILE
    jc .nofile
    mov [romlen], ax
    ; шрифт
    mov si, font
    mov di, c8mem + 0x50
    mov cx, 80
    rep movsb
    call reset_cpu
    call draw_frame
    jmp run

.nofile:
    FAPI_PRINT msg_nofile
    FAPI_QUIT
usage:
    FAPI_PRINT msg_usage
    FAPI_QUIT

; сброс процессора и экрана
reset_cpu:
    mov word [pc], 0x200
    mov word [ireg], 0
    mov byte [sp8], 0
    mov byte [dtim], 0
    mov byte [stim], 0
    mov byte [paused], 0
    push ds
    pop es
    mov di, vregs
    mov cx, 16
    xor al, al
    rep stosb
    mov di, keyt
    mov cx, 16
    rep stosb
    mov di, disp
    mov cx, 2048
    rep stosb
    mov byte [dirty], 1
    ret

;---------------------------------------------------------------- главный цикл
run:
    FAPI FAPI_TICKS
    mov [last_tick], ax
.frame:
    ; --- клавиатура ---
.keys:
    FAPI FAPI_KEYHIT
    jz .nokey
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    cmp ah, 0x3F                    ; F5
    je .reset
    cmp al, ' '
    je .pause
    call map_key                    ; -> AL индекс 0..15 или CF
    jc .keys
    mov bx, ax
    mov byte [keyt + bx], KEYHOLD
    jmp .keys
.reset:
    call reset_cpu
    call draw_frame
    jmp .keys
.pause:
    xor byte [paused], 1
    call draw_status
    jmp .keys
.nokey:
    ; --- инструкции ---
    cmp byte [paused], 0
    jne .wait_tick
    mov cx, [speed]
.exec:
    push cx
    call step
    pop cx
    loop .exec
    ; --- экран ---
    cmp byte [dirty], 0
    je .wait_tick
    call render
    mov byte [dirty], 0
.wait_tick:
    FAPI FAPI_TICKS
    cmp ax, [last_tick]
    jne .tick
    hlt
    jmp .keys
.tick:
    mov [last_tick], ax
    ; таймеры: 60 Гц ≈ 3.3 на тик
    mov al, [dtim]
    sub al, 3
    jnc .dt_ok
    xor al, al
.dt_ok:
    mov [dtim], al
    mov al, [stim]
    test al, al
    jz .st_ok
    sub al, 3
    jnc .st_set
    xor al, al
.st_set:
    mov [stim], al
.st_ok:
    ; удержание клавиш
    mov cx, 16
    mov bx, keyt
.kd:
    cmp byte [bx], 0
    je .kn
    dec byte [bx]
.kn:
    inc bx
    loop .kd
    jmp .frame

quit:
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

;---------------------------------------------------------------- одна инструкция
step:
    mov si, [pc]
    and si, 0x0FFF
    mov ah, [c8mem + si]
    mov al, [c8mem + si + 1]
    add word [pc], 2
    mov [op], ax
    ; x, y, n, kk, nnn
    mov bl, ah
    and bl, 0x0F
    mov [vx], bl
    mov bl, al
    shr bl, 4
    mov [vy], bl
    mov bl, al
    and bl, 0x0F
    mov [n4], bl
    mov [kk], al
    mov bx, ax
    and bx, 0x0FFF
    mov [nnn], bx
    mov bl, ah
    shr bl, 4
    xor bh, bh
    shl bx, 1
    jmp [optab + bx]

optab:  dw op0, op1, op2, op3, op4, op5, op6, op7, op8, op9, opA, opB, opC, opD, opE, opF

op0:
    cmp ax, 0x00E0
    jne .ee
    push es
    push ds
    pop es
    mov di, disp
    mov cx, 2048
    xor al, al
    rep stosb
    pop es
    mov byte [dirty], 1
    ret
.ee:
    cmp ax, 0x00EE
    jne .r
    mov bl, [sp8]
    test bl, bl
    jz .r
    dec bl
    mov [sp8], bl
    xor bh, bh
    shl bx, 1
    mov ax, [stack8 + bx]
    mov [pc], ax
.r: ret

op1:
    mov ax, [nnn]
    mov [pc], ax
    ret

op2:
    mov bl, [sp8]
    cmp bl, 16
    jae .r
    xor bh, bh
    shl bx, 1
    mov ax, [pc]
    mov [stack8 + bx], ax
    inc byte [sp8]
    mov ax, [nnn]
    mov [pc], ax
.r: ret

op3:
    call getvx
    cmp al, [kk]
    jne .r
    add word [pc], 2
.r: ret

op4:
    call getvx
    cmp al, [kk]
    je .r
    add word [pc], 2
.r: ret

op5:
    call getvx
    mov ah, al
    call getvy
    cmp al, ah
    jne .r
    add word [pc], 2
.r: ret

op6:
    mov al, [kk]
    call setvx
    ret

op7:
    call getvx
    add al, [kk]
    call setvx
    ret

op8:
    call getvy
    mov ah, al                      ; AH = VY
    call getvx                      ; AL = VX
    mov bl, [n4]
    cmp bl, 0
    je .mov
    cmp bl, 1
    je .or
    cmp bl, 2
    je .and
    cmp bl, 3
    je .xor
    cmp bl, 4
    je .add
    cmp bl, 5
    je .sub
    cmp bl, 6
    je .shr
    cmp bl, 7
    je .subn
    cmp bl, 0xE
    je .shl
    ret
.mov:
    mov al, ah
    jmp setvx
.or:
    or al, ah
    jmp .flags_reset
.and:
    and al, ah
    jmp .flags_reset
.xor:
    xor al, ah
.flags_reset:
    call setvx
    mov byte [vregs + 15], 0
    ret
.add:
    add al, ah
    mov cl, 0
    adc cl, 0
    call setvx
    mov [vregs + 15], cl
    ret
.sub:
    sub al, ah
    mov cl, 1
    sbb cl, 0
    call setvx
    mov [vregs + 15], cl
    ret
.subn:
    sub ah, al
    mov cl, 1
    sbb cl, 0
    mov al, ah
    call setvx
    mov [vregs + 15], cl
    ret
.shr:
    cmp byte [q_shift], 0
    jne .shr_x
    mov al, ah                      ; VX = VY >> 1
.shr_x:
    shr al, 1
    mov cl, 0
    adc cl, 0
    call setvx
    mov [vregs + 15], cl
    ret
.shl:
    cmp byte [q_shift], 0
    jne .shl_x
    mov al, ah
.shl_x:
    shl al, 1
    mov cl, 0
    adc cl, 0
    call setvx
    mov [vregs + 15], cl
    ret

op9:
    call getvx
    mov ah, al
    call getvy
    cmp al, ah
    je .r
    add word [pc], 2
.r: ret

opA:
    mov ax, [nnn]
    mov [ireg], ax
    ret

opB:
    mov al, [vregs]
    xor ah, ah
    add ax, [nnn]
    mov [pc], ax
    ret

opC:
    FAPI FAPI_RAND
    and al, [kk]
    call setvx
    ret

; Dxyn — спрайт
opD:
    mov byte [vregs + 15], 0
    call getvx
    and al, 63
    mov [sx], al
    call getvy
    and al, 31
    mov [sy], al
    mov cl, [n4]
    xor ch, ch
    jcxz .done
    mov si, [ireg]
    and si, 0x0FFF
    add si, c8mem
    xor dh, dh                      ; строка спрайта
.row:
    mov al, [sy]
    add al, dh
    cmp al, 32
    jb .row_ok
    cmp byte [q_wrap], 0
    je .next_row
    and al, 31
.row_ok:
    mov [cy], al
    mov bl, [si]                    ; байт спрайта
    xor dl, dl                      ; бит 0..7
.bit:
    test bl, 0x80
    jz .nb
    mov al, [sx]
    add al, dl
    cmp al, 64
    jb .col_ok
    cmp byte [q_wrap], 0
    je .nb
    and al, 63
.col_ok:
    ; адрес = cy*64 + al
    push bx
    mov bl, al
    mov al, [cy]
    xor ah, ah
    shl ax, 6
    xor bh, bh
    add bx, ax
    cmp byte [disp + bx], 0
    je .set
    mov byte [disp + bx], 0
    mov byte [vregs + 15], 1
    pop bx
    jmp .nb
.set:
    mov byte [disp + bx], 1
    pop bx
.nb:
    shl bl, 1
    inc dl
    cmp dl, 8
    jb .bit
.next_row:
    inc si
    inc dh
    loop .row
.done:
    mov byte [dirty], 1
    ret

opE:
    call getvx
    and al, 15
    mov bl, al
    xor bh, bh
    mov al, [kk]
    cmp al, 0x9E
    je .skp
    cmp al, 0xA1
    jne .r
    cmp byte [keyt + bx], 0
    jne .r
    add word [pc], 2
    ret
.skp:
    cmp byte [keyt + bx], 0
    je .r
    add word [pc], 2
.r: ret

opF:
    mov al, [kk]
    cmp al, 0x07
    je .f07
    cmp al, 0x0A
    je .f0a
    cmp al, 0x15
    je .f15
    cmp al, 0x18
    je .f18
    cmp al, 0x1E
    je .f1e
    cmp al, 0x29
    je .f29
    cmp al, 0x33
    je .f33
    cmp al, 0x55
    je .f55
    cmp al, 0x65
    je .f65
    ret
.f07:
    mov al, [dtim]
    jmp setvx
.f0a:
    ; ждать клавишу
    call render
    mov byte [dirty], 0
.f0a_l:
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    call map_key
    jc .f0a_l
    mov bx, ax
    mov byte [keyt + bx], KEYHOLD
    jmp setvx
.f15:
    call getvx
    mov [dtim], al
    ret
.f18:
    call getvx
    mov [stim], al
    test al, al
    jz .r
    FAPI FAPI_BEEP
.r: ret
.f1e:
    call getvx
    xor ah, ah
    add [ireg], ax
    ret
.f29:
    call getvx
    and al, 15
    mov ah, 5
    mul ah
    add ax, 0x50
    mov [ireg], ax
    ret
.f33:
    call getvx
    mov bx, [ireg]
    and bx, 0x0FFF
    xor ah, ah
    mov cl, 100
    div cl                          ; AL сотни, AH остаток
    mov [c8mem + bx], al
    mov al, ah
    xor ah, ah
    mov cl, 10
    div cl
    mov [c8mem + bx + 1], al
    mov [c8mem + bx + 2], ah
    ret
.f55:
    mov cl, [vx]
    xor ch, ch
    inc cx
    mov si, vregs
    mov di, [ireg]
    and di, 0x0FFF
    add di, c8mem
    push es
    push ds
    pop es
    rep movsb
    pop es
    cmp byte [q_load], 0
    jne .r
    mov cl, [vx]
    inc cx
    add [ireg], cx
    ret
.f65:
    mov cl, [vx]
    xor ch, ch
    inc cx
    mov si, [ireg]
    and si, 0x0FFF
    add si, c8mem
    mov di, vregs
    push es
    push ds
    pop es
    rep movsb
    pop es
    cmp byte [q_load], 0
    jne .r2
    mov cl, [vx]
    inc cx
    add [ireg], cx
.r2: ret

getvx:
    push bx
    mov bl, [vx]
    xor bh, bh
    mov al, [vregs + bx]
    pop bx
    ret
getvy:
    push bx
    mov bl, [vy]
    xor bh, bh
    mov al, [vregs + bx]
    pop bx
    ret
setvx:
    push bx
    mov bl, [vx]
    xor bh, bh
    mov [vregs + bx], al
    pop bx
    ret

; клавиша AL (ASCII) -> AX индекс CHIP-8; CF=1 не клавиатура
map_key:
    cmp al, 'A'
    jb .k
    cmp al, 'Z'
    ja .k
    add al, 0x20
.k:
    push si
    mov si, keymap
    xor cx, cx
.l:
    cmp al, [si]
    je .f
    inc si
    inc cx
    cmp cx, 16
    jb .l
    pop si
    stc
    ret
.f:
    pop si
    mov ax, cx
    clc
    ret

;---------------------------------------------------------------- экран
; disp -> текст полублоками в видеосегмент [0010h]
render:
    push es
    mov es, [0x10]
    mov si, disp
    mov di, SCR_Y * 160 + SCR_X * 2
    mov ah, [color]
    mov dx, 16                      ; строк текста
.row:
    mov cx, 64
.col:
    mov bl, [si]                    ; верхний пиксель
    mov bh, [si + 64]               ; нижний
    shl bh, 1
    or bl, bh
    xor bh, bh
    mov al, [blocks + bx]
    stosw
    inc si
    loop .col
    add si, 64                      ; пропустить нижнюю строку пары
    add di, 160 - 64 * 2
    dec dx
    jnz .row
    pop es
    ret

draw_frame:
    FAPI FAPI_CLS
    ; рамка
    mov dh, SCR_Y - 1
    mov dl, SCR_X - 1
    mov ch, 18
    mov cl, 66
    mov al, 0xB0
    mov bl, 0x08
    FAPI FAPI_FILLRECT
    call draw_status
    mov byte [dirty], 1
    ret

draw_status:
    mov dh, 22
    xor dl, dl
    mov ch, 2
    mov cl, 80
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    FAPI_PUTSAT 22, 1, msg_title, 0x0F
    FAPI_PUTSAT 22, 8, rompath, 0x0B
    FAPI_PUTSAT 23, 1, msg_keys, 0x07
    cmp byte [paused], 0
    je .r
    FAPI_PUTSAT 22, 60, msg_paused, 0x4F
.r: ret

;---------------------------------------------------------------- утилиты
skip_sp:
    cmp byte [si], ' '
    jne .r
    inc si
    jmp skip_sp
.r: ret

parse_dec:
    xor ax, ax
.l:
    mov bl, [si]
    sub bl, '0'
    jc .d
    cmp bl, 9
    ja .d
    xor bh, bh
    mov cx, 10
    mul cx
    add ax, bx
    inc si
    jmp .l
.d: ret

hex_digit:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .a
    sub al, '0'
    clc
    ret
.a:
    or al, 0x20
    cmp al, 'a'
    jb .bad
    cmp al, 'f'
    ja .bad
    sub al, 'a' - 10
    clc
    ret
.bad:
    stc
    ret

;---------------------------------------------------------------- данные
msg_usage   db "micro - CHIP-8 emulator", 13, 10
            db "Usage: micro FILE.CH8 [-s N] [-c X] [-q] [-l] [-w]", 13, 10
            db "  -s N  speed (instructions per timer tick, default 40)", 13, 10
            db "  -c X  pixel color 0-F        -q shift quirk (VX)", 13, 10
            db "  -l    Fx55/Fx65 keep I       -w wrap sprites", 13, 10
            db "Keys: 1234 QWER ASDF ZXCV = CHIP-8 keypad, Esc exit, F5 reset, Space pause", 13, 10, 0
msg_nofile  db "micro: cannot read ROM", 13, 10, 0
msg_title   db "micro:", 0
msg_keys    db "Keypad: 1234/QWER/ASDF/ZXCV   Esc exit   F5 reset   Space pause", 0
msg_paused  db " PAUSED ", 0
keymap      db "x123qweasdzc4rfv"
blocks      db ' ', 0xDF, 0xDC, 0xDB
font:
    db 0xF0,0x90,0x90,0x90,0xF0, 0x20,0x60,0x20,0x20,0x70, 0xF0,0x10,0xF0,0x80,0xF0, 0xF0,0x10,0xF0,0x10,0xF0
    db 0x90,0x90,0xF0,0x10,0x10, 0xF0,0x80,0xF0,0x10,0xF0, 0xF0,0x80,0xF0,0x90,0xF0, 0xF0,0x10,0x20,0x40,0x40
    db 0xF0,0x90,0xF0,0x90,0xF0, 0xF0,0x90,0xF0,0x10,0xF0, 0xF0,0x90,0xF0,0x90,0x90, 0xE0,0x90,0xE0,0x90,0xE0
    db 0xF0,0x80,0x80,0x80,0xF0, 0xE0,0x90,0x90,0x90,0xE0, 0xF0,0x80,0xF0,0x80,0xF0, 0xF0,0x80,0xF0,0x80,0x80

speed       dw 40
color       db 0x0A
q_shift     db 0
q_load      db 0
q_wrap      db 0
paused      db 0
dirty       db 0
romlen      dw 0
last_tick   dw 0
pc          dw 0
ireg        dw 0
sp8         db 0
dtim        db 0
stim        db 0
op          dw 0
vx          db 0
vy          db 0
n4          db 0
kk          db 0
nnn         dw 0
sx          db 0
sy          db 0
cy          db 0
vregs       times 16 db 0
stack8      times 16 dw 0
keyt        times 16 db 0
rompath     times 80 db 0
disp        times 2048 db 0
c8mem       times 4096 db 0
