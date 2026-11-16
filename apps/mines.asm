;======================================
; File name: apps/mines.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Mines — сапёр (игра .FAP)
;======================================
; Поле 16x16, 40 мин. Стрелки — курсор, Space/Enter — открыть, F — флаг,
; N — новая игра, Esc — выход. Первый ход всегда безопасен.
; Лучшее время (секунды) хранится в /MINES.HI.

%include "fapi.inc"

    FAPI_HEADER

%include "game.inc"

FW       equ 16
FH       equ 16
NMINES   equ 40
F_TOP    equ 4                      ; экранная строка первой строки поля
F_LEFT   equ 24                     ; экранный столбец (клетка = 2 столбца)
S_CLOSED equ 0
S_OPEN   equ 1
S_FLAG   equ 2

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov si, hi_name
    call g_hi_load
new_game:
    FAPI FAPI_CLS
    FAPI FAPI_KBFLUSH
    mov di, mines
    mov cx, FW * FH * 2             ; mines + state
    xor al, al
    rep stosb
    mov byte [placed], 0
    mov byte [over], 0
    mov word [opened], 0
    mov byte [flags], 0
    mov byte [cx_], FW / 2
    mov byte [cy_], FH / 2
    mov word [start_tick], 0
    mov dh, F_TOP - 1
    mov dl, F_LEFT - 1
    mov ch, FH + 2
    mov cl, FW * 2 + 2
    mov bl, 0x09
    call g_frame
    FAPI_PUTSAT 0, 24, msg_title, 0x0F
    FAPI_PUTSAT 2, 24, msg_mines, 0x07
    FAPI_PUTSAT 2, 40, msg_time, 0x07
    FAPI_PUTSAT 2, 56, msg_best, 0x07
    FAPI_PUTSAT 22, 14, msg_keys, 0x08
    mov ax, [g_hiscore]
    mov dh, 2
    mov dl, 62
    mov bl, 0x0E
    mov cl, 5
    call g_num_at
    call draw_all
    call show_status
main_loop:
    call draw_cursor
    mov cx, 9                       ; обновлять таймер ~2 раза в секунду
    call g_wait_key
    test ax, ax
    jnz .key
    call show_status
    jmp main_loop
.key:
    push ax
    call undraw_cursor
    pop ax
    cmp al, 27
    je quit
    cmp al, 'n'
    je new_game
    cmp al, 'N'
    je new_game
    cmp byte [over], 0
    jne main_loop                   ; после конца — только N / Esc
    cmp al, ' '
    je .open
    cmp al, 13
    je .open
    cmp al, 'f'
    je .flag
    cmp al, 'F'
    je .flag
    test al, al
    jz .ext
    cmp al, 0xE0
    jne main_loop
.ext:
    cmp ah, 0x48
    je .up
    cmp ah, 0x50
    je .down
    cmp ah, 0x4B
    je .left
    cmp ah, 0x4D
    je .right
    jmp main_loop
.up:
    cmp byte [cy_], 0
    je main_loop
    dec byte [cy_]
    jmp main_loop
.down:
    cmp byte [cy_], FH - 1
    jae main_loop
    inc byte [cy_]
    jmp main_loop
.left:
    cmp byte [cx_], 0
    je main_loop
    dec byte [cx_]
    jmp main_loop
.right:
    cmp byte [cx_], FW - 1
    jae main_loop
    inc byte [cx_]
    jmp main_loop
.flag:
    call cur_index                  ; BX
    cmp byte [state + bx], S_OPEN
    je main_loop
    xor byte [state + bx], S_FLAG
    test byte [state + bx], S_FLAG
    jz .fl_dec
    inc byte [flags]
    jmp .fl_draw
.fl_dec:
    dec byte [flags]
.fl_draw:
    call draw_cell_bx
    call show_status
    jmp main_loop
.open:
    call cur_index
    cmp byte [state + bx], S_CLOSED
    jne main_loop
    cmp byte [placed], 0
    jne .op_go
    call place_mines                ; первый ход: мины не под курсором
    FAPI FAPI_TICKS
    mov [start_tick], ax
.op_go:
    cmp byte [mines + bx], 0
    jne boom
    call open_flood
    ; победа?
    mov ax, [opened]
    cmp ax, FW * FH - NMINES
    jb main_loop
    call win
    jmp main_loop

; BX = cy*FW + cx
cur_index:
    mov al, [cy_]
    mov ah, FW
    mul ah
    mov bl, [cx_]
    xor bh, bh
    add bx, ax
    ret

place_mines:
    push bx
    mov cx, NMINES
.pm_loop:
    push cx
    mov cx, FW * FH
    call g_rand
    mov si, ax
    pop cx
    cmp si, bx                      ; не под курсором
    je .pm_loop
    cmp byte [mines + si], 0
    jne .pm_loop
    mov byte [mines + si], 1
    loop .pm_loop
    mov byte [placed], 1
    pop bx
    ret

; AL = число мин вокруг клетки BX
count_around:
    push bx
    push cx
    push dx
    push si
    xor dl, dl
    mov ax, bx
    mov cl, FW
    div cl                          ; AL = y, AH = x
    mov ch, al                      ; CH = y
    mov cl, ah                      ; CL = x
    mov si, -1                      ; dy
.ca_dy:
    mov di, -1                      ; dx
.ca_dx:
    mov ax, si
    or ax, di
    jz .ca_next                     ; сама клетка
    mov al, ch
    xor ah, ah
    add ax, si                      ; si = -1/0/1 -> ax = y+dy
    cmp ax, FH
    jae .ca_next
    mov bl, al
    mov al, cl
    xor ah, ah
    add ax, di
    cmp ax, FW
    jae .ca_next
    push ax
    mov al, bl
    mov ah, FW
    mul ah
    mov bx, ax
    pop ax
    add bx, ax
    add dl, [mines + bx]
.ca_next:
    inc di
    cmp di, 2
    jl .ca_dx
    inc si
    cmp si, 2
    jl .ca_dy
    mov al, dl
    pop si
    pop dx
    pop cx
    pop bx
    ret

; открыть клетку BX и соседей нулей (итеративно через стек-очередь)
open_flood:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov word [qlen], 0
    call push_q
.of_loop:
    cmp word [qlen], 0
    je .of_done
    dec word [qlen]
    mov si, [qlen]
    shl si, 1
    mov bx, [queue + si]
    cmp byte [state + bx], S_OPEN
    je .of_loop
    mov byte [state + bx], S_OPEN
    inc word [opened]
    call draw_cell_bx
    call count_around
    test al, al
    jnz .of_loop
    ; соседи
    mov ax, bx
    mov cl, FW
    div cl                          ; AL=y AH=x
    mov ch, al
    mov cl, ah
    mov si, -1
.of_dy:
    mov di, -1
.of_dx:
    mov al, ch
    xor ah, ah
    add ax, si
    cmp ax, FH
    jae .of_n
    mov dl, al
    mov al, cl
    xor ah, ah
    add ax, di
    cmp ax, FW
    jae .of_n
    push ax
    mov al, dl
    mov ah, FW
    mul ah
    mov bx, ax
    pop ax
    add bx, ax
    cmp byte [state + bx], S_CLOSED
    jne .of_n
    call push_q
.of_n:
    inc di
    cmp di, 2
    jl .of_dx
    inc si
    cmp si, 2
    jl .of_dy
    jmp .of_loop
.of_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

push_q:
    push si
    mov si, [qlen]
    cmp si, QMAX
    jae .pq_ret
    shl si, 1
    mov [queue + si], bx
    inc word [qlen]
.pq_ret:
    pop si
    ret

; нарисовать клетку BX
draw_cell_bx:
    push ax
    push bx
    push cx
    push dx
    mov ax, bx
    mov cl, FW
    div cl                          ; AL=y AH=x
    mov dh, al
    add dh, F_TOP
    mov dl, ah
    shl dl, 1
    add dl, F_LEFT
    mov al, [state + bx]
    cmp al, S_OPEN
    je .dc_open
    test al, S_FLAG
    jnz .dc_flag
    mov al, 0xB1
    mov bl, 0x08
    jmp .dc_two
.dc_flag:
    mov al, 0xB1
    mov bl, 0x08
    FAPI FAPI_PUTAT
    inc dl
    mov al, 'F'
    mov bl, 0x0C
    FAPI FAPI_PUTAT
    jmp .dc_done
.dc_open:
    cmp byte [mines + bx], 0
    jne .dc_mine
    call count_around
    test al, al
    jz .dc_zero
    mov bl, al
    xor bh, bh
    mov bl, [numcol + bx]
    add al, '0'
    push ax
    mov al, ' '
    FAPI FAPI_PUTAT
    pop ax
    inc dl
    FAPI FAPI_PUTAT
    jmp .dc_done
.dc_zero:
    mov al, ' '
    mov bl, 0x07
    jmp .dc_two
.dc_mine:
    mov al, ' '
    mov bl, 0x4F
    FAPI FAPI_PUTAT
    inc dl
    mov al, '*'
    FAPI FAPI_PUTAT
    jmp .dc_done
.dc_two:
    FAPI FAPI_PUTAT
    inc dl
    FAPI FAPI_PUTAT
.dc_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

draw_all:
    xor bx, bx
.da_loop:
    call draw_cell_bx
    inc bx
    cmp bx, FW * FH
    jb .da_loop
    ret

; курсор: скобки вокруг клетки (поверх соседних клеток)
draw_cursor:
    mov dh, [cy_]
    add dh, F_TOP
    mov dl, [cx_]
    shl dl, 1
    add dl, F_LEFT
    mov bl, 0x0E
    cmp byte [cx_], 0
    je .dc_r
    dec dl
    mov al, '['
    FAPI FAPI_PUTAT
    inc dl
.dc_r:
    cmp byte [cx_], FW - 1
    je .dc_done
    add dl, 2
    mov al, ']'
    FAPI FAPI_PUTAT
.dc_done:
    ret
; стереть курсор — перерисовать соседние клетки
undraw_cursor:
    call cur_index
    cmp byte [cx_], 0
    je .uc_r
    dec bx
    call draw_cell_bx
    inc bx
.uc_r:
    cmp byte [cx_], FW - 1
    je .uc_done
    inc bx
    call draw_cell_bx
.uc_done:
    ret

show_status:
    mov al, NMINES
    sub al, [flags]
    xor ah, ah
    mov dh, 2
    mov dl, 31
    mov bl, 0x0F
    mov cl, 4
    call g_num_at
    cmp byte [placed], 0
    je .ss_z
    cmp byte [over], 0
    jne .ss_ret
    FAPI FAPI_TICKS
    sub ax, [start_tick]
    mov cx, 18
    xor dx, dx
    div cx                          ; секунды (грубо, 18 тик/с)
    mov [elapsed], ax
    jmp .ss_t
.ss_z:
    xor ax, ax
.ss_t:
    mov dh, 2
    mov dl, 46
    mov bl, 0x0F
    mov cl, 5
    call g_num_at
.ss_ret:
    ret

boom:
    mov byte [over], 1
    ; показать все мины
    xor bx, bx
.bm_loop:
    cmp byte [mines + bx], 0
    je .bm_n
    mov byte [state + bx], S_OPEN
    call draw_cell_bx
.bm_n:
    inc bx
    cmp bx, FW * FH
    jb .bm_loop
    FAPI FAPI_BEEP
    FAPI_PUTSAT 21, 30, msg_boom, 0x4F
    jmp main_loop

win:
    call show_status                ; зафиксировать время (over ещё 0)
    mov byte [over], 1
    mov ax, [elapsed]
    cmp word [g_hiscore], 0
    je .w_hi
    cmp ax, [g_hiscore]
    jae .w_nohi
.w_hi:
    mov [g_hiscore], ax
    mov si, hi_name
    call g_hi_save
    mov dh, 2
    mov dl, 62
    mov bl, 0x0E
    mov cl, 5
    call g_num_at
.w_nohi:
    FAPI_PUTSAT 21, 30, msg_win, 0x2F
    ret

quit:
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

;---------------- данные ----------------
QMAX        equ FW * FH * 2
hi_name     db "/MINES.HI", 0
msg_title   db " M I N E S   16x16, 40 mines ", 0
msg_mines   db "Mines:", 0
msg_time    db "Time:", 0
msg_best    db "Best:", 0
msg_keys    db "Arrows move  Space/Enter open  F flag  N new game  Esc quit", 0
msg_boom    db "  BOOM! N = new game  ", 0
msg_win     db "  YOU WIN! N = again  ", 0
numcol      db 0x07, 0x09, 0x0A, 0x0C, 0x0D, 0x04, 0x03, 0x0F, 0x08
placed      db 0
over        db 0
flags       db 0
cx_         db 0
cy_         db 0
opened      dw 0
start_tick  dw 0
elapsed     dw 0
qlen        dw 0
mines       times FW * FH db 0
state       times FW * FH db 0
queue:                              ; QMAX слов за концом файла
