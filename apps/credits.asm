;======================================
; File name: apps/credits.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: credits — авторы (CREDITS.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, msg
    FAPI FAPI_PUTS
    FAPI_QUIT
msg:
    db 0xB0, "================================================", 0xB0, 13,10
    db 0xB0, "                    CREDITS                     ", 0xB0, 13,10
    db 0xB0, "================================================", 0xB0, 13,10
    db 0xB0, "  OS Name: Ferrix OS v4.0 patch 1               ", 0xB0, 13,10
    db 0xB0, "  Language: NASM Assembly                       ", 0xB0, 13,10
    db 0xB0, "  Made by: Grushdeck                            ", 0xB0, 13,10
    db 0xB0, "================================================", 0xB0, 13,10, 0
