;======================================
; File name: apps/paint.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: paint — текстовый графический редактор с сохранением в BMP (.FAP)
;======================================
; paint [FILE.BMP] — холст 80x23 клеток, 16 цветов.
; Мышь: левая кнопка — рисовать, правая — стирать, клик по палитре — выбрать цвет.
; Клавиши: стрелки, Space — рисовать, Del/BS — стирать, 0-9 a-f — цвет,
;          F2/S — сохранить BMP (8 бит, 320x92, клетка = 4x4 пикселя),
;          C — очистить холст, Esc — выход.
; Если FILE.BMP существует и создан paint'ом (320x92, 8 бит) — он загружается.

%include "fapi.inc"

CW       equ 80                     ; ширина холста (клеток)
CH_      equ 23                     ; высота холста
CTOP     equ 1                      ; первая строка холста на экране
PALROW   equ 24
SCALE    equ 4
BMPW     equ CW * SCALE             ; 320
BMPH     equ CH_ * SCALE            ; 92
HDRSZ    equ 14 + 40 + 1024
BMPSZ    equ HDRSZ + BMPW * BMPH    ; 30518
A_TTL    equ 0x30
A_MSG    equ 0x0E

    FAPI_HEADER

start:
    cld
    ; имя файла из аргументов
    mov byte [fname], 0
    mov si, 0x80
    call skip_sp
    cmp byte [si], 0
    je .noarg
    mov di, fname
    mov cx, 40
.cp:
    lodsb
    cmp al, ' '
    je .cp_end
    test al, al
    jz .cp_end
    stosb
    loop .cp
.cp_end:
    mov byte [di], 0
.noarg:
    ; очистить холст
    push ds
    pop es
    mov di, canvas
    mov cx, CW * CH_
    xor al, al
    rep stosb
    mov byte [color], 15
    mov byte [cur_r], 11
    mov byte [cur_c], 40
    cmp byte [fname], 0
    je .fresh
    call bmp_load                   ; если есть — загрузить
.fresh:
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    call draw_all
main_loop:
    call draw_status
    call place_cursor
.wait:
    FAPI FAPI_KEYHIT
    jnz .key
    call mouse_poll
    jc main_loop
    hlt
    jmp .wait
.key:
    FAPI FAPI_GETKEY
    call handle_key
    jnc main_loop
    ; выход
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

;---------------------------------------------------------------- клавиши
; CF=1 — выход
handle_key:
    cmp al, 27
    je .quit
    cmp al, ' '
    je .draw
    cmp al, 8
    je .erase
    cmp al, 'c'
    je .clear
    cmp al, 'C'
    je .clear
    cmp al, 's'
    je .save
    cmp al, 'S'
    je .save
    cmp ah, 0x3C                    ; F2
    je .save
    cmp ah, 0x48
    je .up
    cmp ah, 0x50
    je .down
    cmp ah, 0x4B
    je .left
    cmp ah, 0x4D
    je .right
    cmp ah, 0x53                    ; Del
    je .erase
    ; цвет 0-9 a-f
    call hex_val
    jc .done
    mov [color], al
    jmp .done
.draw:
    mov al, [color]
    call set_cell
    jmp .done
.erase:
    xor al, al
    call set_cell
    jmp .done
.clear:
    push ds
    pop es
    mov di, canvas
    mov cx, CW * CH_
    xor al, al
    rep stosb
    call draw_canvas
    jmp .done
.save:
    call do_save
    jmp .done
.up:
    cmp byte [cur_r], 0
    je .done
    dec byte [cur_r]
    jmp .done
.down:
    cmp byte [cur_r], CH_ - 1
    jae .done
    inc byte [cur_r]
    jmp .done
.left:
    cmp byte [cur_c], 0
    je .done
    dec byte [cur_c]
    jmp .done
.right:
    cmp byte [cur_c], CW - 1
    jae .done
    inc byte [cur_c]
.done:
    clc
    ret
.quit:
    stc
    ret

; AL = символ -> AL = 0..15, CF=1 если не hex-цифра
hex_val:
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .alpha
    sub al, '0'
    clc
    ret
.alpha:
    or al, 0x20
    cmp al, 'a'
    jb .no
    cmp al, 'f'
    ja .no
    sub al, 'a' - 10
    clc
    ret
.no:
    stc
    ret

; записать цвет AL в клетку курсора и перерисовать её
set_cell:
    push bx
    mov bl, [cur_r]
    mov bh, [cur_c]
    call set_cell_at
    pop bx
    ret
; BL = строка холста, BH = столбец, AL = цвет
set_cell_at:
    pusha
    mov dl, al                      ; цвет
    mov dh, bl                      ; строка
    mov al, bl
    mov ah, CW
    mul ah
    mov cl, bh
    xor ch, ch
    add ax, cx
    mov si, ax
    mov [canvas + si], dl
    mov al, dl
    call cell_attr                  ; AL цвет -> BL атрибут
    mov dl, bh
    add dh, CTOP
    mov al, ' '
    FAPI FAPI_PUTAT
    popa
    ret

; AL = цвет клетки -> BL = атрибут: фон = цвет, текст контрастный
; (аппаратный курсор рисуется цветом текста, поэтому он всегда виден)
cell_attr:
    mov bl, al
    shl bl, 1
    shl bl, 1
    shl bl, 1
    shl bl, 1
    cmp al, 8
    jae .dark
    or bl, 0x0F                     ; на тёмном фоне — белый курсор
.dark:
    ret

;---------------------------------------------------------------- мышь
; CF=1 если было действие
mouse_poll:
    FAPI FAPI_MOUSE
    test ah, ah
    jz .none
    mov [mbtn], al
    test al, 3
    jz .none
    cmp dx, PALROW
    je .pal
    cmp dx, CTOP
    jb .none
    cmp dx, CTOP + CH_ - 1
    ja .none
    ; рисовать/стирать под мышью
    mov bl, dl
    sub bl, CTOP
    mov bh, cl
    mov [cur_r], bl
    mov [cur_c], bh
    mov al, [color]
    test byte [mbtn], 1
    jnz .put
    xor al, al
.put:
    call set_cell_at
    stc
    ret
.pal:
    ; палитра: столбцы 8..8+16*3
    cmp cx, 8
    jb .none
    sub cx, 8
    mov ax, cx
    mov bl, 3
    div bl
    cmp al, 15
    ja .none
    mov [color], al
    stc
    ret
.none:
    clc
    ret

;---------------------------------------------------------------- рисование
draw_all:
    FAPI FAPI_CLS
    ; заголовок
    mov dh, 0
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_TTL
    FAPI FAPI_FILLRECT
    mov si, s_title
    mov dh, 0
    mov dl, 1
    mov bl, A_TTL
    FAPI FAPI_PUTSAT
    call draw_canvas
    ret

draw_canvas:
    push si
    mov si, canvas
    mov dh, CTOP
.row:
    mov dl, 0
.col:
    lodsb
    call cell_attr
    mov al, ' '
    FAPI FAPI_PUTAT
    inc dl
    cmp dl, CW
    jb .col
    inc dh
    cmp dh, CTOP + CH_
    jb .row
    pop si
    ret

; строка состояния: палитра + текущий цвет + имя файла
draw_status:
    mov dh, PALROW
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    mov si, s_color
    mov dh, PALROW
    mov dl, 0
    mov bl, 0x07
    FAPI FAPI_PUTSAT
    ; 16 образцов по 3 клетки, начиная со столбца 8
    xor cx, cx
.sw:
    mov dl, cl
    mov al, cl
    add dl, dl
    add dl, cl                      ; cl*3
    add dl, 8
    mov bl, cl
    shl bl, 1
    shl bl, 1
    shl bl, 1
    shl bl, 1
    or bl, 0x0F
    cmp cl, 15
    jne .fg
    mov bl, 0xF0
.fg:
    ; hex-цифра
    cmp al, 10
    jb .dig
    add al, 'a' - 10 - '0'
.dig:
    add al, '0'
    inc dl
    push cx
    FAPI FAPI_PUTAT
    ; маркер текущего цвета
    mov al, ' '
    cmp cl, [color]
    jne .nm
    mov al, '['
    dec dl
    FAPI FAPI_PUTAT
    mov al, ']'
    add dl, 2
    FAPI FAPI_PUTAT
.nm:
    pop cx
    inc cl
    cmp cl, 16
    jb .sw
    ; имя файла / подсказка
    mov si, fname
    cmp byte [si], 0
    jne .nm2
    mov si, s_noname
.nm2:
    mov dh, PALROW
    mov dl, 58
    mov bl, 0x07
    FAPI FAPI_PUTSAT
    ret

place_cursor:
    mov dh, [cur_r]
    add dh, CTOP
    mov dl, [cur_c]
    FAPI FAPI_SETCUR
    ret

; сообщение SI в строке состояния и пауза
show_msg:
    mov dh, PALROW
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_MSG
    FAPI FAPI_FILLRECT
    mov dh, PALROW
    mov dl, 1
    mov bl, A_MSG
    FAPI FAPI_PUTSAT
    mov cx, 18
    FAPI FAPI_SLEEP
    ret

;---------------------------------------------------------------- сохранение BMP
do_save:
    cmp byte [fname], 0
    jne .have
    ; запросить имя
    mov dh, PALROW
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, 0x70
    FAPI FAPI_FILLRECT
    mov si, s_ask
    mov dh, PALROW
    mov dl, 1
    mov bl, 0x70
    FAPI FAPI_PUTSAT
    mov dh, PALROW
    mov dl, 16
    FAPI FAPI_SETCUR
    mov di, fname
    mov cx, 40
    call read_line
    jc .cancel
    cmp byte [fname], 0
    je .cancel
.have:
    call bmp_build
    mov si, fname
    push ds
    pop es
    mov di, bmpbuf
    mov cx, BMPSZ
    FAPI FAPI_WRITEFILE
    mov si, s_saved
    jnc .msg
    mov si, s_err
.msg:
    call show_msg
    ret
.cancel:
    mov byte [fname], 0
    ret

; ввод строки в DS:DI (CX макс) с эхом в текущей позиции; CF=1 — Esc
read_line:
    push bx
    xor bx, bx
.rl:
    FAPI FAPI_GETKEY
    cmp al, 13
    je .done
    cmp al, 27
    je .esc
    cmp al, 8
    je .bs
    cmp al, ' '
    jbe .rl
    cmp bx, cx
    jae .rl
    cmp al, 'a'
    jb .st
    cmp al, 'z'
    ja .st
    sub al, 0x20
.st:
    mov [di + bx], al
    inc bx
    FAPI FAPI_PUTC
    jmp .rl
.bs:
    test bx, bx
    jz .rl
    dec bx
    mov al, 8
    FAPI FAPI_PUTC
    mov al, ' '
    FAPI FAPI_PUTC
    mov al, 8
    FAPI FAPI_PUTC
    jmp .rl
.done:
    mov byte [di + bx], 0
    pop bx
    clc
    ret
.esc:
    mov byte [di], 0
    pop bx
    stc
    ret

; собрать BMP (8 бит, 320x92, палитра 256 записей) в bmpbuf
bmp_build:
    push ds
    pop es
    mov di, bmpbuf
    ; заголовок
    mov si, bmp_hdr
    mov cx, 54
    rep movsb
    ; палитра: 16 цветов VGA (B,G,R,0), остальные нули
    mov si, vga_pal
    mov cx, 16 * 4
    rep movsb
    mov cx, 240 * 4
    xor al, al
    rep stosb
    ; пиксели снизу вверх: строки холста CH_-1..0, каждая SCALE раз
    mov bl, CH_ - 1
.crow:
    mov dl, SCALE
.rep:
    mov al, bl
    mov ah, CW
    mul ah
    mov si, canvas
    add si, ax
    mov cx, CW
.cell:
    lodsb
    push cx
    mov cx, SCALE
    rep stosb
    pop cx
    loop .cell
    dec dl
    jnz .rep
    dec bl
    jns .crow
    ret

; загрузить BMP из fname (если наш формат)
bmp_load:
    mov si, fname
    FAPI FAPI_STAT
    jc .r
    test dx, dx
    jnz .r
    cmp ax, BMPSZ
    jne .r
    mov si, fname
    push ds
    pop es
    mov di, bmpbuf
    mov cx, BMPSZ
    FAPI FAPI_READFILE
    jc .r
    cmp word [bmpbuf], 'BM'
    jne .r
    cmp word [bmpbuf + 18], BMPW
    jne .r
    cmp word [bmpbuf + 22], BMPH
    jne .r
    cmp word [bmpbuf + 28], 8
    jne .r
    ; пиксели -> холст (берём каждый SCALE-й пиксель каждой SCALE-й строки)
    mov bl, CH_ - 1
    mov si, bmpbuf + HDRSZ
.row:
    mov al, bl
    mov ah, CW
    mul ah
    mov di, canvas
    add di, ax
    mov cx, CW
.px:
    mov al, [si]
    and al, 0x0F
    stosb
    add si, SCALE
    loop .px
    add si, BMPW * (SCALE - 1)
    dec bl
    jns .row
.r: ret

skip_sp:
    cmp byte [si], ' '
    jne .r
    inc si
    jmp skip_sp
.r: ret

;---------------------------------------------------------------- данные
s_title  db " paint  Arrows+Space/LMB draw  Del/RMB erase  0-9 a-f color  F2 save  C clear  Esc", 0
s_color  db "Color:", 0
s_noname db "F2: save as...", 0
s_ask    db "Save as (BMP):", 0
s_saved  db "Saved.", 0
s_err    db "Save failed!", 0

bmp_hdr:
    db "BM"
    dd BMPSZ                        ; размер файла
    dw 0, 0
    dd HDRSZ                        ; смещение пикселей
    dd 40                           ; BITMAPINFOHEADER
    dd BMPW
    dd BMPH
    dw 1                            ; плоскости
    dw 8                            ; бит на пиксель
    dd 0                            ; без сжатия
    dd BMPW * BMPH
    dd 2835, 2835                   ; 72 dpi
    dd 256                          ; цветов в палитре
    dd 0

vga_pal:                            ; B, G, R, 0
    db 0x00,0x00,0x00,0, 0xAA,0x00,0x00,0, 0x00,0xAA,0x00,0, 0xAA,0xAA,0x00,0
    db 0x00,0x00,0xAA,0, 0xAA,0x00,0xAA,0, 0x00,0x55,0xAA,0, 0xAA,0xAA,0xAA,0
    db 0x55,0x55,0x55,0, 0xFF,0x55,0x55,0, 0x55,0xFF,0x55,0, 0xFF,0xFF,0x55,0
    db 0x55,0x55,0xFF,0, 0xFF,0x55,0xFF,0, 0x55,0xFF,0xFF,0, 0xFF,0xFF,0xFF,0

color    db 15
cur_r    db 0
cur_c    db 0
mbtn     db 0
fname    times 41 db 0
canvas   times CW * CH_ db 0
bmpbuf:                             ; BMPSZ байт — до конца сегмента
