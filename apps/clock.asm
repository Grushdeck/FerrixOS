;======================================
; File name: apps/clock.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: clock — аналоговые часы на весь экран + большие цифровые часы и дата
;======================================
; Esc / любая клавиша — выход. Рисует в свой буфер и копирует кадр целиком (без мерцания).

%include "fapi.inc"

    FAPI_HEADER

CX0      equ 40                     ; центр циферблата (столбец)
CY0      equ 8                      ; центр (строка)
RY       equ 8                      ; радиус в строках
RX       equ 17                     ; радиус в столбцах (знакоместо ~ 1:2)
TROW     equ 18                     ; строка больших цифр
DROW     equ 24                     ; строка даты
C_RING   equ 0x08
C_NUM    equ 0x0F
C_HOUR   equ 0x0F
C_MIN    equ 0x0B
C_SEC    equ 0x0C
C_CENTER equ 0x0E
C_TIME   equ 0x0B
C_DATE   equ 0x07

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    FAPI FAPI_KBFLUSH
    mov byte [last_s], 0xFF
.loop:
    FAPI FAPI_KEYHIT
    jnz .quit
    FAPI FAPI_LOCALTIME
    cmp dh, [last_s]
    je .idle
    mov [last_s], dh
    mov [cur_h], ch
    mov [cur_m], cl
    mov [cur_s], dh
    call draw_frame
    call blit
.idle:
    hlt
    jmp .loop
.quit:
    FAPI FAPI_GETKEY
    FAPI FAPI_CLS
    FAPI FAPI_UIREDRAW
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI_QUIT

; ---------- кадр ----------
draw_frame:
    ; очистить буфер
    mov di, buf
    mov ax, 0x0720
    mov cx, 2000
    rep stosw
    ; кольцо: 60 минутных делений (точки)
    xor si, si
.ring:
    mov ax, si
    mov bx, RY
    mov dx, RX
    call polar                      ; -> DH строка, DL столбец
    mov al, 0xF9
    mov bl, C_RING
    call bput
    inc si
    cmp si, 60
    jb .ring
    ; цифры 1..12 поверх кольца (часовые позиции = 5*k)
    mov si, 1
.nums:
    mov ax, si
    mov cl, 5
    mul cl                          ; позиция
    cmp ax, 60
    jb .pos_ok
    xor ax, ax                      ; 12 -> позиция 0
.pos_ok:
    mov bx, RY
    mov dx, RX
    call polar
    ; текст числа
    push si
    mov ax, si
    mov di, numbuf
    cmp ax, 10
    jb .one
    mov byte [di], '1'
    inc di
    sub ax, 10
    dec dl                          ; двузначное — сдвинуть влево
.one:
    add al, '0'
    mov [di], al
    mov byte [di + 1], 0
    mov si, numbuf
    mov bl, C_NUM
    call bputs
    pop si
    inc si
    cmp si, 12
    jbe .nums
    ; стрелки: часовая = (h%12)*5 + m/12
    mov al, [cur_h]
    xor ah, ah
    mov cl, 12
    div cl
    mov al, ah
    mov cl, 5
    mul cl
    push ax
    mov al, [cur_m]
    xor ah, ah
    mov cl, 12
    div cl
    pop cx
    add al, cl
    xor ah, ah
    mov bx, RY - 4
    mov dx, RX - 8
    mov cl, 0xDB
    mov ch, C_HOUR
    call hand
    mov al, [cur_m]
    xor ah, ah
    mov bx, RY - 2
    mov dx, RX - 3
    mov cl, 0xB2
    mov ch, C_MIN
    call hand
    mov al, [cur_s]
    xor ah, ah
    mov bx, RY - 1
    mov dx, RX - 2
    mov cl, 0xF9
    mov ch, C_SEC
    call hand
    mov dh, CY0
    mov dl, CX0
    mov al, 0x09
    mov bl, C_CENTER
    call bput
    ; большие цифры HH:MM:SS (ширина 6*6 + 2*3 = 42)
    mov dl, (80 - 42) / 2
    mov al, [cur_h]
    call big2
    call bigcolon
    mov al, [cur_m]
    call big2
    call bigcolon
    mov al, [cur_s]
    call big2
    ; дата: "S A T U R D A Y ,  1 5  N O V E M B E R  2 0 2 5"
    FAPI FAPI_DATE
    mov [cur_y], cx
    mov [cur_mo], dh
    mov [cur_d], dl
    mov [cur_dow], al
    mov di, datebuf
    mov al, [cur_dow]
    mov bl, 10
    mul bl
    mov si, dows
    add si, ax
    call spaced
    mov al, ','
    stosb
    mov al, ' '
    stosb
    mov al, ' '
    stosb
    mov al, [cur_d]
    call spaced_num2
    mov al, ' '
    stosb
    mov al, [cur_mo]
    dec al
    mov bl, 10
    mul bl
    mov si, months
    add si, ax
    call spaced
    mov al, ' '
    stosb
    mov ax, [cur_y]
    mov cx, 100
    xor dx, dx
    div cx
    push dx
    call spaced_num2
    pop ax
    call spaced_num2
    dec di                          ; убрать последний пробел
    mov byte [di], 0
    ; центрировать
    mov ax, di
    sub ax, datebuf
    mov cx, 80
    sub cx, ax
    shr cx, 1
    mov dh, DROW
    mov dl, cl
    mov si, datebuf
    mov bl, C_DATE
    call bputs
    ret

; имя из таблицы (10 байт, пробелами дополнено) -> DI буквами через пробел
spaced:
    mov cx, 10
.sp:
    lodsb
    cmp al, ' '
    je .done
    stosb
    mov al, ' '
    stosb
    loop .sp
.done:
    ret

; AL = число 0..99 -> "D D " в DI
spaced_num2:
    xor ah, ah
    mov bl, 10
    div bl
    add al, '0'
    stosb
    mov al, ' '
    stosb
    mov al, ah
    add al, '0'
    stosb
    mov al, ' '
    stosb
    ret

; AX = позиция 0..59 (0 = вверх), BX = радиус строк, DX = радиус столбцов
; -> DH строка, DL столбец
polar:
    push ax
    push bx
    push cx
    push si
    mov si, ax
    shl si, 1
    push dx
    mov ax, [sin_t + si]
    imul dx                         ; sin * rx
    mov cx, 256
    idiv cx
    add ax, CX0
    mov cl, al                      ; столбец
    mov ax, [cos_t + si]
    imul bx                         ; cos * ry
    push cx
    mov cx, 256
    idiv cx
    pop cx
    neg ax
    add ax, CY0
    mov dh, al
    mov dl, cl
    pop ax                          ; (старый dx — не нужен)
    pop si
    pop cx
    pop bx
    pop ax
    ret

; стрелка: AX = позиция, BX = длина строк, DX = длина столбцов, CL символ, CH атрибут
hand:
    push cx
    call polar                      ; DH,DL = конец
    pop cx
    ; шаги от центра к концу: 24 шага
    mov al, dh
    sub al, CY0
    cbw
    mov [h_ey], ax
    mov al, dl
    sub al, CX0
    cbw
    mov [h_ex], ax
    mov [h_ch], cx
    mov word [h_i], 1
.step:
    mov ax, [h_ex]
    imul word [h_i]
    mov bx, 24
    idiv bx
    add ax, CX0
    mov [h_x], al
    mov ax, [h_ey]
    imul word [h_i]
    mov bx, 24
    idiv bx
    add ax, CY0
    mov dh, al
    mov dl, [h_x]
    mov cx, [h_ch]
    mov al, cl
    mov bl, ch
    call bput
    inc word [h_i]
    cmp word [h_i], 24
    jbe .step
    ret

; AL = число 0..99 -> две большие цифры с позиции столбца DL (строка TROW); DL += 12
big2:
    xor ah, ah
    mov bl, 10
    div bl
    push ax
    call bigdigit
    pop ax
    mov al, ah
    call bigdigit
    ret

; AL = цифра, DL = столбец; рисует 5x5 блоками и сдвигает DL на 6
bigdigit:
    push ax
    push bx
    push cx
    push si
    push dx
    xor ah, ah
    mov si, ax
    shl si, 2
    add si, ax                      ; *5
    add si, font5
    mov dh, TROW
    mov cx, 5
.row:
    push cx
    push dx
    mov ah, [si]
    shl ah, 3                       ; 5 бит -> старшие
    mov cx, 5
.col:
    shl ah, 1
    jnc .skip
    mov al, 0xDB
    mov bl, C_TIME
    call bput
.skip:
    inc dl
    loop .col
    pop dx
    inc dh
    inc si
    pop cx
    loop .row
    pop dx
    add dl, 6
    pop si
    pop cx
    pop bx
    pop ax
    ret

; двоеточие шириной 3 (точки в строках 1 и 3)
bigcolon:
    push ax
    push bx
    push dx
    mov dh, TROW + 1
    mov al, 0xDB
    mov bl, C_TIME
    call bput
    mov dh, TROW + 3
    call bput
    pop dx
    add dl, 3
    pop bx
    pop ax
    ret

; ---------- буфер ----------
; bput: DH строка, DL столбец, AL символ, BL атрибут -> buf
bput:
    push ax
    push bx
    push di
    cmp dh, 25
    jae .out
    cmp dl, 80
    jae .out
    mov ah, bl
    push ax
    mov al, dh
    mov ah, 80
    mul ah
    xor bh, bh
    mov bl, dl
    add ax, bx
    shl ax, 1
    mov di, ax
    pop ax
    mov [buf + di], ax
.out:
    pop di
    pop bx
    pop ax
    ret

; bputs: DH,DL позиция, SI строка, BL атрибут
bputs:
    push ax
    push dx
    push si
.l:
    lodsb
    test al, al
    jz .d
    call bput
    inc dl
    jmp .l
.d:
    pop si
    pop dx
    pop ax
    ret

blit:
    push es
    mov es, [0x0010]                ; видеосегмент (под gui — экран окна)
    mov si, buf
    xor di, di
    mov cx, 2000
    rep movsw
    pop es
    ret

; ---------- данные ----------
sin_t:
    dw 0, 27, 53, 79, 104, 128, 150, 171, 190, 207, 222, 234
    dw 243, 250, 255, 256, 255, 250, 243, 234, 222, 207, 190, 171
    dw 150, 128, 104, 79, 53, 27, 0, -27, -53, -79, -104, -128
    dw -150, -171, -190, -207, -222, -234, -243, -250, -255, -256, -255, -250
    dw -243, -234, -222, -207, -190, -171, -150, -128, -104, -79, -53, -27
cos_t:
    dw 256, 255, 250, 243, 234, 222, 207, 190, 171, 150, 128, 104
    dw 79, 53, 27, 0, -27, -53, -79, -104, -128, -150, -171, -190
    dw -207, -222, -234, -243, -250, -255, -256, -255, -250, -243, -234, -222
    dw -207, -190, -171, -150, -128, -104, -79, -53, -27, 0, 27, 53
    dw 79, 104, 128, 150, 171, 190, 207, 222, 234, 243, 250, 255
font5:
    db 0b01110, 0b10001, 0b10001, 0b10001, 0b01110   ; 0
    db 0b00100, 0b01100, 0b00100, 0b00100, 0b01110   ; 1
    db 0b11110, 0b00001, 0b01110, 0b10000, 0b11111   ; 2
    db 0b11110, 0b00001, 0b01110, 0b00001, 0b11110   ; 3
    db 0b10001, 0b10001, 0b11111, 0b00001, 0b00001   ; 4
    db 0b11111, 0b10000, 0b11110, 0b00001, 0b11110   ; 5
    db 0b01111, 0b10000, 0b11110, 0b10001, 0b01110   ; 6
    db 0b11111, 0b00001, 0b00010, 0b00100, 0b00100   ; 7
    db 0b01110, 0b10001, 0b01110, 0b10001, 0b01110   ; 8
    db 0b01110, 0b10001, 0b01111, 0b00001, 0b11110   ; 9

dows    db "SUNDAY    ", "MONDAY    ", "TUESDAY   ", "WEDNESDAY ", "THURSDAY  ", "FRIDAY    ", "SATURDAY  "
months  db "JANUARY   ", "FEBRUARY  ", "MARCH     ", "APRIL     ", "MAY       ", "JUNE      "
        db "JULY      ", "AUGUST    ", "SEPTEMBER ", "OCTOBER   ", "NOVEMBER  ", "DECEMBER  "
last_s  db 0
cur_h   db 0
cur_m   db 0
cur_s   db 0
cur_d   db 0
cur_mo  db 0
cur_dow db 0
cur_y   dw 0
h_ex    dw 0
h_ey    dw 0
h_i     dw 0
h_ch    dw 0
h_x     db 0
numbuf  db 0, 0, 0
datebuf times 96 db 0
buf     times 4000 db 0
