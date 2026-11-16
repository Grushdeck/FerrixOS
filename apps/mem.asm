;======================================
; File name: apps/mem.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: mem — базовая и расширенная память (MEM.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, conv
    call u_puts
    int 0x12
    call u_dec
    mov si, kb
    call u_puts
    mov si, ext
    call u_puts
    mov ah, 0x88
    int 0x15
    jc .noext
    call u_dec
    mov si, kb
    call u_puts
    jmp .done
.noext:
    mov si, na
    call u_puts
.done:
    FAPI_QUIT
%include "sysutil.inc"
conv db "Conventional: ", 0
kb   db " KB", 13,10, 0
ext  db "Extended: ", 0
na   db "n/a", 13,10, 0
