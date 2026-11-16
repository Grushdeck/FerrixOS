;======================================
; File name: apps/tetris.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Tetris (игра .FAP)
;======================================
; Стакан 10x20, клетка = 2 символа. Стрелки <- -> двигают, Up — поворот,
; Down — мягкое падение, Space — сброс, P — пауза, Esc — выход.
; Очки: 100/300/500/800 за 1..4 линии, умноженные на уровень. Рекорд в /TETRIS.HI.

%include "fapi.inc"

    FAPI_HEADER

%include "game.inc"

BWID       equ 10
BHGT       equ 20
B_TOP    equ 2                      ; экранная строка первой строки стакана
B_LEFT   equ 30                     ; экранный столбец (клетка = 2 столбца)

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov si, hi_name
    call g_hi_load
new_game:
    FAPI FAPI_CLS
    FAPI FAPI_KBFLUSH
    ; очистить стакан
    mov di, board
    mov cx, BWID * BHGT
    xor al, al
    rep stosb
    mov word [score], 0
    mov word [lines], 0
    mov word [level], 1
    mov byte [paused], 0
    ; рамка стакана и панели
    mov dh, B_TOP - 1
    mov dl, B_LEFT - 1
    mov ch, BHGT + 2
    mov cl, BWID * 2 + 2
    mov bl, 0x09
    call g_frame
    FAPI_PUTSAT 0, 30, msg_title, 0x0F
    FAPI_PUTSAT 3, 6, msg_score, 0x07
    FAPI_PUTSAT 5, 6, msg_lines, 0x07
    FAPI_PUTSAT 7, 6, msg_level, 0x07
    FAPI_PUTSAT 9, 6, msg_best, 0x07
    FAPI_PUTSAT 3, 56, msg_next, 0x07
    FAPI_PUTSAT 14, 56, msg_k1, 0x08
    FAPI_PUTSAT 15, 56, msg_k2, 0x08
    FAPI_PUTSAT 16, 56, msg_k3, 0x08
    FAPI_PUTSAT 17, 56, msg_k4, 0x08
    FAPI_PUTSAT 18, 56, msg_k5, 0x08
    mov ax, [g_hiscore]
    mov dh, 9
    mov dl, 13
    mov bl, 0x0E
    mov cl, 6
    call g_num_at
    call show_stats
    call draw_board
    mov cx, 7
    call g_rand
    mov [next_p], al
    call spawn
    jc game_over
main_loop:
    ; тики до падения: 11 - уровень (мин. 1)
    mov ax, 11
    sub ax, [level]
    cmp ax, 1
    jge .ok
    mov ax, 1
.ok:
    mov bx, ax
    FAPI FAPI_TICKS
    add bx, ax
.wait:
    FAPI FAPI_KEYHIT
    jz .nokey
    FAPI FAPI_GETKEY
    call handle_key
    jc quit
    cmp byte [dropped], 0
    jne .fall_now
.nokey:
    cmp byte [paused], 0
    jne .wait
    FAPI FAPI_TICKS
    sub ax, bx
    jns .fall
    hlt
    jmp .wait
.fall_now:
    mov byte [dropped], 0
.fall:
    call piece_erase
    inc byte [py]
    call piece_fits
    jnc .draw
    dec byte [py]
    call piece_draw
    call lock_piece
    call clear_lines
    call spawn
    jc game_over
    jmp main_loop
.draw:
    call piece_draw
    jmp main_loop

; AX = клавиша; CF=1 выход
handle_key:
    cmp al, 27
    je .k_quit
    cmp al, 'p'
    je .k_pause
    cmp al, 'P'
    je .k_pause
    cmp byte [paused], 0
    jne .k_none
    cmp al, ' '
    je .k_drop
    test al, al
    jz .k_ext
    cmp al, 0xE0
    jne .k_none
.k_ext:
    cmp ah, 0x4B
    je .k_left
    cmp ah, 0x4D
    je .k_right
    cmp ah, 0x48
    je .k_rot
    cmp ah, 0x50
    je .k_down
.k_none:
    clc
    ret
.k_left:
    call piece_erase
    dec byte [px]
    call piece_fits
    jnc .k_redraw
    inc byte [px]
    jmp .k_redraw
.k_right:
    call piece_erase
    inc byte [px]
    call piece_fits
    jnc .k_redraw
    dec byte [px]
    jmp .k_redraw
.k_down:
    call piece_erase
    inc byte [py]
    call piece_fits
    jnc .k_redraw
    dec byte [py]
    mov byte [dropped], 1           ; упёрлись — зафиксировать сразу
    jmp .k_redraw
.k_drop:
    call piece_erase
.k_drop_l:
    inc byte [py]
    call piece_fits
    jnc .k_drop_l
    dec byte [py]
    add word [score], 2
    mov byte [dropped], 1
    jmp .k_redraw
.k_rot:
    call piece_erase
    mov al, [prot]
    mov [old_rot], al
    inc al
    and al, 3
    mov [prot], al
    call piece_fits
    jnc .k_redraw
    dec byte [px]                   ; wall kick влево
    call piece_fits
    jnc .k_redraw
    add byte [px], 2                ; вправо
    call piece_fits
    jnc .k_redraw
    dec byte [px]
    mov al, [old_rot]
    mov [prot], al
.k_redraw:
    call piece_draw
    clc
    ret
.k_pause:
    xor byte [paused], 1
    mov si, msg_pause
    cmp byte [paused], 0
    jne .k_pp
    mov si, msg_nopause
.k_pp:
    mov dh, 11
    mov dl, 6
    mov bl, 0x0E
    FAPI FAPI_PUTSAT
    clc
    ret
.k_quit:
    stc
    ret

; новая фигура из next_p; CF=1 — не помещается (конец игры)
spawn:
    mov al, [next_p]
    mov [ptype], al
    mov cx, 7
    call g_rand
    mov [next_p], al
    mov byte [prot], 0
    mov byte [px], 3
    mov byte [py], 0
    call draw_next
    call piece_fits
    jc .sp_over
    call piece_draw
    clc
    ret
.sp_over:
    call piece_draw
    stc
    ret

; SI -> 4 пары (dx,dy) текущей фигуры/поворота
piece_ptr:
    mov al, [ptype]
    mov ah, 32                      ; 4 поворота * 8 байт
    mul ah
    mov si, ax
    mov al, [prot]
    mov ah, 8
    mul ah
    add si, ax
    add si, pieces
    ret

; CF=1, если фигура в (px,py,prot) пересекает стенки/занятые клетки
piece_fits:
    push ax
    push bx
    push cx
    push si
    call piece_ptr
    mov cx, 4
.pf_cell:
    mov al, [si]                    ; dx
    add al, [px]
    cmp al, BWID
    jae .pf_bad                     ; и отрицательные (как 255) тоже
    mov ah, [si + 1]                ; dy
    add ah, [py]
    cmp ah, BHGT
    jae .pf_bad
    push ax
    mov al, ah
    mov ah, BWID
    mul ah
    mov bx, ax
    pop ax
    xor ah, ah
    add bx, ax
    cmp byte [board + bx], 0
    jne .pf_bad
    add si, 2
    loop .pf_cell
    clc
    jmp .pf_ret
.pf_bad:
    stc
.pf_ret:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; нарисовать фигуру цветом её типа / стереть
piece_draw:
    mov al, [ptype]
    inc al
    mov [draw_color], al
    jmp piece_paint
piece_erase:
    mov byte [draw_color], 0
piece_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    call piece_ptr
    mov cx, 4
.pp_cell:
    mov dl, [si]
    add dl, [px]
    mov dh, [si + 1]
    add dh, [py]
    mov al, [draw_color]
    call draw_cell
    add si, 2
    loop .pp_cell
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; клетка стакана DL=x DH=y, AL = цвет (0 пусто)
draw_cell:
    push ax
    push bx
    push cx
    push dx
    mov bl, al
    add dh, B_TOP
    shl dl, 1
    add dl, B_LEFT
    test bl, bl
    jz .dc_empty
    mov al, 0xDB
    xor bh, bh
    mov bl, [colors + bx]
    jmp .dc_put
.dc_empty:
    mov al, 0xFA
    mov bl, 0x08
.dc_put:
    FAPI FAPI_PUTAT
    inc dl
    FAPI FAPI_PUTAT
    pop dx
    pop cx
    pop bx
    pop ax
    ret

draw_board:
    xor dh, dh
.db_row:
    xor dl, dl
.db_col:
    mov al, dh
    mov ah, BWID
    mul ah
    mov bl, dl
    xor bh, bh
    add bx, ax
    mov al, [board + bx]
    call draw_cell
    inc dl
    cmp dl, BWID
    jb .db_col
    inc dh
    cmp dh, BHGT
    jb .db_row
    ret

; зафиксировать фигуру в board
lock_piece:
    push ax
    push bx
    push cx
    push si
    call piece_ptr
    mov cx, 4
.lp_cell:
    mov al, [si + 1]
    add al, [py]
    mov ah, BWID
    mul ah
    mov bx, ax
    mov al, [si]
    add al, [px]
    xor ah, ah
    add bx, ax
    mov al, [ptype]
    inc al
    mov [board + bx], al
    add si, 2
    loop .lp_cell
    pop si
    pop cx
    pop bx
    pop ax
    ret

; убрать заполненные строки, начислить очки
clear_lines:
    pusha
    xor dx, dx                      ; DL = убрано строк
    mov ch, BHGT - 1                  ; проверяемая строка (снизу вверх)
.cl_row:
    mov al, ch
    mov ah, BWID
    mul ah
    mov bx, ax
    mov cl, BWID
.cl_chk:
    cmp byte [board + bx], 0
    je .cl_next
    inc bx
    dec cl
    jnz .cl_chk
    ; строка полна: сдвинуть всё выше вниз
    inc dl
    mov al, ch
    mov ah, BWID
    mul ah
    mov di, ax
    add di, board + BWID - 1          ; конец строки CH
    mov si, di
    sub si, BWID
    mov cx, ax                      ; байт выше = ch*BWID
    std
    rep movsb
    cld
    mov di, board
    mov cx, BWID
    xor al, al
    rep stosb                       ; верхняя строка пустая
    mov cl, 0
    jmp .cl_row                     ; ту же строку проверить снова (CH не менялся)
.cl_next:
    dec ch
    jns .cl_row
    test dl, dl
    jz .cl_done
    ; очки
    xor dh, dh
    mov bx, dx
    shl bx, 1
    mov ax, [line_pts + bx - 2]
    push dx
    mul word [level]
    pop dx
    add [score], ax
    add [lines], dx
    mov ax, [lines]
    mov bl, 10
    div bl
    xor ah, ah
    inc ax
    mov [level], ax
    call show_stats
    call draw_board
    FAPI FAPI_BEEP
.cl_done:
    popa
    ret

show_stats:
    mov ax, [score]
    mov dh, 3
    mov dl, 13
    mov bl, 0x0F
    mov cl, 6
    call g_num_at
    mov ax, [lines]
    mov dh, 5
    call g_num_at
    mov ax, [level]
    mov dh, 7
    call g_num_at
    ret

; превью следующей фигуры в окне справа (строки 5..8, столбцы 56..63)
draw_next:
    pusha
    mov dh, 5
    mov dl, 56
    mov ch, 4
    mov cl, 10
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    mov al, [next_p]
    mov ah, 32
    mul ah
    mov si, ax
    add si, pieces                  ; поворот 0
    mov al, [next_p]
    inc al
    mov bl, al
    xor bh, bh
    mov bl, [colors + bx]
    mov cx, 4
.dn_cell:
    mov dl, [si]
    shl dl, 1
    add dl, 57
    mov dh, [si + 1]
    add dh, 5
    mov al, 0xDB
    FAPI FAPI_PUTAT
    inc dl
    FAPI FAPI_PUTAT
    add si, 2
    loop .dn_cell
    popa
    ret

game_over:
    mov ax, [score]
    cmp ax, [g_hiscore]
    jbe .go_nohi
    mov [g_hiscore], ax
    mov si, hi_name
    call g_hi_save
.go_nohi:
    FAPI FAPI_BEEP
    FAPI_PUTSAT 10, 31, msg_over, 0x4F
    FAPI_PUTSAT 11, 31, msg_again, 0x4F
    FAPI_PUTSAT 12, 31, msg_again2, 0x4F
    FAPI FAPI_KBFLUSH
.go_key:
    FAPI FAPI_GETKEY
    cmp al, 13
    je new_game
    cmp al, 27
    jne .go_key
quit:
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

;---------------- данные ----------------
hi_name     db "/TETRIS.HI", 0
msg_title   db " T E T R I S ", 0
msg_score   db "Score:", 0
msg_lines   db "Lines:", 0
msg_level   db "Level:", 0
msg_best    db "Best: ", 0
msg_next    db "Next:", 0
msg_pause   db "[ PAUSED ]", 0
msg_nopause db "          ", 0
msg_k1      db "<- ->  move", 0
msg_k2      db "Up     rotate", 0
msg_k3      db "Down   soft drop", 0
msg_k4      db "Space  hard drop", 0
msg_k5      db "P pause Esc quit", 0
msg_over    db "   GAME OVER   ", 0
msg_again   db " Enter = again ", 0
msg_again2  db " Esc   = quit  ", 0
line_pts    dw 100, 300, 500, 800
colors      db 0x07, 0x0B, 0x0E, 0x0D, 0x0A, 0x0C, 0x09, 0x06   ; [0] не используется
; фигуры: 7 типов x 4 поворота x 4 клетки (dx,dy) в сетке 4x4
pieces:
    ; I
    db 0,1, 1,1, 2,1, 3,1,   2,0, 2,1, 2,2, 2,3,   0,2, 1,2, 2,2, 3,2,   1,0, 1,1, 1,2, 1,3
    ; O
    db 1,0, 2,0, 1,1, 2,1,   1,0, 2,0, 1,1, 2,1,   1,0, 2,0, 1,1, 2,1,   1,0, 2,0, 1,1, 2,1
    ; T
    db 1,0, 0,1, 1,1, 2,1,   1,0, 1,1, 2,1, 1,2,   0,1, 1,1, 2,1, 1,2,   1,0, 0,1, 1,1, 1,2
    ; S
    db 1,0, 2,0, 0,1, 1,1,   1,0, 1,1, 2,1, 2,2,   1,1, 2,1, 0,2, 1,2,   0,0, 0,1, 1,1, 1,2
    ; Z
    db 0,0, 1,0, 1,1, 2,1,   2,0, 1,1, 2,1, 1,2,   0,1, 1,1, 1,2, 2,2,   1,0, 0,1, 1,1, 0,2
    ; J
    db 0,0, 0,1, 1,1, 2,1,   1,0, 2,0, 1,1, 1,2,   0,1, 1,1, 2,1, 2,2,   1,0, 1,1, 0,2, 1,2
    ; L
    db 2,0, 0,1, 1,1, 2,1,   1,0, 1,1, 1,2, 2,2,   0,1, 1,1, 2,1, 0,2,   0,0, 1,0, 1,1, 1,2
score       dw 0
lines       dw 0
level       dw 1
next_p      db 0
ptype       db 0
prot        db 0
old_rot     db 0
px          db 0
py          db 0
paused      db 0
dropped     db 0
draw_color  db 0
board       times BWID * BHGT db 0
