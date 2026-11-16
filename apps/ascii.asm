;======================================
; File name: apps/ascii.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: ascii — таблица ASCII 32..127 (ASCII.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    FAPI FAPI_CLS
    mov si, header
    call u_puts
    mov bx, 32
.row:
    mov di, 4
.col:
    mov al, bl
    call u_hex_byte
    mov al, ' '
    call u_putc
    mov al, bl
    call u_putc
    mov al, ' '
    call u_putc
    inc bx
    dec di
    jnz .col
    call u_crlf
    cmp bx, 128
    jb .row
    FAPI FAPI_GETKEY
    FAPI FAPI_CLS
    FAPI_QUIT
%include "sysutil.inc"
header:
    db "HEX CHR  HEX CHR  HEX CHR  HEX CHR", 13,10
    db "==================================", 13,10, 0
