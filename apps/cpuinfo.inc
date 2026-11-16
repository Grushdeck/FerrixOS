;======================================
; File name: apps/cpuinfo.inc
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: определение процессора для программ (CPU.FAP, FETCH.FAP) — копия логики ядра
;======================================
; cpu_probe: [cpu_level] 0=8086/88, 1=286, 2=386+ без CPUID, 3=CPUID.
; Заполняет cpu_v0 (vendor), cpu_leaf1, cpu_brand (пусто, если нет).
; cpu_name_ptr: SI -> короткое имя процессора.
%ifndef CPUINFO_INC
%define CPUINFO_INC
cpu_probe:
    pusha
    mov byte [cpu_level], 0
    mov byte [cpu_brand], 0
    push sp
    pop ax
    cmp ax, sp
    jne .cp_done
    mov byte [cpu_level], 1
    pushf
    pop ax
    mov bx, ax
    xor ax, 0xF000
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    xor ax, bx
    and ax, 0xF000
    jz .cp_done                     ; 286: биты 12-15 не меняются
    mov byte [cpu_level], 2
    pushfd
    pop eax
    mov ebx, eax
    xor eax, 0x00200000
    push eax
    popfd
    pushfd
    pop eax
    push ebx
    popfd
    cmp eax, ebx
    je .cp_done                     ; 386/ранний 486: нет CPUID
    mov byte [cpu_level], 3
    xor eax, eax
    cpuid
    mov [cpu_v0], ebx
    mov [cpu_v0+4], edx
    mov [cpu_v0+8], ecx
    mov byte [cpu_v0+12], 0
    mov eax, 1
    cpuid
    mov [cpu_leaf1], eax
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .cp_done
    mov eax, 0x80000002
    cpuid
    mov [cpu_brand], eax
    mov [cpu_brand+4], ebx
    mov [cpu_brand+8], ecx
    mov [cpu_brand+12], edx
    mov eax, 0x80000003
    cpuid
    mov [cpu_brand+16], eax
    mov [cpu_brand+20], ebx
    mov [cpu_brand+24], ecx
    mov [cpu_brand+28], edx
    mov eax, 0x80000004
    cpuid
    mov [cpu_brand+32], eax
    mov [cpu_brand+36], ebx
    mov [cpu_brand+40], ecx
    mov [cpu_brand+44], edx
    mov byte [cpu_brand+48], 0
.cp_done:
    popa
    ret

; SI -> короткое имя процессора (brand без ведущих пробелов / vendor / класс)
cpu_name_ptr:
    cmp byte [cpu_level], 3
    jb .cn_old
    mov si, cpu_brand
.cn_trim:
    cmp byte [si], ' '
    jne .cn_chk
    inc si
    jmp .cn_trim
.cn_chk:
    cmp byte [si], 0
    jne .cn_ret
    mov si, cpu_v0
    ret
.cn_old:
    mov si, cpu_386_lbl
    cmp byte [cpu_level], 2
    je .cn_ret
    mov si, cpu_286_lbl
    cmp byte [cpu_level], 1
    je .cn_ret
    mov si, cpu_8086_lbl
.cn_ret:
    ret

cpu_level         db 0
cpu_v0            times 13 db 0
cpu_leaf1         dd 0
cpu_brand         times 49 db 0
cpu_386_lbl      db "80386/80486 (no CPUID)", 0
cpu_286_lbl      db "80286", 0
cpu_8086_lbl     db "8086/8088", 0
%endif
