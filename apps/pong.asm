;======================================
; File name: apps/pong.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Pong — игрок против компьютера (игра .FAP)
;======================================
; Управление: стрелки вверх/вниз или W/S (левая ракетка), P — пауза, Esc — выход.
; До 10 очков. Мяч ускоряется после каждого отбития; угол зависит от места удара.
; Координаты мяча — в 1/16 клетки.

%include "fapi.inc"

    FAPI_HEADER

%include "game.inc"

TOP      equ 2                      ; поле: строки TOP..TOP+ROWS-1
ROWS     equ 22
COLS     equ 78
LEFT     equ 1
PADH     equ 5                      ; высота ракетки
PX_L     equ LEFT + 1               ; столбец левой ракетки
PX_R     equ LEFT + COLS - 2        ; столбец правой
WIN      equ 10
C_FRAME  equ 0x08
C_PAD    equ 0x0F
C_CPU    equ 0x0C
C_BALL   equ 0x0E
C_NET    equ 0x08

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
new_match:
    mov byte [sc_l], 0
    mov byte [sc_r], 0
    FAPI FAPI_CLS
    FAPI FAPI_KBFLUSH
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov dh, TOP - 1
    mov dl, LEFT - 1
    mov ch, ROWS + 2
    mov cl, COLS + 2
    mov bl, C_FRAME
    call g_frame
    FAPI_PUTSAT 0, 1, msg_title, 0x0F
    FAPI_PUTSAT 0, 58, msg_keys, 0x08
    mov byte [pad_l], TOP + ROWS / 2 - PADH / 2
    mov byte [pad_r], TOP + ROWS / 2 - PADH / 2
    call draw_static
    call serve
game_loop:
    ; --- ввод ---
    FAPI FAPI_KEYHIT
    jz .nokey
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    cmp al, 'p'
    je .pause
    cmp al, 'P'
    je .pause
    cmp ah, 0x48
    je .up
    cmp al, 'w'
    je .up
    cmp al, 'W'
    je .up
    cmp ah, 0x50
    je .down
    cmp al, 's'
    je .down
    cmp al, 'S'
    je .down
    jmp .nokey
.pause:
    FAPI_PUTSAT 0, 36, msg_pause, 0x4F
    FAPI FAPI_GETKEY
    FAPI_PUTSAT 0, 36, msg_nopause, 0x07
    jmp .nokey
.up:
    cmp byte [pad_l], TOP
    jbe .nokey
    dec byte [pad_l]
    jmp .nokey
.down:
    cmp byte [pad_l], TOP + ROWS - PADH
    jae .nokey
    inc byte [pad_l]
.nokey:
    ; --- компьютер: следит за мячом, но не быстрее 1 клетки за 2 кадра ---
    inc byte [cpu_tick]
    test byte [cpu_tick], 1
    jnz .cpu_done
    mov ax, [ball_y]
    mov cl, 4
    shr ax, cl                      ; строка мяча
    mov bl, [pad_r]
    add bl, PADH / 2                ; центр ракетки
    cmp al, bl
    je .cpu_done
    jb .cpu_up
    cmp byte [pad_r], TOP + ROWS - PADH
    jae .cpu_done
    inc byte [pad_r]
    jmp .cpu_done
.cpu_up:
    cmp byte [pad_r], TOP
    jbe .cpu_done
    dec byte [pad_r]
.cpu_done:
    ; --- мяч ---
    call erase_ball
    mov ax, [ball_x]
    add ax, [vel_x]
    mov [ball_x], ax
    mov ax, [ball_y]
    add ax, [vel_y]
    mov [ball_y], ax
    ; отскок от верха/низа
    cmp ax, TOP * 16
    jge .ny1
    mov ax, TOP * 16
    mov [ball_y], ax
    neg word [vel_y]
.ny1:
    cmp ax, (TOP + ROWS - 1) * 16
    jle .ny2
    mov ax, (TOP + ROWS - 1) * 16
    mov [ball_y], ax
    neg word [vel_y]
.ny2:
    ; столбец/строка мяча
    mov ax, [ball_x]
    mov cl, 4
    shr ax, cl
    mov [bcol], al
    mov ax, [ball_y]
    shr ax, cl
    mov [brow], al
    ; левая ракетка
    cmp byte [bcol], PX_L
    jne .chk_r
    cmp word [vel_x], 0
    jge .chk_r
    mov bl, [pad_l]
    call hit_test
    jnc .miss_l
    call bounce
    mov word [ball_x], (PX_L + 1) * 16
    jmp .drawn
.miss_l:
    jmp .chk_out
.chk_r:
    cmp byte [bcol], PX_R
    jne .chk_out
    cmp word [vel_x], 0
    jle .chk_out
    mov bl, [pad_r]
    call hit_test
    jnc .chk_out
    call bounce
    mov word [ball_x], (PX_R - 1) * 16
    jmp .drawn
.chk_out:
    cmp byte [bcol], LEFT
    ja .not_l
    inc byte [sc_r]
    jmp .point
.not_l:
    cmp byte [bcol], LEFT + COLS - 1
    jb .drawn
    inc byte [sc_l]
.point:
    call draw_static
    FAPI FAPI_BEEP
    cmp byte [sc_l], WIN
    jae .win
    cmp byte [sc_r], WIN
    jae .lose
    mov cx, 12
    call g_wait_key
    call serve
    jmp game_loop
.win:
    FAPI_PUTSAT 11, 30, msg_win, 0x2F
    jmp .end
.lose:
    FAPI_PUTSAT 11, 30, msg_lose, 0x4F
.end:
    FAPI_PUTSAT 12, 30, msg_again, 0x70
    FAPI FAPI_KBFLUSH
.wait:
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    cmp al, 13
    jne .wait
    jmp new_match
.drawn:
    call draw_pads
    call draw_ball
    ; задержка кадра: 1 тик (~55 мс); скорость — в vel
    mov cx, 1
    call g_wait_key
    test ax, ax
    jz game_loop
    ; клавишу вернуть в обработку: простой способ — обработать здесь же
    push ax
    FAPI FAPI_KBFLUSH
    pop ax
    cmp al, 27
    je quit
    cmp ah, 0x48
    je .k_up
    cmp al, 'w'
    je .k_up
    cmp al, 'W'
    je .k_up
    cmp ah, 0x50
    je .k_down
    cmp al, 's'
    je .k_down
    cmp al, 'S'
    je .k_down
    cmp al, 'p'
    je .k_pause
    cmp al, 'P'
    je .k_pause
    jmp game_loop
.k_up:
    cmp byte [pad_l], TOP
    jbe game_loop
    dec byte [pad_l]
    jmp game_loop
.k_down:
    cmp byte [pad_l], TOP + ROWS - PADH
    jae game_loop
    inc byte [pad_l]
    jmp game_loop
.k_pause:
    FAPI_PUTSAT 0, 36, msg_pause, 0x4F
    FAPI FAPI_GETKEY
    FAPI_PUTSAT 0, 36, msg_nopause, 0x07
    jmp game_loop

quit:
    FAPI FAPI_CLS
    FAPI FAPI_UIREDRAW
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI_QUIT

; BL = верх ракетки; мяч в строке [brow]. CF=1 попал; [hit_off] = смещение от центра (-2..2)
hit_test:
    mov al, [brow]
    sub al, bl
    cmp al, PADH
    jae .no
    sub al, PADH / 2
    mov [hit_off], al
    stc
    ret
.no:
    clc
    ret

; отскок от ракетки: vel_x меняет знак и растёт, vel_y по месту удара
bounce:
    neg word [vel_x]
    mov ax, [vel_x]
    test ax, ax
    js .neg
    cmp ax, 40
    jae .vy
    add ax, 2
    jmp .set
.neg:
    cmp ax, -40
    jle .vy
    sub ax, 2
.set:
    mov [vel_x], ax
.vy:
    mov al, [hit_off]
    cbw
    mov cx, 5
    imul cx                         ; -10..10
    mov [vel_y], ax
    ; небольшой случайный разброс
    mov cx, 5
    call g_rand
    sub ax, 2
    add [vel_y], ax
    FAPI FAPI_BEEP
    ret

; новая подача из центра в сторону проигравшего (или случайно)
serve:
    mov word [ball_x], (LEFT + COLS / 2) * 16
    mov word [ball_y], (TOP + ROWS / 2) * 16
    mov word [vel_x], 14
    mov cx, 2
    call g_rand
    test ax, ax
    jz .r
    neg word [vel_x]
.r:
    mov cx, 13
    call g_rand
    sub ax, 6
    mov [vel_y], ax
    call draw_pads
    call draw_ball
    ret

; сетка, счёт, очистка поля
draw_static:
    pusha
    mov dh, TOP
    mov dl, LEFT
    mov ch, ROWS
    mov cl, COLS
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    mov dh, TOP
    mov dl, LEFT + COLS / 2
    mov cx, ROWS
.net:
    test dh, 1
    jnz .skip
    mov al, 0xB3
    mov bl, C_NET
    FAPI FAPI_PUTAT
.skip:
    inc dh
    loop .net
    ; счёт
    mov al, [sc_l]
    xor ah, ah
    mov dh, 0
    mov dl, 34
    mov bl, 0x0F
    mov cl, 2
    call g_num_at
    FAPI_PUTSAT 0, 36, msg_sep, 0x08
    mov al, [sc_r]
    xor ah, ah
    mov dh, 0
    mov dl, 40
    mov bl, 0x0C
    mov cl, 2
    call g_num_at
    popa
    ret

draw_pads:
    pusha
    ; стереть столбцы ракеток и нарисовать заново
    mov dh, TOP
    mov dl, PX_L
    mov ch, ROWS
    mov cl, 1
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    mov dl, PX_R
    FAPI FAPI_FILLRECT
    mov dh, [pad_l]
    mov dl, PX_L
    mov ch, PADH
    mov cl, 1
    mov al, 0xDB
    mov bl, C_PAD
    FAPI FAPI_FILLRECT
    mov dh, [pad_r]
    mov dl, PX_R
    mov bl, C_CPU
    FAPI FAPI_FILLRECT
    popa
    ret

draw_ball:
    pusha
    mov ax, [ball_x]
    mov cl, 4
    shr ax, cl
    mov [bcol], al
    mov ax, [ball_y]
    shr ax, cl
    mov [brow], al
    mov dh, [brow]
    mov dl, [bcol]
    mov al, 0x4F                    ; 'O'
    mov bl, C_BALL
    FAPI FAPI_PUTAT
    mov ax, [ball_x]
    mov [old_x], ax
    mov ax, [ball_y]
    mov [old_y], ax
    popa
    ret

erase_ball:
    pusha
    mov ax, [old_x]
    mov cl, 4
    shr ax, cl
    mov dl, al
    mov ax, [old_y]
    shr ax, cl
    mov dh, al
    mov al, ' '
    mov bl, 0x07
    cmp dl, LEFT + COLS / 2         ; на сетке — вернуть сетку
    jne .put
    test dh, 1
    jnz .put
    mov al, 0xB3
    mov bl, C_NET
.put:
    FAPI FAPI_PUTAT
    popa
    ret

msg_title   db " PONG  you vs CPU ", 0
msg_keys    db "W/S or arrows  P  Esc", 0
msg_sep     db " : ", 0
msg_pause   db " PAUSE ", 0
msg_nopause db " :     ", 0
msg_win     db "    YOU WIN!     ", 0
msg_lose    db "   CPU WINS...   ", 0
msg_again   db " Enter = again   ", 0
sc_l        db 0
sc_r        db 0
pad_l       db 0
pad_r       db 0
cpu_tick    db 0
ball_x      dw 0
ball_y      dw 0
old_x       dw 0
old_y       dw 0
vel_x       dw 0
vel_y       dw 0
bcol        db 0
brow        db 0
hit_off     db 0
