;======================================
; File name: apps/fetch.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: fetch — сведения о системе в стиле neofetch (FETCH.FAP)
;======================================
%include "fapi.inc"
    FAPI_HEADER
FETCH_COL equ 24
start:
    FAPI FAPI_CLS
    call cpu_probe
    ; --- логотип слева: атрибут, строка, 0 ... 0xFF ---
    mov si, fetch_logo
    xor dh, dh
.logo:
    mov bl, [si]
    cmp bl, 0xFF
    je .logo_done
    inc si
    mov dl, 2
    push dx
    push si
    FAPI FAPI_PUTSAT
    pop si
    pop dx
.skip:
    lodsb
    test al, al
    jnz .skip
    inc dh
    jmp .logo
.logo_done:
    ; --- строка 0: NAME@ferrix ---
    mov di, userbuf
    FAPI FAPI_USERNAME
    mov si, userbuf
    call str_end
    mov si, host
    call str_cpy
    xor dh, dh
    mov si, userbuf
    mov bl, 0x0A
    call put_row
    ; --- строка 1 ---
    inc dh
    mov si, dash
    mov bl, 0x07
    call put_row
    ; --- OS ---
    inc dh
    mov si, f_os
    call label
    mov si, f_os_v
    call u_puts
    ; --- Host: дата BIOS из F000:FFF5 ---
    inc dh
    mov si, f_host
    call label
    mov si, f_host_v
    call u_puts
    push ds
    mov ax, 0xF000
    mov ds, ax
    mov si, 0xFFF5
    mov cx, 8
.bios:
    lodsb
    call u_putc
    loop .bios
    pop ds
    mov al, ')'
    call u_putc
    ; --- Kernel ---
    inc dh
    mov si, f_kernel
    call label
    mov si, f_kernel_v
    call u_puts
    ; --- Uptime ---
    inc dh
    mov si, f_uptime
    call label
    call uptime
    ; --- Shell ---
    inc dh
    mov si, f_shell
    call label
    mov si, f_shell_v
    call u_puts
    ; --- Resolution / Terminal ---
    inc dh
    mov si, f_res
    call label
    mov si, f_res_v
    call u_puts
    inc dh
    mov si, f_term
    call label
    mov si, f_term_v
    call u_puts
    ; --- CPU ---
    inc dh
    mov si, f_cpu
    call label
    call cpu_name_ptr
    call u_puts
    ; --- Memory ---
    inc dh
    mov si, f_mem
    call label
    int 0x12
    call u_dec
    mov si, f_mem_v1
    call u_puts
    mov ah, 0x88
    int 0x15
    jc .noext
    call u_dec
    mov si, f_mem_v2
    call u_puts
    jmp .disk
.noext:
    mov si, f_mem_noext
    call u_puts
.disk:
    ; --- Disk ---
    inc dh
    mov si, f_disk
    call label
    xor al, al
    FAPI FAPI_SYSINFO               ; AX занято, DX всего, CL 12/16, CH буква
    jc .nodisk
    push dx
    push cx
    mov [f_disk_l], ch
    push ax
    mov si, f_disk_l
    call u_puts
    pop ax
    call u_dec
    mov si, f_disk_v
    call u_puts
    pop cx
    pop ax
    call u_dec
    mov si, f_disk_v12
    cmp cl, 12
    je .dt
    mov si, f_disk_v16
.dt:
    call u_puts
    jmp .pal
.nodisk:
    mov si, f_disk_err
    call u_puts
.pal:
    ; --- палитра ---
    add dh, 2
    xor bl, bl
    call palette
    inc dh
    mov bl, 8
    call palette
    add dh, 2
    xor dl, dl
    FAPI FAPI_SETCUR
    FAPI_QUIT

; строка DH: текст SI с атрибутом BL в колонке FETCH_COL, курсор после него
put_row:
    push dx
    mov dl, FETCH_COL
    FAPI FAPI_PUTSAT
    pop dx
    ret
; метка SI голубым в строке DH, курсор за ней (для обычного вывода)
label:
    push bx
    push si
    call put_row
    call str_len                    ; CX
    mov dl, FETCH_COL
    add dl, cl
    FAPI FAPI_SETCUR
    pop si
    pop bx
    ret
; 8 цветных блоков с цвета BL в строке DH
palette:
    push cx
    push dx
    mov dl, FETCH_COL
    mov cx, 8
.pl:
    push cx
    push bx
    push dx
    mov cl, 4
    shl bl, cl
    mov al, ' '
    mov ch, 1
    mov cl, 3
    FAPI FAPI_FILLRECT
    pop dx
    pop bx
    inc bl
    add dl, 3
    pop cx
    loop .pl
    pop dx
    pop cx
    ret
; Uptime = TICKS - boot ticks (18.2 тика/с)
uptime:
    push dx
    FAPI FAPI_TICKS                 ; DX:AX
    mov cx, dx
    mov bx, ax
    mov al, 2
    FAPI FAPI_SYSINFO               ; DX:AX на момент загрузки
    sub bx, ax
    sbb cx, dx
    jnc .nowrap
    add bx, 0x00B0                  ; счётчик обнулился в полночь
    adc cx, 0x0018
.nowrap:
    mov ax, cx
    xor dx, dx
    mov cx, 18
    div cx                          ; старшее слово секунд
    push ax
    mov ax, bx
    div cx
    pop cx                          ; CX:AX секунды
    mov bx, 3600
    push ax
    mov ax, cx
    xor dx, dx
    div bx
    pop ax
    div bx                          ; AX часы, DX сек
    push dx
    call u_dec
    mov si, f_hours
    call u_puts
    pop ax
    xor dx, dx
    mov bx, 60
    div bx
    call u_dec
    mov si, f_mins
    call u_puts
    pop dx
    ret
; SI -> конец строки (DI на терминаторе)
str_end:
    mov di, si
.se:
    cmp byte [di], 0
    je .sd
    inc di
    jmp .se
.sd:
    ret
str_cpy:
    lodsb
    stosb
    test al, al
    jnz str_cpy
    ret
str_len:
    push si
    xor cx, cx
.sl:
    lodsb
    test al, al
    jz .sd
    inc cx
    jmp .sl
.sd:
    pop si
    ret

%include "sysutil.inc"
%include "cpuinfo.inc"
host       db "@ferrix", 0
dash       db "-----------", 0
f_os       db "OS: ", 0
f_os_v     db "Ferrix OS 4.0 patch 1 x86 (16-bit)", 0
f_host     db "Host: ", 0
f_host_v   db "IBM PC/AT compatible (BIOS ", 0
f_kernel   db "Kernel: ", 0
f_kernel_v db "ferrix-4.0p1-realmode", 0
f_uptime   db "Uptime: ", 0
f_hours    db " hours, ", 0
f_mins     db " mins", 0
f_shell    db "Shell: ", 0
f_shell_v  db "fsh 1.1", 0
f_res      db "Resolution: ", 0
f_res_v    db "80x25 (text, 16 colors)", 0
f_term     db "Terminal: ", 0
f_term_v   db "VGA console", 0
f_cpu      db "CPU: ", 0
f_mem      db "Memory: ", 0
f_mem_v1   db " KB base + ", 0
f_mem_v2   db " KB ext", 0
f_mem_noext db " KB base", 0
f_disk     db "Disk (", 0
f_disk_l   db "A:): ", 0
f_disk_v   db " KB / ", 0
f_disk_v12 db " KB (FAT12)", 0
f_disk_v16 db " KB (FAT16)", 0
f_disk_err db "n/a", 0
userbuf    times 40 db 0
fetch_logo:
    db 0x0C, "  "
    times 16 db 0xDB
    db 0
    db 0x0C, "  "
    times 16 db 0xDB
    db 0
    db 0x0C, "  "
    times 4 db 0xDB
    db 0
    db 0x0E, "  "
    times 4 db 0xDB
    db 0
    db 0x0E, "  "
    times 12 db 0xDB
    db 0
    db 0x0E, "  "
    times 12 db 0xDB
    db 0
    db 0x06, "  "
    times 4 db 0xDB
    db 0
    db 0x06, "  "
    times 4 db 0xDB
    db 0
    db 0x04, "  "
    times 4 db 0xDB
    db 0
    db 0x04, "  "
    times 4 db 0xDB
    db 0
    db 0x08, "  f e r r i x", 0
    db 0xFF