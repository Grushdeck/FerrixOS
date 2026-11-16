;======================================
; File name: apps/banner.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: banner — баннер Ferrix и сводка о системе (BANNER.FAP)
;======================================
; Запуск: banner  — очищает экран, рисует баннер, ждёт клавишу
%include "fapi.inc"
    FAPI_HEADER
start:
    FAPI FAPI_CLS
    mov si, boot_art
    FAPI FAPI_PUTS
    mov si, fetch_info
    FAPI FAPI_PUTS
    FAPI FAPI_GETKEY
    FAPI_QUIT

boot_art:
    db "==========================================================", 13,10
    db "       "
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' ', ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' ', ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', 0xDB, 0xDB, ' '
    db 13, 10
    db "       "
    db 0xDB, 0xDB, ' ', ' ', ' ', ' ', ' ', ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', ' ', ' ', ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', 0xDB, 0xDB, ' '
    db ' ', ' ', 0xDB, 0xDB, 0xDB, ' ', ' ', ' '
    db ' ', 0xDB, 0xDB, ' ', 0xDB, 0xDB, ' ', ' '
    db 13, 10
    db "       "
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' ', ' ', ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' ', ' ', ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' ', ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' ', ' '
    db ' ', ' ', 0xDB, 0xDB, 0xDB, ' ', ' ', ' '
    db ' ', ' ', 0xDB, 0xDB, 0xDB, ' ', ' ', ' '
    db 13, 10
    db "       "
    db 0xDB, 0xDB, ' ', ' ', ' ', ' ', ' ', ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', ' ', ' ', ' '
    db 0xDB, 0xDB, ' ', ' ', 0xDB, 0xDB, ' ', ' '
    db 0xDB, 0xDB, ' ', ' ', 0xDB, 0xDB, ' ', ' '
    db ' ', ' ', 0xDB, 0xDB, 0xDB, ' ', ' ', ' '
    db ' ', 0xDB, 0xDB, ' ', 0xDB, 0xDB, ' ', ' '
    db 13, 10
    db "       "
    db 0xDB, 0xDB, ' ', ' ', ' ', ' ', ' ', ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, ' '
    db 0xDB, 0xDB, ' ', ' ', ' ', 0xDB, 0xDB, ' '
    db 13, 10
    db "                                                          ", 13,10
    db "                 |Ferrix OS v4.0 patch 1|                 ", 13,10
    db "        ======================================            ", 13,10
    db "        =        |16-bit Real Mode |         =            ", 13,10
    db "        ======================================            ", 13,10
    db "==========================================================", 13,10
    db 13,10, 0

fetch_info:
    db 1, 0x0B, "  OS      ", 1, 0x08, ": ", 1, 0x07, "Ferrix OS v4.0 patch 1", 13,10
    db 1, 0x0B, "  Kernel  ", 1, 0x08, ": ", 1, 0x07, "16-bit real mode", 13,10
    db 1, 0x0B, "  Shell   ", 1, 0x08, ": ", 1, 0x07, "fsh 1.1 (FSH.FAP)", 13,10
    db 1, 0x0B, "  FS      ", 1, 0x08, ": ", 1, 0x07, "FAT12/FAT16 (r/w)", 13,10
    db 1, 0x0B, "  Author  ", 1, 0x08, ": ", 1, 0x07, "Grushdeck", 13,10, 0
