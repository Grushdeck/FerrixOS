;======================================
; File name: apps/time.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: time — показать время и часовой пояс (TIME.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, msg
    call u_puts
    FAPI FAPI_LOCALTIME             ; CH час, CL мин, DH сек
    mov al, ch
    call u_dec2
    mov al, ':'
    call u_putc
    mov al, cl
    call u_dec2
    mov al, ':'
    call u_putc
    mov al, dh
    call u_dec2
    mov si, utc
    call u_puts
    mov al, 1
    FAPI FAPI_SYSINFO               ; AL смещение, AH = RTC по UTC
    push ax
    test al, al
    js .neg
    push ax
    mov al, '+'
    call u_putc
    pop ax
    jmp .num
.neg:
    neg al
    push ax
    mov al, '-'
    call u_putc
    pop ax
.num:
    xor ah, ah
    call u_dec
    mov al, ')'
    call u_putc
    pop ax
    test ah, ah
    jz .done
    mov si, rtc
    call u_puts
.done:
    call u_crlf
    FAPI_QUIT
%include "sysutil.inc"
msg db "Time: ", 0
utc db " (UTC", 0
rtc db "  [RTC keeps UTC]", 0
