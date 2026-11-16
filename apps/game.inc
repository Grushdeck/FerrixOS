;======================================
; File name: apps/game.inc
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: общие помощники для игр на FAPI (подключать после fapi.inc)
;======================================
%ifndef GAME_INC
%define GAME_INC

; включается сразу после FAPI_HEADER: точка входа заголовка ведёт сюда,
; поэтому сразу передаём управление метке start программы
    jmp start

; AX = случайное число 0..CX-1 (CX > 0)
g_rand:
    push dx
    FAPI FAPI_RAND
    mul cx                          ; старшие биты качественнее младших
    mov ax, dx
    pop dx
    ret

; AX -> ASCIIZ десятичное в g_numbuf, SI -> строка
g_itoa:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.gi_div:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .gi_div
    mov si, g_numbuf
    mov di, si
.gi_pr:
    pop ax
    add al, '0'
    mov [di], al
    inc di
    loop .gi_pr
    mov byte [di], 0
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; напечатать AX в позиции DH,DL атрибутом BL, дополнив пробелами до CL знаков
g_num_at:
    push ax
    push cx
    push dx
    push si
    call g_itoa
    mov ah, FAPI_PUTSAT
    int API_INT
    ; дополнить
    mov si, g_numbuf
.gn_len:
    cmp byte [si], 0
    je .gn_lend
    inc si
    jmp .gn_len
.gn_lend:
    sub si, g_numbuf                ; SI = длина
    mov ax, si
    add dl, al
.gn_pad:
    cmp al, cl
    jae .gn_done
    push ax
    mov al, ' '
    mov ah, FAPI_PUTAT
    int API_INT
    pop ax
    inc dl
    inc al
    jmp .gn_pad
.gn_done:
    pop si
    pop dx
    pop cx
    pop ax
    ret

; прямоугольная рамка (двойная): DH,DL угол; CH высота, CL ширина (включая рамку); BL атрибут
g_frame:
    push ax
    push cx
    push dx
    push si
    ; верх
    mov al, 0xC9
    mov ah, FAPI_PUTAT
    int API_INT
    push dx
    push cx
    mov ch, 1
    sub cl, 2
    inc dl
    mov al, 0xCD
    mov ah, FAPI_FILLRECT
    int API_INT
    pop cx
    pop dx
    push dx
    add dl, cl
    dec dl
    mov al, 0xBB
    mov ah, FAPI_PUTAT
    int API_INT
    pop dx
    ; бока
    push dx
    push cx
    inc dh
    sub ch, 2
    mov al, 0xBA
    push cx
    mov cl, 1
    mov ah, FAPI_FILLRECT
    int API_INT
    pop cx
    add dl, cl
    dec dl
    mov cl, 1
    mov ah, FAPI_FILLRECT
    int API_INT
    pop cx
    pop dx
    ; низ
    add dh, ch
    dec dh
    mov al, 0xC8
    mov ah, FAPI_PUTAT
    int API_INT
    push dx
    push cx
    mov ch, 1
    sub cl, 2
    inc dl
    mov al, 0xCD
    mov ah, FAPI_FILLRECT
    int API_INT
    pop cx
    pop dx
    add dl, cl
    dec dl
    mov al, 0xBC
    mov ah, FAPI_PUTAT
    int API_INT
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ждать CX тиков, но прервать, если нажата клавиша (AX = клавиша или 0)
g_wait_key:
    push bx
    push cx
    push dx
    FAPI FAPI_TICKS
    mov bx, ax
    add bx, cx                      ; BX = целевой тик (младшее слово)
.gw_loop:
    FAPI FAPI_KEYHIT
    jnz .gw_key
    FAPI FAPI_TICKS
    sub ax, bx
    jns .gw_done                    ; дождались
    hlt
    jmp .gw_loop
.gw_key:
    FAPI FAPI_GETKEY
    jmp .gw_ret
.gw_done:
    xor ax, ax
.gw_ret:
    pop dx
    pop cx
    pop bx
    ret

; Прочитать/сохранить рекорд: DS:SI имя файла, [g_hiscore]
g_hi_load:
    push ax
    push cx
    push di
    mov word [g_hiscore], 0
    mov di, g_numbuf
    mov cx, 6
    FAPI FAPI_READFILE
    jc .hl_ret
    mov byte [g_numbuf + 6], 0
    mov si, g_numbuf
    xor ax, ax
.hl_p:
    mov cl, [si]
    cmp cl, '0'
    jb .hl_ok
    cmp cl, '9'
    ja .hl_ok
    sub cl, '0'
    xor ch, ch
    push cx
    mov cx, 10
    mul cx
    pop cx
    add ax, cx
    inc si
    jmp .hl_p
.hl_ok:
    mov [g_hiscore], ax
.hl_ret:
    pop di
    pop cx
    pop ax
    ret

g_hi_save:                          ; DS:SI имя файла, AX = значение
    push cx
    push di
    push si
    call g_itoa                     ; -> g_numbuf, SI
    mov di, g_numbuf
    mov cx, 0
.hs_len:
    cmp byte [di], 0
    je .hs_go
    inc di
    inc cx
    jmp .hs_len
.hs_go:
    pop si
    mov di, g_numbuf
    FAPI FAPI_WRITEFILE
    pop di
    pop cx
    ret

g_numbuf    times 8 db 0
g_hiscore   dw 0

%endif
