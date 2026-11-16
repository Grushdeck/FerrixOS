;======================================
; File name: apps/bin.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: hex — десятичное число в двоичное (BIN.FAP)
;======================================
; Запуск: bin N   (без аргумента — спросит)
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, 0x80
    call u_skip_sp
    cmp byte [si], 0
    jne .have
    mov si, prompt
    call u_puts
    call read_num
.have:
    call u_parse_uint
    push ax
    mov si, res
    call u_puts
    pop ax
    call put_bin
    call u_crlf
    FAPI_QUIT
; простой ввод строки в buf -> SI
read_num:
    mov di, buf
.rn_l:
    FAPI FAPI_GETKEY
    cmp al, 13
    je .rn_d
    cmp al, 8
    je .rn_bs
    cmp al, '0'
    jb .rn_l
    cmp al, '9'
    ja .rn_l
    cmp di, buf + 6
    jae .rn_l
    stosb
    call u_putc
    jmp .rn_l
.rn_bs:
    cmp di, buf
    je .rn_l
    dec di
    mov si, bs
    call u_puts
    jmp .rn_l
.rn_d:
    mov byte [di], 0
    call u_crlf
    mov si, buf
    ret
%include "sysutil.inc"
prompt db "Dec: ", 0
res    db "0b", 0
bs     db 8, " ", 8, 0
buf    times 8 db 0
; AX -> 16 двоичных цифр
put_bin:
    mov bx, ax
    mov cx, 16
.pb:
    shl bx, 1
    mov al, '0'
    jnc .z
    mov al, '1'
.z:
    call u_putc
    loop .pb
    ret
