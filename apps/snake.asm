;======================================
; File name: apps/snake.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Snake — змейка (игра .FAP)
;======================================
; Управление: стрелки / WASD, P — пауза, Esc — выход.
; Поле 78x22 внутри рамки, еда '*', скорость растёт каждые 5 съеденных.
; Рекорд хранится в /SNAKE.HI.

%include "fapi.inc"

    FAPI_HEADER

%include "game.inc"

TOP      equ 2                      ; первая строка поля
LEFT     equ 1
ROWS     equ 22
COLS     equ 78
C_SNAKE  equ 0x0A
C_HEAD   equ 0x0E
C_FOOD   equ 0x0C
C_FRAME  equ 0x09

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov si, hi_name
    call g_hi_load
new_game:
    FAPI FAPI_CLS
    FAPI FAPI_KBFLUSH
    ; рамка и заголовок
    mov dh, 1
    mov dl, 0
    mov ch, ROWS + 2
    mov cl, COLS + 2
    mov bl, C_FRAME
    call g_frame
    FAPI_PUTSAT 0, 1, msg_title, 0x0F
    FAPI_PUTSAT 0, 50, msg_score, 0x07
    FAPI_PUTSAT 0, 64, msg_hi, 0x07
    mov ax, [g_hiscore]
    mov dh, 0
    mov dl, 69
    mov bl, 0x0E
    mov cl, 5
    call g_num_at
    ; змейка: 3 клетки в центре, движение вправо
    mov word [head], 0
    mov word [tail], 0
    mov word [score], 0
    mov word [grow], 2
    mov byte [delay], 3
    mov byte [eaten], 0
    mov byte [dir], 1               ; 0 up 1 right 2 down 3 left
    mov byte [cur_r], TOP + ROWS / 2
    mov byte [cur_c], LEFT + COLS / 2
    mov ax, [cur_r]                 ; AL = row, AH = col
    mov [body], ax
    mov dh, al
    mov dl, ah
    mov al, 0xDB
    mov bl, C_HEAD
    FAPI FAPI_PUTAT
    call show_score
    call place_food
game_loop:
    FAPI FAPI_TICKS
    mov bl, [delay]
    xor bh, bh
    add bx, ax
    mov [next_tick], bx
.wait:
    FAPI FAPI_KEYHIT
    jz .nokey
    FAPI FAPI_GETKEY
    call handle_key
    jc quit
.nokey:
    FAPI FAPI_TICKS
    sub ax, [next_tick]
    jns .step
    hlt
    jmp .wait
.step:
    cmp byte [paused], 0
    jne game_loop
    ; старая голова -> цвет тела
    mov dh, [cur_r]
    mov dl, [cur_c]
    mov al, 0xDB
    mov bl, C_SNAKE
    FAPI FAPI_PUTAT
    ; новая позиция
    mov al, [dir]
    cmp al, 0
    jne .d1
    dec byte [cur_r]
    jmp .moved
.d1:
    cmp al, 1
    jne .d2
    inc byte [cur_c]
    jmp .moved
.d2:
    cmp al, 2
    jne .d3
    inc byte [cur_r]
    jmp .moved
.d3:
    dec byte [cur_c]
.moved:
    ; что в клетке? (читаем видеопамять)
    push es
    mov es, [0x10]                  ; сегмент видеопамяти (B800h или окно GUI)
    mov al, [cur_r]
    mov ah, 160
    mul ah
    mov bl, [cur_c]
    xor bh, bh
    shl bx, 1
    add bx, ax
    mov al, [es:bx]
    pop es
    cmp al, ' '
    je .free
    cmp al, '*'
    je .eat
    jmp game_over
.eat:
    add word [score], 10
    add word [grow], 3
    inc byte [eaten]
    cmp byte [eaten], 5
    jb .eat_ok
    mov byte [eaten], 0
    cmp byte [delay], 1
    jbe .eat_ok
    dec byte [delay]
.eat_ok:
    call show_score
    call place_food
.free:
    ; записать голову в кольцевой буфер
    mov bx, [head]
    inc bx
    cmp bx, BODY_MAX
    jb .hk
    xor bx, bx
.hk:
    mov [head], bx
    shl bx, 1
    mov ax, [cur_r]
    mov [body + bx], ax
    mov dh, al
    mov dl, ah
    mov al, 0xDB
    mov bl, C_HEAD
    FAPI FAPI_PUTAT
    ; хвост
    cmp word [grow], 0
    je .cut
    dec word [grow]
    jmp game_loop
.cut:
    mov bx, [tail]
    shl bx, 1
    mov ax, [body + bx]
    mov dh, al
    mov dl, ah
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_PUTAT
    mov bx, [tail]
    inc bx
    cmp bx, BODY_MAX
    jb .tk
    xor bx, bx
.tk:
    mov [tail], bx
    jmp game_loop

; AX = клавиша. CF=1 — выход
handle_key:
    cmp al, 27
    je .hk_quit
    cmp al, 'p'
    je .hk_pause
    cmp al, 'P'
    je .hk_pause
    mov bl, 0
    cmp al, 'w'
    je .hk_set
    cmp al, 'W'
    je .hk_set
    mov bl, 3
    cmp al, 'a'
    je .hk_set
    cmp al, 'A'
    je .hk_set
    mov bl, 2
    cmp al, 's'
    je .hk_set
    cmp al, 'S'
    je .hk_set
    mov bl, 1
    cmp al, 'd'
    je .hk_set
    cmp al, 'D'
    je .hk_set
    test al, al
    jz .hk_ext
    cmp al, 0xE0
    jne .hk_none
.hk_ext:
    mov bl, 0
    cmp ah, 0x48
    je .hk_set
    mov bl, 1
    cmp ah, 0x4D
    je .hk_set
    mov bl, 2
    cmp ah, 0x50
    je .hk_set
    mov bl, 3
    cmp ah, 0x4B
    je .hk_set
.hk_none:
    clc
    ret
.hk_set:
    ; запрет разворота на 180
    mov al, [dir]
    sub al, bl
    cmp al, 2
    je .hk_none
    cmp al, -2
    je .hk_none
    mov [dir], bl
    clc
    ret
.hk_pause:
    xor byte [paused], 1
    mov si, msg_pause
    cmp byte [paused], 0
    jne .hk_pp
    mov si, msg_nopause
.hk_pp:
    mov dh, 24
    mov dl, 35
    mov bl, 0x0E
    FAPI FAPI_PUTSAT
    clc
    ret
.hk_quit:
    stc
    ret

show_score:
    mov ax, [score]
    mov dh, 0
    mov dl, 57
    mov bl, 0x0F
    mov cl, 5
    call g_num_at
    ret

place_food:
.pf_try:
    mov cx, ROWS
    call g_rand
    add al, TOP
    mov dh, al
    mov cx, COLS
    call g_rand
    add al, LEFT
    mov dl, al
    ; клетка свободна?
    push es
    mov es, [0x10]                  ; сегмент видеопамяти (B800h или окно GUI)
    mov al, dh
    mov ah, 160
    mul ah
    mov bl, dl
    xor bh, bh
    shl bx, 1
    add bx, ax
    mov al, [es:bx]
    pop es
    cmp al, ' '
    jne .pf_try
    mov al, '*'
    mov bl, C_FOOD
    FAPI FAPI_PUTAT
    ret

game_over:
    FAPI FAPI_BEEP
    mov ax, [score]
    cmp ax, [g_hiscore]
    jbe .go_nohi
    mov [g_hiscore], ax
    mov si, hi_name
    call g_hi_save
.go_nohi:
    mov dh, 10
    mov dl, 24
    mov ch, 5
    mov cl, 32
    mov al, ' '
    mov bl, 0x4F
    FAPI FAPI_FILLRECT
    FAPI_PUTSAT 11, 26, msg_over, 0x4F
    FAPI_PUTSAT 12, 26, msg_score, 0x4F
    mov ax, [score]
    mov dh, 12
    mov dl, 33
    mov bl, 0x4E
    mov cl, 5
    call g_num_at
    FAPI_PUTSAT 13, 26, msg_again, 0x4F
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
BODY_MAX    equ ROWS * COLS
hi_name     db "/SNAKE.HI", 0
msg_title   db " SNAKE   arrows/WASD move  P pause  Esc quit ", 0
msg_score   db "Score:", 0
msg_hi      db "Best:", 0
msg_pause   db "[ PAUSED ]", 0
msg_nopause db "          ", 0
msg_over    db "        GAME OVER        ", 0
msg_again   db " Enter = again, Esc = quit ", 0
head        dw 0
next_tick   dw 0
tail        dw 0
score       dw 0
grow        dw 0
delay       db 3
eaten       db 0
dir         db 1
paused      db 0
cur_r       db 0                    ; cur_r и cur_c идут подряд: AL=row, AH=col
cur_c       db 0
body:                               ; кольцевой буфер BODY_MAX слов (за концом файла)
