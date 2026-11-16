;======================================
; File name: apps/osinfo.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: osinfo — кратко об ОС (OSINFO.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    mov si, msg
    FAPI FAPI_PUTS
    FAPI_QUIT
msg:
    db "OS: Ferrix OS v4.0 patch 1", 13,10
    db "Arch: x86 16-bit", 13,10
    db "FS: FAT12/FAT16 (r/w)", 13,10, 0
