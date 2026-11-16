;======================================
; File name: apps/echo.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: echo — напечатать аргументы (ECHO.FAP)
;======================================
; Запуск: echo TEXT
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, 0x80
    FAPI FAPI_PUTS
    mov si, crlf
    FAPI FAPI_PUTS
    FAPI_QUIT
crlf db 13,10, 0
