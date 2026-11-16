;======================================
; File name: apps/date.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: date — показать дату (DATE.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, msg
    call u_puts
    FAPI FAPI_DATE                  ; CX год, DH месяц, DL день, AL день недели
    push dx
    push ax
    mov ax, cx
    call u_dec
    mov al, '-'
    call u_putc
    pop ax
    pop dx
    push ax
    mov al, dh
    call u_dec2
    mov al, '-'
    call u_putc
    mov al, dl
    call u_dec2
    mov al, ' '
    call u_putc
    pop ax
    xor ah, ah
    mov si, ax
    shl si, 1
    mov si, [dows + si]
    call u_puts
    call u_crlf
    FAPI_QUIT
%include "sysutil.inc"
msg  db "Date: ", 0
dows dw d0, d1, d2, d3, d4, d5, d6
d0 db "Sunday", 0
d1 db "Monday", 0
d2 db "Tuesday", 0
d3 db "Wednesday", 0
d4 db "Thursday", 0
d5 db "Friday", 0
d6 db "Saturday", 0
