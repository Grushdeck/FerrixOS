;======================================
; File name: apps/2048.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: 2048 — сдвигай плитки, складывай одинаковые (игра .FAP)
;======================================
; Управление: стрелки / WASD, R — новая игра, Esc — выход. Рекорд в /2048.HI.

%include "fapi.inc"

    FAPI_HEADER

%include "game.inc"

TW       equ 9                      ; ширина плитки
TH       equ 4                      ; высота плитки
GL       equ 21                     ; левый край поля
GT       equ 3                      ; верх поля
C_FRAME  equ 0x08

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov si, hi_name
    call g_hi_load
new_game:
    FAPI FAPI_CLS
    FAPI FAPI_KBFLUSH
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov di, grid
    mov cx, 16
    xor al, al
    rep stosb
    mov word [score], 0
    mov byte [won], 0
    call add_tile
    call add_tile
    FAPI_PUTSAT 0, 2, msg_title, 0x0F
    FAPI_PUTSAT 1, 2, msg_keys, 0x08
    FAPI_PUTSAT 24, 2, msg_help, 0x08
    ; рамка поля
    mov dh, GT - 1
    mov dl, GL - 1
    mov ch, TH * 4 + 2
    mov cl, TW * 4 + 2
    mov bl, C_FRAME
    call g_frame
    call draw
main_loop:
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    cmp al, 'r'
    je new_game
    cmp al, 'R'
    je new_game
    xor bx, bx                      ; направление: 0 left 1 right 2 up 3 down
    cmp ah, 0x4B
    je .go
    cmp al, 'a'
    je .go
    cmp al, 'A'
    je .go
    inc bx
    cmp ah, 0x4D
    je .go
    cmp al, 'd'
    je .go
    cmp al, 'D'
    je .go
    inc bx
    cmp ah, 0x48
    je .go
    cmp al, 'w'
    je .go
    cmp al, 'W'
    je .go
    inc bx
    cmp ah, 0x50
    je .go
    cmp al, 's'
    je .go
    cmp al, 'S'
    je .go
    jmp main_loop
.go:
    call move                       ; CF=1 если что-то сдвинулось
    jnc main_loop
    call add_tile
    call draw
    call check_end
    jnc main_loop
    ; игра окончена
    FAPI_PUTSAT 11, 28, msg_over, 0x4F
    FAPI_PUTSAT 12, 28, msg_again, 0x4F
.wait:
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    cmp al, 13
    jne .wait
    jmp new_game
quit:
    mov ax, [score]
    cmp ax, [g_hiscore]
    jbe .q
    mov si, hi_name
    call g_hi_save
.q:
    FAPI FAPI_CLS
    FAPI FAPI_UIREDRAW
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI_QUIT

; ---------- логика ----------
; BX = направление. Для каждой из 4 линий: индекс старта из таблицы, шаг
move:
    mov byte [moved], 0
    mov si, bx
    shl si, 1
    mov ax, [dir_step + si]
    mov [step], ax
    shl si, 1
    add si, dir_start               ; 4 стартовых индекса
    mov cx, 4
.line:
    push cx
    push si
    mov al, [si]
    xor ah, ah
    mov [lstart], ax
    ; собрать линию в tmp (4 байта)
    mov di, lstart
    mov bx, ax
    mov di, tmp
    mov cx, 4
.gather:
    mov al, [grid + bx]
    mov [di], al
    inc di
    add bx, [step]
    loop .gather
    call slide_tmp
    ; записать обратно
    mov bx, [lstart]
    mov si, tmp
    mov cx, 4
.scatter:
    lodsb
    cmp al, [grid + bx]
    je .same
    mov byte [moved], 1
.same:
    mov [grid + bx], al
    add bx, [step]
    loop .scatter
    pop si
    pop cx
    inc si
    loop .line
    cmp byte [moved], 0
    je .no
    stc
    ret
.no:
    clc
    ret

; сжать tmp[0..3] влево и слить пары; счёт добавляется
slide_tmp:
    ; 1) убрать нули
    call compress
    ; 2) слияние
    mov si, tmp
    mov cx, 3
.mg:
    mov al, [si]
    test al, al
    jz .next
    cmp al, [si + 1]
    jne .next
    inc al
    mov [si], al
    mov byte [si + 1], 0
    ; счёт += 2^al
    push cx
    mov cl, al
    mov ax, 1
    shl ax, cl
    add [score], ax
    pop cx
    cmp byte [si], 11               ; 2048
    jne .next
    mov byte [won], 1
.next:
    inc si
    loop .mg
    call compress
    ret

compress:
    push cx
    push si
    push di
    mov si, tmp
    mov di, tmp2
    mov word [tmp2], 0
    mov word [tmp2 + 2], 0
    mov cx, 4
.c:
    lodsb
    test al, al
    jz .z
    stosb
.z:
    loop .c
    mov ax, [tmp2]
    mov [tmp], ax
    mov ax, [tmp2 + 2]
    mov [tmp + 2], ax
    pop di
    pop si
    pop cx
    ret

; случайная пустая клетка <- 2 (90%) или 4
add_tile:
    push ax
    push bx
    push cx
    ; есть ли пустые?
    xor bx, bx
    mov cx, 16
.chk:
    cmp byte [grid + bx], 0
    je .have
    inc bx
    loop .chk
    jmp .done
.have:
    mov cx, 16
    call g_rand
    mov bx, ax
    cmp byte [grid + bx], 0
    jne .have
    mov cx, 10
    call g_rand
    mov byte [grid + bx], 1
    test ax, ax
    jnz .done
    mov byte [grid + bx], 2
.done:
    pop cx
    pop bx
    pop ax
    ret

; CF=1 если ходов нет
check_end:
    xor bx, bx
.e:
    mov al, [grid + bx]
    test al, al
    jz .ok
    ; сосед справа
    mov cx, bx
    and cx, 3
    cmp cx, 3
    je .nr
    cmp al, [grid + bx + 1]
    je .ok
.nr:
    cmp bx, 12
    jae .nd
    cmp al, [grid + bx + 4]
    je .ok
.nd:
    inc bx
    cmp bx, 16
    jb .e
    stc
    ret
.ok:
    clc
    ret

; ---------- вывод ----------
draw:
    pusha
    ; счёт
    FAPI_PUTSAT 0, 58, msg_score, 0x07
    mov ax, [score]
    mov dh, 0
    mov dl, 65
    mov bl, 0x0E
    mov cl, 6
    call g_num_at
    FAPI_PUTSAT 1, 58, msg_best, 0x07
    mov ax, [score]
    cmp ax, [g_hiscore]
    jbe .nb
    mov [g_hiscore], ax
.nb:
    mov ax, [g_hiscore]
    mov dh, 1
    mov dl, 65
    mov bl, 0x0A
    mov cl, 6
    call g_num_at
    cmp byte [won], 0
    je .nw
    FAPI_PUTSAT 1, 30, msg_won, 0x0E
.nw:
    xor bx, bx
.tile:
    mov ax, bx
    shr ax, 1
    shr ax, 1                       ; строка плитки
    mov cl, TH
    mul cl
    add al, GT
    mov dh, al
    mov ax, bx
    and ax, 3
    mov cl, TW
    mul cl
    add al, GL
    mov dl, al
    ; цвет по значению
    push bx
    mov al, [grid + bx]
    xor ah, ah
    mov si, ax
    mov bl, [colors + si]
    mov ch, TH
    mov cl, TW
    mov al, ' '
    push dx
    mov ah, FAPI_FILLRECT
    int API_INT
    pop dx
    ; число по центру
    pop bx
    mov al, [grid + bx]
    test al, al
    jz .next
    push bx
    mov cl, al
    mov ax, 1
    shl ax, cl
    call g_itoa                     ; SI -> строка
    ; длина
    push si
    xor cx, cx
.len:
    cmp byte [si], 0
    je .ld
    inc si
    inc cx
    jmp .len
.ld:
    pop si
    mov ax, TW
    sub ax, cx
    shr ax, 1
    add dl, al
    add dh, TH / 2 - 1
    mov al, [grid + bx]
    xor ah, ah
    mov bx, ax
    mov bl, [colors + bx]
    mov ah, FAPI_PUTSAT
    int API_INT
    pop bx
.next:
    inc bx
    cmp bx, 16
    jb .tile
    popa
    ret

; ---------- данные ----------
dir_start   db 0, 4, 8, 12          ; влево
            db 3, 7, 11, 15         ; вправо
            db 0, 1, 2, 3           ; вверх
            db 12, 13, 14, 15       ; вниз
dir_step    dw 1, -1, 4, -4
; атрибут плитки по показателю (фон + цвет текста)
colors      db 0x80, 0x70, 0x3F, 0x6F, 0xE0, 0xC0, 0xCF, 0x4F, 0xD0, 0x5F, 0x9F, 0x1F, 0x3F, 0xBF, 0xAF, 0x2F
msg_title   db "2048", 0
msg_keys    db "arrows/WASD move  R new game  Esc quit", 0
msg_help    db "Join the numbers and get to the 2048 tile!", 0
msg_score   db "Score:", 0
msg_best    db "Best :", 0
msg_won     db " You made 2048! ", 0
msg_over    db "   GAME OVER!   ", 0
msg_again   db " Enter = again  ", 0
hi_name     db "/2048.HI", 0
grid        times 16 db 0
tmp         times 4 db 0
tmp2        times 4 db 0
score       dw 0
step        dw 0
lstart      dw 0
moved       db 0
won         db 0
