;======================================
; File name: apps/cpu.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: cpu — сведения о процессоре через CPUID (CPU.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
start:
    call cpu_probe
    cmp byte [cpu_level], 3
    jb .simple
    mov si, vendor_lbl
    call u_puts
    mov si, cpu_v0
    call u_puts
    call u_crlf
    mov si, family_lbl
    call u_puts
    mov ax, [cpu_leaf1]
    mov cl, 8
    shr ax, cl
    and ax, 0x0F
    call u_dec
    mov si, model_lbl
    call u_puts
    mov ax, [cpu_leaf1]
    mov cl, 4
    shr ax, cl
    and ax, 0x0F
    call u_dec
    mov si, step_lbl
    call u_puts
    mov ax, [cpu_leaf1]
    and ax, 0x0F
    call u_dec
    call u_crlf
    cmp byte [cpu_brand], 0
    je .mode
    mov si, brand_lbl
    call u_puts
    call cpu_name_ptr
    call u_puts
    call u_crlf
.mode:
    mov si, mode_lbl
    call u_puts
    jmp .done
.simple:
    mov si, cpu_lbl
    call u_puts
    call cpu_name_ptr
    call u_puts
    call u_crlf
.done:
    FAPI_QUIT
%include "sysutil.inc"
%include "cpuinfo.inc"
vendor_lbl db "Vendor  : ", 0
family_lbl db "Family  : ", 0
model_lbl  db "  Model: ", 0
step_lbl   db "  Step: ", 0
brand_lbl  db "Brand   : ", 0
mode_lbl   db "Mode    : 16-bit Real Mode", 13,10, 0
cpu_lbl    db "CPU: ", 0
