;======================================
; File name: apps/sysutil.inc
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: мелкие помощники вывода для системных утилит (.FAP): числа, hex, строки
;======================================
%ifndef SYSUTIL_INC
%define SYSUTIL_INC

; SI -> ASCIIZ
u_puts:
    push ax
    FAPI FAPI_PUTS
    pop ax
    ret
u_crlf:
    push si
    mov si, u_crlf_s
    call u_puts
    pop si
    ret
; AL -> символ
u_putc:
    push ax
    FAPI FAPI_PUTC
    pop ax
    ret
; AX -> десятичное
u_dec:
    push ax
    push dx
    mov dx, ax
    FAPI FAPI_PRINTDEC
    pop dx
    pop ax
    ret
; AL -> две цифры
u_dec2:
    push ax
    xor ah, ah
    mov dl, 10
    div dl
    push ax
    add al, '0'
    call u_putc
    pop ax
    mov al, ah
    add al, '0'
    call u_putc
    pop ax
    ret
; AL -> 2 hex-цифры
u_hex_byte:
    push ax
    push cx
    mov ah, al
    mov cl, 4
    shr al, cl
    call .uh_nib
    mov al, ah
    and al, 0x0F
    call .uh_nib
    pop cx
    pop ax
    ret
.uh_nib:
    push ax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .uh_p
    add al, 7
.uh_p:
    call u_putc
    pop ax
    ret
; AX -> 4 hex-цифры
u_hex_word:
    push ax
    mov al, ah
    call u_hex_byte
    pop ax
    call u_hex_byte
    ret
; SI -> десятичное число без знака -> AX (SI за числом)
u_parse_uint:
    push bx
    push cx
    xor ax, ax
.pu_l:
    mov bl, [si]
    sub bl, '0'
    jb .pu_d
    cmp bl, 9
    ja .pu_d
    mov cx, 10
    mul cx
    xor bh, bh
    add ax, bx
    inc si
    jmp .pu_l
.pu_d:
    pop cx
    pop bx
    ret
; SI -> пропустить пробелы
u_skip_sp:
    cmp byte [si], ' '
    jne .ss_r
    inc si
    jmp u_skip_sp
.ss_r:
    ret
u_crlf_s    db 13,10, 0
%endif
