;======================================
; File name: kernel.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Kernel
;======================================
[bits 16]
[org 0x0000]

KSEG     equ 0x1000          ; сегмент ядра
APP_SEG  equ 0x4000          ; сегмент внешних программ (.FAP): 64 КБ
SCR_SEG  equ 0x5000          ; служебный сегмент ядра: панели fm, копия экрана, скрипты
APP_MAX  equ 0xF000          ; макс. размер образа программы
DIR_MAXS equ 32              ; макс. секторов каталога в буфере 2000:0000 (корень FAT16 — 512 записей)
API_INT  equ 0x80

kernel_start:
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFFE                  ; стек ядра — верх сегмента (образ ядра > 31 КБ)
    sti
    push ds
    xor ax, ax
    mov ds, ax
    mov al, [0x0500]
    mov bx, [0x7C18]                ; геометрия из BPB загрузочного сектора
    mov cx, [0x7C1A]
    pop ds
    mov [boot_drive], al
    test bx, bx
    jz .geo_def
    test cx, cx
    jz .geo_def
    mov [disk_spt], bx
    mov [disk_heads], cx
.geo_def:
    ; надёжнее спросить BIOS самим (int 13h/08h); BPB — запасной вариант
    push es
    mov ah, 0x08
    mov dl, [boot_drive]
    int 0x13
    pop es
    jc .geo_ok
    and cx, 0x3F
    jz .geo_ok
    mov [disk_spt], cx
    xor ax, ax
    mov al, dh
    inc ax
    mov [disk_heads], ax
.geo_ok:
    mov ax, cs                      ; int 13h/08h мог испортить регистры — восстановить
    mov ds, ax
    mov es, ax
    call vol_init                   ; параметры тома из BPB (FAT12 дискета / FAT16 диск)
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x6C]               ; запомнить тики BIOS на момент загрузки
    mov [boot_ticks], ax
    mov ax, [es:0x6E]
    mov [boot_ticks + 2], ax
    pop es
    call cpu_probe                  ; класс процессора нужен view/play(HDA)
    call api_install                ; int 80h — системные вызовы для .FAP
    call beep_short
    ; строка лога ядра через BIOS-телетайп и пауза ~1.5 с, чтобы лог загрузчика
    ; успел показаться на реальном железе (иначе экран очищается мгновенно)
    mov si, boot_log_msg
.bl_print:
    lodsb
    test al, al
    jz .bl_wait
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp .bl_print
.bl_wait:
    push es
    xor ax, ax
    mov es, ax
    mov bx, [es:0x046C]
.bl_loop:
    sti
    hlt
    mov ax, [es:0x046C]
    sub ax, bx
    cmp ax, 27
    jb .bl_loop
    pop es
    mov ax, 0x1003              ; отключить blink -> 16 цветов фона
    xor bl, bl
    int 0x10
    call clear_screen
    call draw_ui
    mov si, welcome_msg
    call print_cstring
    call mouse_init
    call user_load                  ; имя пользователя из USER.CFG
    jc .ks_first
    call user_greet                 ; повторный запуск — поздороваться
    call autoexec_run
    jmp shell_loop
.ks_first:
    call setup_wizard               ; первый запуск — мастер настройки
    call autoexec_run

shell_loop:
    call print_prompt
    mov word [get_max], 1022
    mov byte [get_hist], 1          ; стрелки вверх/вниз = история
    mov di, input_buffer
    call get_string
    ; убрать ведущие пробелы
    mov si, input_buffer
.sl_lead:
    cmp byte [si], ' '
    jne .sl_lead_done
    inc si
    jmp .sl_lead
.sl_lead_done:
    cmp si, input_buffer
    je .sl_go
    mov di, input_buffer
.sl_shift:
    lodsb
    stosb
    test al, al
    jnz .sl_shift
.sl_go:
    call exec_line
    jmp shell_loop

; Выполнить команду из input_buffer (используется шеллом и скриптами)
exec_line:
    push ds
    pop es                          ; команды рассчитывают на ES = DS
    mov si, input_buffer
    mov di, cmd_cd
    call str_match
    jc do_cd
    mov di, cmd_ls
    call str_match
    jc do_ls
    mov di, cmd_dir
    call str_match
    jc do_ls
    mov di, cmd_cat
    call str_match
    jc do_cat
    mov di, cmd_rm
    call str_match
    jc do_rm
    mov di, cmd_touch
    call str_match
    jc do_touch
    mov di, cmd_write
    call str_match
    jc do_write
    mov di, cmd_mkdir
    call str_match
    jc do_mkdir
    mov di, cmd_rename
    call str_match
    jc do_rename
    mov di, cmd_cp
    call str_match
    jc do_cp
    mov di, cmd_mv
    call str_match
    jc do_mv
    mov di, cmd_view
    call str_match
    jc do_view
    mov di, cmd_play
    call str_match
    jc do_play
    mov di, cmd_fetch
    call str_match
    jc do_fetch
    mov di, cmd_clear
    call str_match
    jc do_clear
    mov di, cmd_help
    call str_match
    jc do_help
    mov di, cmd_reboot
    call str_match
    jc do_reboot
    mov di, cmd_shutdown
    call str_match
    jc do_shutdown
    mov di, cmd_date
    call str_match
    jc do_date
    mov di, cmd_time
    call str_match
    jc do_time
    mov di, cmd_mem
    call str_match
    jc do_mem
    mov di, cmd_echo
    call str_match
    jc do_echo
    mov di, cmd_matrix
    call str_match
    jc do_matrix
    mov di, cmd_ascii
    call str_match
    jc do_ascii
    mov di, cmd_cpu
    call str_match
    jc do_cpu
    mov di, cmd_osinfo
    call str_match
    jc do_osinfo
    mov di, cmd_credits
    call str_match
    jc do_credits
    mov di, cmd_hex
    call str_match
    jc do_hex
    mov di, cmd_bin
    call str_match
    jc do_bin
    mov di, cmd_banner
    call str_match
    jc do_banner
    mov di, cmd_pwd
    call str_match
    jc do_pwd
    mov di, cmd_whoami
    call str_match
    jc do_whoami
    mov di, cmd_user
    call str_match
    jc do_user
    mov di, cmd_tz
    call str_match
    jc do_tz
    mov di, cmd_setup
    call str_match
    jc do_setup
    mov di, cmd_run
    call str_match
    jc do_run
    mov di, cmd_saver
    call str_match
    jc do_saver
    mov di, cmd_sh
    call str_match
    jc do_sh
    mov al, [input_buffer]
    test al, al
    jz .ex_ret
    call app_try_run                ; NAME.FAP в текущем каталоге или в корне
    jnc .ex_ret
    mov si, unknown_msg
    mov bl, 0x0C
    call print_attr
.ex_ret:
    ret

;=================== КОМАНДЫ ===================
do_ls:
    call list_root_dir
    ret
do_cat:
    call cat_command
    ret
do_rm:
    call rm_command
    ret
do_touch:
    call touch_command
    ret
do_write:
    call write_command
    ret
do_mkdir:
    call mkdir_command
    ret
do_rename:
    call rename_command
    ret
do_cp:
    call cp_command
    ret
do_mv:
    call mv_command
    ret
do_view:
    call view_command
    ret
do_play:
    call play_command
    ret
do_fetch:
    call fetch_command
    ret
do_cd:
    call cd_command
    ret
do_clear:
    call clear_screen
    call draw_ui
    ret
do_help:
    call help_command
    ret
do_reboot:
    mov si, reboot_msg
    call print_string
    mov ax, 0x0000
    mov ds, ax
    mov word [0x0472], 0x1234
    jmp 0xFFFF:0x0000
do_shutdown:
    call shutdown_system
    ret
do_date:
    call show_date
    ret
do_time:
    call show_time
    ret
do_mem:
    call show_memory
    ret
do_echo:
    call echo_command
    ret
do_matrix:
    call matrix_effect
    ret
do_ascii:
    call ascii_table
    ret
do_cpu:
    call cpu_detect
    ret
do_osinfo:
    mov si, osinfo_msg
    call print_string
    ret
do_credits:
    mov si, credits_msg
    call print_string
    ret
do_hex:
    call hex_converter
    ret
do_bin:
    call bin_converter
    ret
do_banner:
    call show_banner
    ret
do_pwd:
    call pwd_command
    ret
do_whoami:
    mov si, user_name
    call print_string
    mov si, newline
    call print_string
    ret
do_user:
    call user_command
    ret
do_tz:
    call tz_command
    ret
do_setup:
    call setup_wizard
    ret
do_run:
    call run_command
    ret
do_saver:
    call saver_command
    ret
do_sh:
    call sh_command
    ret

;=================== BEEP ===================
beep_short:
    pusha
    mov al, 0xB6
    out 0x43, al
    mov ax, 0x0533
    out 0x42, al
    mov al, ah
    out 0x42, al
    in al, 0x61
    or al, 0x03
    out 0x61, al
    push es
    mov ax, 0x0040
    mov es, ax
    mov dx, [es:0x6C]
    add dx, 2                       ; ~110 мс (пустой цикл на быстром ЦП неслышен)
.bs_wait:
    mov ax, [es:0x6C]
    cmp ax, dx
    jne .bs_wait
    pop es
    in al, 0x61
    and al, 0xFC
    out 0x61, al
    popa
    ret

;=================== CPU ===================
; cpu_probe: [cpu_level] 0=8086/88, 1=286, 2=386+ без CPUID, 3=CPUID.
; Заполняет cpu_v0 (vendor), cpu_leaf1, cpu_brand (пусто, если нет).
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

cpu_detect:
    pusha
    call cpu_probe
    cmp byte [cpu_level], 3
    jb .cd_simple
    mov si, cpu_vendor_lbl
    call print_string
    mov si, cpu_v0
    call print_string
    mov si, newline
    call print_string
    mov si, cpu_family_lbl
    call print_string
    mov ax, [cpu_leaf1]
    mov cl, 8
    shr ax, cl
    and ax, 0x0F
    call print_dec_ax
    mov si, cpu_model_lbl
    call print_string
    mov ax, [cpu_leaf1]
    mov cl, 4
    shr ax, cl
    and ax, 0x0F
    call print_dec_ax
    mov si, cpu_stepping_lbl
    call print_string
    mov ax, [cpu_leaf1]
    and ax, 0x0F
    call print_dec_ax
    mov si, newline
    call print_string
    cmp byte [cpu_brand], 0
    je .cd_mode
    mov si, cpu_brand_lbl
    call print_string
    call cpu_name_ptr
    call print_string
    mov si, newline
    call print_string
.cd_mode:
    mov si, cpu_16bit_lbl
    call print_string
    jmp .cd_done
.cd_simple:
    mov si, cpu_lbl
    call print_string
    call cpu_name_ptr
    call print_string
    mov si, newline
    call print_string
.cd_done:
    popa
    ret

;=================== fetch (как neofetch) ===================
FETCH_COL equ 24

fetch_command:
    pusha
    push es
    call clear_screen
    call cpu_probe
    ; --- логотип слева ---
    mov si, fetch_logo
    xor dh, dh
.fe_logo:
    mov bl, [si]
    cmp bl, 0xFF
    je .fe_logo_done
    inc si
    mov ah, 0x02
    xor bh, bh
    mov dl, 2
    int 0x10
    call print_attr                 ; SI -> за терминатором
    inc dh
    jmp .fe_logo
.fe_logo_done:
    ; --- строка 0: root@ferrix ---
    xor dh, dh
    call fetch_row
    mov si, prm_user
    mov bl, 0x0A
    call print_attr
    ; --- строка 1: подчёркивание ---
    inc dh
    call fetch_row
    mov si, fetch_dash
    mov bl, 0x07
    call print_attr
    ; --- OS ---
    inc dh
    mov si, f_os
    call fetch_label
    mov si, f_os_v
    call print_string
    ; --- Host (дата BIOS из F000:FFF5) ---
    inc dh
    mov si, f_host
    call fetch_label
    mov si, f_host_v
    call print_string
    push ds
    mov ax, 0xF000
    mov ds, ax
    mov si, 0xFFF5
    mov cx, 8
.fe_bios:
    lodsb
    call print_char
    loop .fe_bios
    pop ds
    mov al, ')'
    call print_char
    ; --- Kernel ---
    inc dh
    mov si, f_kernel
    call fetch_label
    mov si, f_kernel_v
    call print_string
    ; --- Uptime ---
    inc dh
    mov si, f_uptime
    call fetch_label
    call fetch_uptime
    ; --- Shell ---
    inc dh
    mov si, f_shell
    call fetch_label
    mov si, f_shell_v
    call print_string
    ; --- Resolution ---
    inc dh
    mov si, f_res
    call fetch_label
    mov si, f_res_v
    call print_string
    ; --- Terminal ---
    inc dh
    mov si, f_term
    call fetch_label
    mov si, f_term_v
    call print_string
    ; --- CPU ---
    inc dh
    mov si, f_cpu
    call fetch_label
    call cpu_name_ptr
    call print_string
    ; --- Memory ---
    inc dh
    mov si, f_mem
    call fetch_label
    int 0x12
    call print_dec_ax
    mov si, f_mem_v1
    call print_string
    mov ah, 0x88
    int 0x15
    jc .fe_noext
    call print_dec_ax
    mov si, f_mem_v2
    call print_string
    jmp .fe_disk
.fe_noext:
    mov si, f_mem_noext
    call print_string
.fe_disk:
    ; --- Disk ---
    inc dh
    mov si, f_disk
    call fetch_label
    call fetch_disk
    ; --- цветовая палитра ---
    add dh, 2
    xor bl, bl
    call fetch_palette
    inc dh
    mov bl, 8
    call fetch_palette
    ; курсор под всем этим
    add dh, 2
    mov ah, 0x02
    xor bh, bh
    xor dl, dl
    int 0x10
    pop es
    popa
    ret

; курсор в строку DH, колонку FETCH_COL
fetch_row:
    push ax
    push bx
    push dx
    mov ah, 0x02
    xor bh, bh
    mov dl, FETCH_COL
    int 0x10
    pop dx
    pop bx
    pop ax
    ret

; строка DH, метка SI голубым
fetch_label:
    push bx
    call fetch_row
    mov bl, 0x0B
    call print_attr
    pop bx
    ret

; 8 цветных блоков, начиная с цвета BL, в строке DH
fetch_palette:
    pusha
    call fetch_row
    mov dl, FETCH_COL
    mov cx, 8
.fp_loop:
    push cx
    mov ah, 0x02
    xor bh, bh
    int 0x10
    push bx
    mov cl, 4
    shl bl, cl
    mov ah, 0x09
    mov al, ' '
    mov cx, 3
    int 0x10
    pop bx
    inc bl
    add dl, 3
    pop cx
    loop .fp_loop
    popa
    ret

; Uptime из тиков BIOS (0040:006C), ~18.2 тика/с
fetch_uptime:
    pusha
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x6C]
    mov dx, [es:0x6E]
    sub ax, [boot_ticks]
    sbb dx, [boot_ticks + 2]
    jnc .fu_nowrap
    add ax, 0x00B0                  ; счётчик обнулился в полночь (0x1800B0 тиков/сутки)
    adc dx, 0x0018
.fu_nowrap:
    mov bx, 18
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    mov cx, ax                      ; старшее слово секунд
    pop ax
    div bx                          ; CX:AX = секунды
    mov bx, 3600
    push ax
    mov ax, cx
    xor dx, dx
    div bx
    pop ax
    div bx                          ; AX = часы, DX = остаток секунд
    push dx
    call print_dec_ax
    mov si, f_hours
    call print_string
    pop ax
    xor dx, dx
    mov bx, 60
    div bx
    call print_dec_ax
    mov si, f_mins
    call print_string
    pop es
    popa
    ret

; Параметры тома из BPB загрузочного сектора (он ещё лежит в 0000:7C00).
; Поддерживаются FAT12 и FAT16 с 512-байтным сектором и 1 сектором на кластер.
vol_init:
    pusha
    push ds
    xor ax, ax
    mov ds, ax
    cmp word [0x7C0B], 512          ; байт на сектор
    jne .vi_bad
    cmp byte [0x7C0D], 1            ; секторов на кластер
    jne .vi_bad
    mov ax, [0x7C0E]                ; зарезервированных
    mov [cs:fat_lba], ax
    mov bl, [0x7C10]                ; копий FAT
    mov [cs:fat_nfats], bl
    xor bh, bh
    mov cx, [0x7C16]                ; секторов в FAT
    mov [cs:fat_spf], cx
    push ax
    mov ax, cx
    mul bx
    pop cx
    add ax, cx                      ; root_lba = reserved + fats*spf
    mov [cs:root_lba], ax
    mov cx, [0x7C11]                ; записей в корне
    mov [cs:root_nent], cx
    mov bx, cx
    mov cl, 4
    shr bx, cl                      ; секторов в корне
    cmp bx, DIR_MAXS
    ja .vi_bad
    mov [cs:root_secs], bx
    add ax, bx                      ; first_data_sector
    mov dx, [0x7C13]                ; всего секторов (16 бит)
    test dx, dx
    jnz .vi_ts
    mov dx, [0x7C20]                ; 32-битное поле: младшее слово (том <= 32 МБ)
    cmp word [0x7C22], 0
    jne .vi_bad
.vi_ts:
    sub dx, ax                      ; кластеров данных
    jbe .vi_bad
    sub ax, 2
    mov [cs:data_lba], ax
    add dx, 2
    jc .vi_bad                      ; > 65534 кластеров — не влезает в 16 бит
    mov [cs:fat_nclus], dx
    sub dx, 2
    cmp dx, 4085
    jb .vi_12
    mov byte [cs:fat_is16], 1
    mov word [cs:fat_eoc], 0xFFF8
    mov word [cs:fat_eocv], 0xFFFF
    jmp .vi_ok
.vi_12:
    mov byte [cs:fat_is16], 0
    mov word [cs:fat_eoc], 0x0FF8
    mov word [cs:fat_eocv], 0x0FFF
.vi_ok:
    pop ds
    cmp byte [boot_drive], 0x80
    jb .vi_fd
    mov byte [f_disk_letter], 'C'
    mov byte [dir_hdr_letter], 'C'
.vi_fd:
    popa
    ret
.vi_bad:
    pop ds
    mov si, vol_bad_msg
    call print_string
    popa
    ret

; Занято/всего на томе по FAT (кластер = 512 байт)
fetch_disk:
    pusha
    call read_fat
    jc .fd_err
    xor bx, bx                      ; занятых кластеров
    mov cx, 2
.fd_loop:
    mov ax, cx
    call fat_next
    test ax, ax
    jz .fd_free
    inc bx
.fd_free:
    inc cx
    cmp cx, [fat_nclus]
    jb .fd_loop
    mov ax, bx
    shr ax, 1                       ; КБ
    call print_dec_ax
    mov si, f_disk_v
    call print_string
    mov ax, [fat_nclus]
    sub ax, 2
    shr ax, 1
    call print_dec_ax
    mov si, f_disk_v12
    cmp byte [fat_is16], 0
    je .fd_t
    mov si, f_disk_v16
.fd_t:
    call print_string
    jmp .fd_done
.fd_err:
    mov si, f_disk_err
    call print_string
.fd_done:
    popa
    ret

; print_attr: строка DS:SI с атрибутом BL от текущей позиции курсора
; (понимает CR/LF, SI остаётся за терминатором)
print_attr:
    push ax
    push bx
    push cx
    push dx
    xor bh, bh
    mov ah, 0x03
    int 0x10
.pa_loop:
    lodsb
    test al, al
    jz .pa_end
    cmp al, 13
    je .pa_cr
    cmp al, 10
    je .pa_lf
    mov ah, 0x02
    int 0x10
    mov ah, 0x09
    mov cx, 1
    int 0x10
    inc dl
    cmp dl, 80
    jb .pa_loop
    xor dl, dl
    inc dh
    jmp .pa_loop
.pa_cr:
    xor dl, dl
    jmp .pa_loop
.pa_lf:
    inc dh
    jmp .pa_loop
.pa_end:
    mov ah, 0x02
    int 0x10
    pop dx
    pop cx
    pop bx
    pop ax
    ret

;=================== SHUTDOWN ===================
shutdown_system:
    pusha
    mov si, shutdown_msg
    call print_string
    xor bx, bx
    mov es, bx
    mov di, bx
    mov ax, 0x5300
    xor bx, bx
    int 0x15
    jc .apm_fail
    cmp bx, 0x504D
    jne .apm_fail
    cmp ax, 0x0101
    jb .apm_fail
    xor bx, bx
    mov es, bx
    mov di, bx
    mov ax, 0x5301
    xor bx, bx
    int 0x15
    jc .apm_fail
    xor bx, bx
    mov es, bx
    mov di, bx
    mov ax, 0x530E
    xor bx, bx
    mov cx, 0x0101
    int 0x15
    xor bx, bx
    mov es, bx
    mov di, bx
    mov ax, 0x5308
    mov bx, 0x0001
    mov cx, 0x0001
    int 0x15
    jc .apm_fail
    xor bx, bx
    mov es, bx
    mov di, bx
    mov ax, 0x5307
    mov bx, 0x0001
    mov cx, 0x0003
    int 0x15
    jc .apm_fail
    mov cx, 0xFFFF
.w1:
    loop .w1
    xor bx, bx
    mov es, bx
    mov di, bx
    mov ax, 0x5307
    mov bx, 0x0001
    mov cx, 0x0003
    int 0x15
    mov cx, 0xFFFF
.w2:
    loop .w2
    mov si, halt_msg
    call print_string
    cli
.halt_loop:
    hlt
    jmp .halt_loop
.apm_fail:
    mov si, apm_fail_msg
    call print_string
    mov si, halt_msg
    call print_string
    cli
.apm_halt:
    hlt
    jmp .apm_halt

;=================== DISK I/O ===================
disk_read_retry:
    pusha
    push es
    sti
    mov [disk_sav_ax], ax
    mov [disk_sav_cx], cx
    mov [disk_sav_dx], dx
    mov [disk_sav_bx], bx
    mov [disk_sav_es], es
    mov byte [disk_retry_count], 3
.dr_retry:
    mov ax, [disk_sav_ax]
    mov cx, [disk_sav_cx]
    mov dx, [disk_sav_dx]
    mov bx, [disk_sav_bx]
    mov es, [disk_sav_es]
    mov dl, [boot_drive]
    mov ah, 0x02
    int 0x13
    jnc .dr_ok
    mov ah, 0x00
    mov dl, [boot_drive]
    int 0x13
    dec byte [disk_retry_count]
    jnz .dr_retry
    stc
    pop es
    popa
    ret
.dr_ok:
    clc
    pop es
    popa
    ret

disk_write_retry:
    pusha
    push es
    sti
    mov [disk_sav_ax], ax
    mov [disk_sav_cx], cx
    mov [disk_sav_dx], dx
    mov [disk_sav_bx], bx
    mov [disk_sav_es], es
    mov byte [disk_retry_count], 3
.dw_retry:
    mov ax, [disk_sav_ax]
    mov cx, [disk_sav_cx]
    mov dx, [disk_sav_dx]
    mov bx, [disk_sav_bx]
    mov es, [disk_sav_es]
    mov dl, [boot_drive]
    mov ah, 0x03
    int 0x13
    jnc .dw_ok
    mov ah, 0x00
    mov dl, [boot_drive]
    int 0x13
    dec byte [disk_retry_count]
    jnz .dw_retry
    stc
    pop es
    popa
    ret
.dw_ok:
    clc
    pop es
    popa
    ret

; LBA (AX) -> CH=цилиндр, CL=сектор, DH=головка. Дискета 1.44: 18 сект/дор, 2 головки
; LBA (AX) -> CHS (CH/CL/DH) по геометрии, которую загрузчик получил от BIOS
; (на флешке в режиме USB-HDD она не 18x2)
lba_to_chs:
    push ax
    push bx
    xor dx, dx
    div word [disk_spt]
    mov cl, dl
    inc cl
    xor dx, dx
    div word [disk_heads]
    mov ch, al
    mov dh, dl
    shl ah, 6                       ; биты 8-9 цилиндра
    or cl, ah
    pop bx
    pop ax
    ret

; Чтение 1 сектора LBA=AX в 0x2000:0
read_data_sector:
    push ax
    push bx
    push cx
    push dx
    push es
    call lba_to_chs
    mov ax, 0x2000
    mov es, ax
    xor bx, bx
    mov al, 1
    call disk_read_retry
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Запись 1 сектора LBA=AX из 0x3000:0
write_data_sector:
    push ax
    push bx
    push cx
    push dx
    push es
    call lba_to_chs
    mov ax, 0x3000
    mov es, ax
    xor bx, bx
    mov al, 1
    call disk_write_retry
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Текущий каталог ([cur_dir]: 0 = корень, иначе первый кластер) <-> 0x2000:0
; Корень: 14 секторов с LBA 19. Подкаталог: цепочка кластеров (макс. 14 секторов).
; После загрузки: [dir_sectors], [dir_nent] (кол-во записей), [dir_last] (посл. кластер)
load_dir:
    pusha
    push es
    mov ax, 0x2000
    mov es, ax
    mov ax, [cur_dir]
    test ax, ax
    jnz .ld_sub
    xor bx, bx
    mov ax, [root_lba]              ; корень: из BPB (дискета: LBA 19, 14 секторов)
    mov cx, [root_secs]
    call read_lba_n
    jc .ld_err
    mov ax, [root_secs]
    mov [dir_sectors], ax
    mov ax, [root_nent]
    mov [dir_nent], ax
    jmp .ld_ok
.ld_sub:
    call read_fat                   ; нужна для обхода цепочки
    jc .ld_err
    xor bx, bx
    mov word [dir_sectors], 0
.ld_next:
    cmp ax, [fat_eoc]
    jae .ld_sub_done
    cmp ax, 2
    jb .ld_sub_done
    cmp word [dir_sectors], DIR_MAXS
    jae .ld_sub_done
    mov [dir_last], ax
    push ax
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call lba_to_chs
    mov al, 1
    call disk_read_retry
    pop ax
    jc .ld_err
    add bx, 512
    inc word [dir_sectors]
    call fat_next
    jmp .ld_next
.ld_sub_done:
    mov ax, [dir_sectors]
    mov cl, 4
    shl ax, cl
    mov [dir_nent], ax
.ld_ok:
    clc
    jmp .ld_ret
.ld_err:
    stc
.ld_ret:
    pop es
    popa
    ret

store_dir:
    pusha
    push es
    mov ax, 0x2000
    mov es, ax
    mov ax, [cur_dir]
    test ax, ax
    jnz .sd_sub
    xor bx, bx
    mov ax, [root_lba]
    mov cx, [root_secs]
    call write_lba_n
    jc .sd_err
    jmp .sd_ok
.sd_sub:
    xor bx, bx
    mov si, [dir_sectors]
.sd_next:
    test si, si
    jz .sd_ok
    cmp ax, [fat_eoc]
    jae .sd_ok
    cmp ax, 2
    jb .sd_ok
    push ax
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call lba_to_chs
    mov al, 1
    call disk_write_retry
    pop ax
    jc .sd_err
    add bx, 512
    dec si
    call fat_next
    jmp .sd_next
.sd_ok:
    clc
    jmp .sd_ret
.sd_err:
    stc
.sd_ret:
    pop es
    popa
    ret

; AX = первый кластер каталога. CF=1 если в нём есть записи кроме "." / ".."
; (читает секторы в 0x2000:0 — буфер каталога нужно перезагрузить после вызова)
dir_is_empty:
    pusha
    push es
    mov bx, 0x2000
    mov es, bx
.de_next:
    cmp ax, [fat_eoc]
    jae .de_empty
    cmp ax, 2
    jb .de_empty
    push ax
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    pop ax
    jc .de_notempty
    xor si, si
    mov cx, 16
.de_ent:
    mov dl, [es:si]
    test dl, dl
    jz .de_empty
    cmp dl, 0xE5
    je .de_skip
    cmp dl, '.'
    je .de_skip
    jmp .de_notempty
.de_skip:
    add si, 32
    loop .de_ent
    call fat_next
    jmp .de_next
.de_empty:
    clc
    jmp .de_ret
.de_notempty:
    stc
.de_ret:
    pop es
    popa
    ret

; FAT не держится в памяти целиком (FAT16 на 32 МБ — 128 КБ): работает окно-кэш
; из 2 секторов (fat_cache) с отложенной записью. read_fat — «обновить»: сбросить
; грязное окно и забыть его (после смены тома/перед повторным чтением с диска).
read_fat:
    call fat_flush
    jc .rf_err
    mov word [fat_win], 0xFFFF
    clc
    ret
.rf_err:
    stc
    ret

; Чтение CX секторов начиная с LBA=AX в ES:BX, по одному (любая геометрия).
; CF=1 при ошибке.
read_lba_n:
    pusha
.rl_next:
    push ax
    push cx
    call lba_to_chs
    mov al, 1
    call disk_read_retry
    pop cx
    pop ax
    jc .rl_err
    inc ax
    add bx, 512
    loop .rl_next
    popa
    clc
    ret
.rl_err:
    popa
    stc
    ret

; Запись CX секторов начиная с LBA=AX из ES:BX, по одному.
write_lba_n:
    pusha
.wl_next:
    push ax
    push cx
    call lba_to_chs
    mov al, 1
    call disk_write_retry
    pop cx
    pop ax
    jc .wl_err
    inc ax
    add bx, 512
    loop .wl_next
    popa
    clc
    ret
.wl_err:
    popa
    stc
    ret

; Записать изменения FAT на диск (грязное окно — в ОБЕ копии FAT)
write_fats:
    call fat_flush
    ret

; --- окно FAT ---
; fat_window: AX = номер сектора внутри FAT -> окно fat_cache содержит секторы AX, AX+1
; (последний сектор FAT — один). Грязное окно перед сменой сбрасывается. CF=1 ошибка диска.
fat_window:
    cmp ax, [fat_win]
    je .fw_ok
    pusha
    push es
    push ax
    call fat_flush
    pop ax
    jc .fw_err
    mov [fat_win], ax
    mov cx, 2
    inc ax
    cmp ax, [fat_spf]
    jb .fw_two
    mov cx, 1                       ; последний сектор FAT
.fw_two:
    dec ax
    mov [fat_win_n], cx
    add ax, [fat_lba]
    push ds
    pop es
    mov bx, fat_cache
    call read_lba_n
    jc .fw_err
    pop es
    popa
.fw_ok:
    clc
    ret
.fw_err:
    mov word [fat_win], 0xFFFF
    pop es
    popa
    stc
    ret

; fat_flush: если окно грязное — записать его секторы во все копии FAT
fat_flush:
    cmp byte [fat_dirty], 0
    je .ff_ok
    cmp word [fat_win], 0xFFFF
    je .ff_ok
    pusha
    push es
    push ds
    pop es
    mov al, [fat_nfats]
    xor ah, ah
    mov dx, ax                      ; копий
    mov ax, [fat_win]
    add ax, [fat_lba]
.ff_copy:
    mov bx, fat_cache
    mov cx, [fat_win_n]
    call write_lba_n
    jc .ff_err
    add ax, [fat_spf]
    dec dx
    jnz .ff_copy
    mov byte [fat_dirty], 0
    pop es
    popa
.ff_ok:
    clc
    ret
.ff_err:
    pop es
    popa
    stc
    ret

; fat_ptr: AX = кластер -> BX = смещение записи в fat_cache (окно подгружено), CF=1 ошибка
fat_ptr:
    push ax
    push cx
    push dx
    mov bx, ax
    cmp byte [fat_is16], 0
    jne .fp_16
    shr bx, 1
    add bx, ax                      ; FAT12: кластер * 3 / 2
    jmp .fp_off
.fp_16:
    mov al, ah                      ; FAT16: сектор = кластер / 256 (кластер*2 не влезает в 16 бит)
    xor ah, ah
    and bx, 255
    shl bx, 1                       ; смещение = (кластер % 256) * 2
    jmp .fp_win
.fp_off:
    mov ax, bx
    mov cl, 9
    shr ax, cl                      ; сектор FAT
    and bx, 511
.fp_win:
    add bx, fat_cache
    call fat_window
    pop dx
    pop cx
    pop ax
    ret

; fat_get: AX = кластер -> AX = значение записи (FAT12 — 12 бит, FAT16 — 16 бит)
fat_get:
    push bx
    push cx
    push dx
    push ax
    call fat_ptr
    pop dx                          ; DX = кластер
    jc .fg_err
    mov ax, [bx]
    cmp byte [fat_is16], 0
    jne .fg_ret
    test dx, 1
    jz .fg_even
    mov cl, 4
    shr ax, cl
    jmp .fg_ret
.fg_even:
    and ax, 0x0FFF
.fg_ret:
    pop dx
    pop cx
    pop bx
    ret
.fg_err:
    mov ax, [fat_eocv]              ; ошибка диска — как конец цепочки
    pop dx
    pop cx
    pop bx
    ret

; fat_put: AX = кластер, DX = значение
fat_put:
    push ax
    push bx
    push cx
    push dx
    push si
    mov si, ax
    call fat_ptr
    jc .fpt_ret
    mov byte [fat_dirty], 1
    cmp byte [fat_is16], 0
    jne .fpt_16
    test si, 1
    jnz .fpt_odd
    mov [bx], dl
    mov al, dh
    and al, 0x0F
    mov ah, [bx + 1]
    and ah, 0xF0
    or ah, al
    mov [bx + 1], ah
    jmp .fpt_ret
.fpt_odd:
    mov al, [bx]
    and al, 0x0F
    mov ah, dl
    and ah, 0x0F
    mov cl, 4
    shl ah, cl
    or al, ah
    mov [bx], al
    mov al, dh
    and al, 0x0F
    shl al, cl
    mov ah, dl
    shr ah, cl
    or al, ah
    mov [bx + 1], al
    jmp .fpt_ret
.fpt_16:
    mov [bx], dx
.fpt_ret:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

;=================== cat ===================
cat_command:
    pusha
    mov si, input_buffer
    add si, 3
    call path_save
    call resolve_path
    jc .ct_patherr
    cmp byte [rp_isdir], 1
    je .ct_isdir
    call load_dir
    jc .ct_read_err
    call find_dir_entry
    jnc .ct_not_found
    push es
    mov ax, 0x2000
    mov es, ax
    test byte [es:si + 11], 0x10
    pop es
    jnz .ct_isdir
    push es
    mov ax, 0x2000
    mov es, ax
    mov ax, [es:si + 26]
    mov [cat_cluster], ax
    mov ax, [es:si + 28]
    mov [cat_size_lo], ax
    mov ax, [es:si + 30]
    mov [cat_size_hi], ax
    pop es
    call read_fat
    jc .ct_read_err
.ct_print_loop:
    mov ax, [cat_size_lo]
    or ax, [cat_size_hi]
    jz .ct_done
    mov ax, [cat_cluster]
    cmp ax, [fat_eoc]
    jae .ct_done
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .ct_read_err
    ; FIX: размер порции считаем ДО переключения DS
    mov cx, 512
    cmp word [cat_size_hi], 0
    jne .ct_amt_ok
    mov ax, [cat_size_lo]
    cmp ax, 512
    jae .ct_amt_ok
    mov cx, ax
.ct_amt_ok:
    push cx
    push ds
    mov ax, 0x2000
    mov ds, ax
    xor si, si
.ct_bytes:
    lodsb
    call print_char
    loop .ct_bytes
    pop ds
    pop cx
    mov ax, [cat_size_lo]
    sub ax, cx
    mov [cat_size_lo], ax
    jnc .ct_no_borrow
    dec word [cat_size_hi]
.ct_no_borrow:
    mov ax, [cat_cluster]
    call fat_next
    mov [cat_cluster], ax
    jmp .ct_print_loop
.ct_done:
    mov si, newline
    call print_string
    call path_restore
    popa
    ret
.ct_patherr:
    cmp byte [input_buffer + 3], 0
    jne .ct_perr2
    mov si, cat_usage
.ct_perr2:
    call print_string
    jmp .ct_done
.ct_not_found:
    mov si, cat_nfound
    call print_string
    jmp .ct_done
.ct_isdir:
    mov si, err_isdir
    call print_string
    jmp .ct_done
.ct_read_err:
    mov si, cat_err
    call print_string
    jmp .ct_done

;=================== rm ===================
rm_command:
    pusha
    push es
    mov si, input_buffer
    add si, 2
    call path_save
    call resolve_path
    jc .rm_patherr
    cmp byte [rp_isdir], 1
    je .rm_usage
    call fs_delete
    jc .rm_msg
    mov si, rm_ok
.rm_msg:
    call print_string
    jmp .rm_done
.rm_patherr:
    cmp byte [input_buffer + 2], 0
    jne .rm_msg
.rm_usage:
    mov si, rm_usage
    call print_string
.rm_done:
    call path_restore
    pop es
    popa
    ret

; Удалить cat_name из текущего каталога. CF=1 ошибка, SI -> сообщение
fs_delete:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    call load_dir
    jc .rm_read_err
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jnc .rm_not_found
    test byte [es:si + 11], 0x01
    jnz .rm_ro
    mov ax, [es:si + 26]
    mov [cat_cluster], ax
    test byte [es:si + 11], 0x10
    jz .rm_mark
    cmp byte [cat_name], '.'
    je .rm_not_found                ; "." и ".." удалять нельзя
    call dir_is_empty
    jc .rm_notempty
    call load_dir                   ; буфер был затёрт проверкой
    jc .rm_read_err
    call find_dir_entry
    jnc .rm_not_found
.rm_mark:
    mov byte [es:si], 0xE5
    call read_fat
    jc .rm_read_err
    mov ax, [cat_cluster]
    test ax, ax
    jz .rm_skip_chain
    call free_fat_chain
.rm_skip_chain:
    call write_fats
    jc .rm_write_err
    call store_dir
    jc .rm_write_err
    clc
    jmp .fd_ret
.rm_not_found:
    mov si, cat_nfound
    jmp .fd_fail
.rm_ro:
    mov si, rm_ro
    jmp .fd_fail
.rm_notempty:
    mov si, rm_notempty
    jmp .fd_fail
.rm_read_err:
.rm_write_err:
    mov si, cat_err
.fd_fail:
    stc
.fd_ret:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

;=================== touch ===================
touch_command:
    pusha
    push es
    mov si, input_buffer
    add si, 5
    call path_save
    call resolve_path
    jc .tc_patherr
    cmp byte [rp_isdir], 1
    je .tc_exists
    call read_fat
    jc .tc_read_err
    call load_dir
    jc .tc_read_err
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jc .tc_exists
    call find_free_slot
    jnc .tc_nospace
    mov di, si
    call fill_dir_entry             ; имя из cat_name, attr 0x20, всё по нулям
    call write_fats                 ; каталог мог вырасти
    jc .tc_write_err
    call store_dir
    jc .tc_write_err
    mov si, touch_ok
    call print_string
    jmp .tc_done
.tc_patherr:
    cmp byte [input_buffer + 5], 0
    jne .tc_pmsg
    mov si, touch_usage
.tc_pmsg:
    call print_string
    jmp .tc_done
.tc_exists:
    mov si, write_exists
    call print_string
    jmp .tc_done
.tc_nospace:
    mov si, write_nospace
    call print_string
    jmp .tc_done
.tc_read_err:
.tc_write_err:
    mov si, cat_err
    call print_string
.tc_done:
    call path_restore
    pop es
    popa
    ret

; Заполнить запись каталога ES:DI: имя cat_name, attr=0x20, cluster=0, size=0
fill_dir_entry:
    push ax
    push cx
    push si
    push di
    mov si, cat_name
    mov cx, 11
    rep movsb
    mov al, 0x20
    stosb                           ; +11 attr
    xor ax, ax
    mov cx, 10                      ; +12..+31 = 20 байт
    rep stosw
    pop di
    pop si
    pop cx
    pop ax
    ret

;=================== write ===================
write_command:
    pusha
    mov si, input_buffer
    add si, 5
    call path_save
    call resolve_path
    jc .wr_patherr
    cmp byte [rp_isdir], 1
    je .wr_usage
.wr_skip_sp:
    cmp byte [si], ' '
    jne .wr_at_text
    inc si
    jmp .wr_skip_sp
.wr_at_text:
    cmp byte [si], 0
    je .wr_usage
    mov [save_off], si
    mov [save_seg], ds
    xor cx, cx
.wr_len:
    cmp byte [si], 0
    je .wr_len_done
    inc cx
    inc si
    jmp .wr_len
.wr_len_done:
    mov [save_len], cx
    call save_file
    jc .wr_msg
    mov si, write_ok
.wr_msg:
    call print_string
    jmp .wr_done
.wr_patherr:
    cmp byte [input_buffer + 5], 0
    jne .wr_msg
.wr_usage:
    mov si, write_usage
    call print_string
.wr_done:
    call path_restore
    popa
    ret

; save_file: записать [save_seg]:[save_off], длина [save_len], в файл cat_name
; (создаёт или перезаписывает). CF=0 ок; CF=1 ошибка, SI -> сообщение.
save_file:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    mov ax, [save_len]
    add ax, 511
    mov cl, 9
    shr ax, cl
    mov [write_nclusters], ax
    call read_fat
    jc .sf_ioerr
    call load_dir
    jc .sf_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jc .sf_overwrite
    call find_free_slot
    jnc .sf_nospace
    mov [write_slot], si
    mov word [wr_old_cluster], 0
    jmp .sf_allocate
.sf_overwrite:
    test byte [es:si + 11], 0x10
    jnz .sf_isdir
    test byte [es:si + 11], 0x01
    jnz .sf_ro
    mov [write_slot], si
    mov ax, [es:si + 26]
    mov [wr_old_cluster], ax
.sf_allocate:
    ; сначала выделяем новую цепочку, только потом освобождаем старую
    xor ax, ax
    mov bx, [write_nclusters]
    test bx, bx
    jz .sf_alloc_done               ; пустой файл: кластер 0
    call alloc_chain
    test ax, ax
    jz .sf_nospace
.sf_alloc_done:
    mov [new_cluster], ax
    mov ax, [wr_old_cluster]
    test ax, ax
    jz .sf_entry
    call free_fat_chain
.sf_entry:
    mov di, [write_slot]
    call fill_dir_entry
    mov ax, [new_cluster]
    mov [es:di + 26], ax
    mov ax, [save_len]
    mov [es:di + 28], ax
    mov ax, [new_cluster]
    mov [write_cur_cluster], ax
    mov ax, [save_len]
    mov [write_remaining], ax
.sf_loop:
    cmp word [write_remaining], 0
    je .sf_data_done
    push es
    mov ax, 0x3000
    mov es, ax
    xor di, di
    mov cx, 512
    xor al, al
    rep stosb
    xor di, di
    mov cx, [write_remaining]
    cmp cx, 512
    jbe .sf_amt
    mov cx, 512
.sf_amt:
    push cx
    mov si, [save_off]
    mov ax, [save_seg]
    push ds
    mov ds, ax
    rep movsb
    pop ds
    mov [save_off], si
    mov ax, [write_cur_cluster]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call write_data_sector
    pop cx
    pop es
    jc .sf_ioerr
    sub [write_remaining], cx
    mov ax, [write_cur_cluster]
    call fat_next
    mov [write_cur_cluster], ax
    jmp .sf_loop
.sf_data_done:
    call write_fats
    jc .sf_ioerr
    call store_dir
    jc .sf_ioerr
    clc
    jmp .sf_ret
.sf_isdir:
    mov si, err_isdir
    jmp .sf_fail
.sf_ro:
    mov si, rm_ro
    jmp .sf_fail
.sf_nospace:
    mov si, write_nospace
    jmp .sf_fail
.sf_ioerr:
    mov si, cat_err
.sf_fail:
    stc
.sf_ret:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

;=================== mkdir ===================
mkdir_command:
    pusha
    push es
    mov si, input_buffer
    add si, 5
    call path_save
    call resolve_path
    jc .mk_patherr
    cmp byte [rp_isdir], 1
    je .mk_exists
    call read_fat
    jc .mk_ioerr
    call load_dir
    jc .mk_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jc .mk_exists
    call find_free_slot
    jnc .mk_nospace
    mov [write_slot], si
    mov bx, 1
    call alloc_chain
    test ax, ax
    jz .mk_nospace
    mov [new_cluster], ax
    mov di, [write_slot]
    call fill_dir_entry
    mov byte [es:di + 11], 0x10     ; каталог
    mov ax, [new_cluster]
    mov [es:di + 26], ax
    ; содержимое нового каталога: "." и ".."
    mov ax, 0x3000
    mov es, ax
    xor di, di
    mov cx, 512
    xor al, al
    rep stosb
    xor di, di
    mov al, ' '
    mov cx, 11
    rep stosb
    mov byte [es:0], '.'
    mov byte [es:11], 0x10
    mov ax, [new_cluster]
    mov [es:26], ax
    mov di, 32
    mov al, ' '
    mov cx, 11
    rep stosb
    mov word [es:32], '..'
    mov byte [es:32 + 11], 0x10
    mov ax, [cur_dir]
    mov [es:32 + 26], ax            ; родитель = текущий каталог
    mov ax, [new_cluster]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call write_data_sector
    jc .mk_ioerr
    call write_fats
    jc .mk_ioerr
    call store_dir
    jc .mk_ioerr
    mov si, mkdir_ok
    call print_string
    jmp .mk_done
.mk_patherr:
    cmp byte [input_buffer + 5], 0
    jne .mk_pmsg
    mov si, mkdir_usage
.mk_pmsg:
    call print_string
    jmp .mk_done
.mk_exists:
    mov si, write_exists
    call print_string
    jmp .mk_done
.mk_nospace:
    mov si, write_nospace
    call print_string
    jmp .mk_done
.mk_ioerr:
    mov si, cat_err
    call print_string
.mk_done:
    call path_restore
    pop es
    popa
    ret

;=================== rename ===================
rename_command:
    pusha
    push es
    mov si, input_buffer
    add si, 6
    call path_save
    call resolve_path               ; старое имя (с путём) -> cat_name
    jc .rn_usage
    cmp byte [rp_isdir], 1
    je .rn_usage
    push si
    mov si, cat_name
    mov di, old_name
    call copy_name
    pop si
    call parse_filename             ; новое имя -> cat_name
    jc .rn_usage
    mov si, cat_name
    mov di, new_name
    call copy_name
    call load_dir
    jc .rn_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry             ; новое имя уже занято?
    jc .rn_exists
    mov si, old_name
    mov di, cat_name
    call copy_name
    call find_dir_entry
    jnc .rn_notfound
    mov di, si
    mov si, new_name
    mov cx, 11
    rep movsb                       ; DS:new_name -> ES:запись
    call store_dir
    jc .rn_ioerr
    mov si, rename_ok
    call print_string
    jmp .rn_done
.rn_usage:
    mov si, rename_usage
    call print_string
    jmp .rn_done
.rn_exists:
    mov si, write_exists
    call print_string
    jmp .rn_done
.rn_notfound:
    mov si, cat_nfound
    call print_string
    jmp .rn_done
.rn_ioerr:
    mov si, cat_err
    call print_string
.rn_done:
    call path_restore
    pop es
    popa
    ret

; 11 байт DS:SI -> DS:DI
copy_name:
    push ax
    push cx
    push si
    push di
    mov cx, 11
.cn_loop:
    lodsb
    mov [di], al
    inc di
    loop .cn_loop
    pop di
    pop si
    pop cx
    pop ax
    ret

;=================== cp / mv ===================
CP_SEG   equ 0x6000              ; буфер копирования (до 60 КБ)
CP_MAX   equ 0xF000

; Прочитать файл cat_name из текущего каталога в CP_SEG:0 (сегмент растёт,
; файлы > 64 КБ допустимы). Лимит — [rf_limit] (dword), размер -> [rf_size]
; (dword) и [save_len] (младшее слово). CF=1 ошибка, SI -> сообщение
read_file:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    call load_dir
    jc .rf_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jnc .rf_nf
    test byte [es:si + 11], 0x10
    jnz .rf_isdir
    mov ax, [es:si + 26]
    mov [cat_cluster], ax
    mov ax, [es:si + 28]
    mov [cat_size_lo], ax
    mov [rf_size], ax
    mov [save_len], ax
    mov dx, [es:si + 30]
    mov [cat_size_hi], dx
    mov [rf_size + 2], dx
    cmp dx, [rf_limit + 2]
    ja .rf_toobig
    jb .rf_size_ok
    cmp ax, [rf_limit]
    ja .rf_toobig
.rf_size_ok:
    call read_fat
    jc .rf_ioerr
    mov ax, CP_SEG
    mov es, ax
.rf_sector:
    mov ax, [cat_size_lo]
    or ax, [cat_size_hi]
    jz .rf_ok
    mov ax, [cat_cluster]
    cmp ax, [fat_eoc]
    jae .rf_ok
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .rf_ioerr
    mov cx, 512
    cmp word [cat_size_hi], 0
    jne .rf_amt
    cmp [cat_size_lo], cx
    jae .rf_amt
    mov cx, [cat_size_lo]
.rf_amt:
    sub [cat_size_lo], cx
    sbb word [cat_size_hi], 0
    push ds
    mov ax, 0x2000
    mov ds, ax
    xor si, si
    xor di, di
    rep movsb
    pop ds
    mov ax, es
    add ax, 32                      ; следующий сектор — следующие 512 байт
    mov es, ax
    mov ax, [cat_cluster]
    call fat_next
    mov [cat_cluster], ax
    jmp .rf_sector
.rf_ok:
    clc
    jmp .rf_ret
.rf_nf:
    mov si, cat_nfound
    jmp .rf_fail
.rf_isdir:
    mov si, err_isdir
    jmp .rf_fail
.rf_toobig:
    mov si, cp_toobig
    jmp .rf_fail
.rf_ioerr:
    mov si, cat_err
.rf_fail:
    stc
.rf_ret:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Разобрать путь назначения: если это существующий каталог (или путь
; кончается на '/') — войти в него и взять имя из old_name.
; CF=1 ошибка (SI -> сообщение)
resolve_dest:
    push ax
    push es
    call resolve_path
    jc .rd_ret
    cmp byte [rp_isdir], 1
    je .rd_use_src
    call load_dir
    jc .rd_ioerr
    mov ax, 0x2000
    mov es, ax
    push si
    call find_dir_entry
    jnc .rd_plain
    test byte [es:si + 11], 0x10
    jz .rd_plain
    pop si
    call cd_enter
    jc .rd_ret
.rd_use_src:
    push si
    mov si, old_name
    mov di, cat_name
    call copy_name
    pop si
    clc
    jmp .rd_ret
.rd_plain:
    pop si
    clc
    jmp .rd_ret
.rd_ioerr:
    mov si, cat_err
    stc
.rd_ret:
    pop es
    pop ax
    ret

; cp SRC DST  (только файлы; DST — имя, путь или каталог)
cp_command:
    pusha
    push es
    mov si, input_buffer
    add si, 2
    call path_save
    call resolve_path
    jc .cp_fail
    cmp byte [rp_isdir], 1
    je .cp_usage
    mov [arg2_ptr], si
    ; источник: каталог и имя запоминаем
    mov ax, [cur_dir]
    mov [cp_src_dir], ax
    mov si, cat_name
    mov di, cp_src_name
    call copy_name
    call path_restore
    mov si, [arg2_ptr]
    cmp byte [si], 0
    je .cp_usage
    mov si, cp_src_name
    mov di, old_name
    call copy_name
    mov si, [arg2_ptr]
    call resolve_dest
    jc .cp_fail
    mov ax, [cur_dir]
    mov [cp_dst_dir], ax
    mov si, cat_name
    mov di, cp_dst_name
    call copy_name
    ; тот же файл?
    cmp ax, [cp_src_dir]
    jne .cp_go
    mov si, cp_src_name
    mov di, cp_dst_name
    mov cx, 11
    repe cmpsb
    jne .cp_go
    mov si, cp_same
    jmp .cp_fail
.cp_go:
    call copy_stream
    jc .cp_fail
    mov si, cp_ok
    jmp .cp_fail
.cp_usage:
    mov si, cp_usage
.cp_fail:
    call print_string
    call path_restore
    pop es
    popa
    ret

; Потоковое копирование cp_src_dir/cp_src_name -> cp_dst_dir/cp_dst_name
; порциями по CP_MAX через CP_SEG (размер файла не ограничен). CF=1, SI -> сообщение
copy_stream:
    push ax
    push bx
    push cx
    push dx
    push es
    mov word [cs_sector], 0
    ; источник существует?
    mov ax, [cp_src_dir]
    mov [cur_dir], ax
    mov si, cp_src_name
    mov di, cat_name
    call copy_name
    call load_dir
    jc .cs_ioerr
    push es
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    pop es
    jnc .cs_nf
    ; создать/обрезать приёмник: пустой файл
    mov ax, [cp_dst_dir]
    mov [cur_dir], ax
    mov si, cp_dst_name
    mov di, cat_name
    call copy_name
    mov word [save_len], 0
    mov word [save_seg], ds
    mov word [save_off], 0
    call save_file
    jc .cs_err
.cs_loop:
    mov ax, [cp_src_dir]
    mov [cur_dir], ax
    mov si, cp_src_name
    mov di, cat_name
    call copy_name
    mov ax, CP_SEG
    mov es, ax
    xor di, di
    mov cx, CP_MAX
    mov bx, [cs_sector]
    call file_read_chunk            ; -> AX байт
    jc .cs_err
    test ax, ax
    jz .cs_done
    mov [save_len], ax
    mov word [save_seg], CP_SEG
    mov word [save_off], 0
    push ax
    mov ax, [cp_dst_dir]
    mov [cur_dir], ax
    mov si, cp_dst_name
    mov di, cat_name
    call copy_name
    call file_append
    pop ax
    jc .cs_err
    cmp ax, CP_MAX
    jb .cs_done
    add word [cs_sector], CP_MAX / 512
    jmp .cs_loop
.cs_done:
    clc
    jmp .cs_ret
.cs_nf:
    mov si, cat_nfound
    jmp .cs_err
.cs_ioerr:
    mov si, cat_err
.cs_err:
    stc
.cs_ret:
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Прочитать кусок файла cat_name (текущий каталог) начиная с сектора BX (512-байтные
; блоки) в ES:DI, не более CX байт. -> AX = прочитано (0 = конец). CF=1 ошибка, SI -> сообщение
file_read_chunk:
    push bx
    push cx
    push dx
    push di
    push es
    mov [frc_max], cx
    mov [frc_skip], bx
    mov word [frc_done], 0
    call load_dir
    jc .frc_ioerr
    push es
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    pop es
    jnc .frc_nf
    push ds
    mov ax, 0x2000
    mov ds, ax
    test byte [si + 11], 0x10
    pop ds
    jnz .frc_isdir
    push ds
    mov ax, 0x2000
    mov ds, ax
    mov ax, [si + 26]
    mov cx, [si + 28]
    mov dx, [si + 30]
    pop ds
    mov [cat_cluster], ax
    ; остаток = размер - skip*512
    mov bx, [frc_skip]
    mov ax, bx
    shl ax, 1                       ; bx*512: младшее слово = (bx<<9) & FFFF
    mov al, 0
    ; ax = (bx & 0x7F) << 9 ; старшее = bx >> 7
    push bx
    and bx, 0x7F
    xchg bl, bh                     ; bx = (bx&7F)<<8
    shl bx, 1
    mov ax, bx
    pop bx
    push cx
    mov cl, 7
    shr bx, cl                      ; старшее слово смещения
    pop cx
    sub cx, ax
    sbb dx, bx
    jc .frc_eof                     ; смещение за концом
    mov [cat_size_lo], cx
    mov [cat_size_hi], dx
    call read_fat
    jc .frc_ioerr
    ; пропустить skip кластеров
    mov cx, [frc_skip]
.frc_skipl:
    jcxz .frc_read
    mov ax, [cat_cluster]
    cmp ax, [fat_eoc]
    jae .frc_eof
    call fat_next
    mov [cat_cluster], ax
    dec cx
    jmp .frc_skipl
.frc_read:
    mov ax, [cat_size_lo]
    or ax, [cat_size_hi]
    jz .frc_eof
    mov ax, [frc_max]
    sub ax, [frc_done]
    jz .frc_eof                     ; буфер полон
    mov ax, [cat_cluster]
    cmp ax, [fat_eoc]
    jae .frc_eof
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .frc_ioerr
    mov cx, 512
    cmp word [cat_size_hi], 0
    jne .frc_amt1
    cmp [cat_size_lo], cx
    jae .frc_amt1
    mov cx, [cat_size_lo]
.frc_amt1:
    mov ax, [frc_max]
    sub ax, [frc_done]
    cmp cx, ax
    jbe .frc_amt2
    mov cx, ax
.frc_amt2:
    sub [cat_size_lo], cx
    sbb word [cat_size_hi], 0
    add [frc_done], cx
    push ds
    mov ax, 0x2000
    mov ds, ax
    xor si, si
    rep movsb
    pop ds
    mov ax, [cat_cluster]
    call fat_next
    mov [cat_cluster], ax
    jmp .frc_read
.frc_eof:
    mov ax, [frc_done]
    clc
    jmp .frc_ret
.frc_nf:
    mov si, cat_nfound
    jmp .frc_fail
.frc_isdir:
    mov si, err_isdir
    jmp .frc_fail
.frc_ioerr:
    mov si, cat_err
.frc_fail:
    stc
.frc_ret:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    ret

; Дописать [save_len] байт из save_seg:save_off в конец файла cat_name (текущий каталог).
; Если файла нет — создаётся. CF=1 ошибка, SI -> сообщение
file_append:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    cmp word [save_len], 0
    je .fa_ok
    call read_fat
    jc .fa_ioerr
    call load_dir
    jc .fa_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jc .fa_found
    call save_file                  ; нет файла — обычное сохранение
    jmp .fa_ret_flags
.fa_found:
    test byte [es:si + 11], 0x10
    jnz .fa_isdir
    test byte [es:si + 11], 0x01
    jnz .fa_ro
    mov ax, [es:si + 28]
    mov [fa_size], ax
    mov dx, [es:si + 30]
    mov [fa_size + 2], dx
    or ax, dx
    jnz .fa_nonempty
    call save_file                  ; пустой файл — просто записать
    jmp .fa_ret_flags
.fa_nonempty:
    mov ax, [es:si + 26]
    ; дойти до последнего кластера: (size-1)/512 шагов
    mov cx, [fa_size]
    mov dx, [fa_size + 2]
    sub cx, 1
    sbb dx, 0
    push ax
    mov ax, cx
    mov al, ah
    mov ah, dl
    shr ax, 1                       ; (size-1) >> 9, младшие 16 бит
    mov cx, ax
    pop ax
.fa_walk:
    jcxz .fa_last
    call fat_next
    dec cx
    jmp .fa_walk
.fa_last:
    mov [fa_lastcl], ax
    mov ax, [fa_size]
    and ax, 511
    mov [fa_part], ax
    mov word [write_remaining], 0
    mov ax, [save_len]
    mov [write_remaining], ax
    cmp word [fa_part], 0
    je .fa_newclusters
    ; дозаполнить последний сектор
    mov ax, [fa_lastcl]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .fa_ioerr
    push ds
    push es
    mov ax, 0x2000
    mov ds, ax
    mov ax, 0x3000
    mov es, ax
    xor si, si
    xor di, di
    mov cx, 512
    rep movsb
    pop es
    pop ds
    mov cx, 512
    sub cx, [fa_part]
    cmp cx, [write_remaining]
    jbe .fa_fill
    mov cx, [write_remaining]
.fa_fill:
    push cx
    push es
    mov ax, 0x3000
    mov es, ax
    mov di, [fa_part]
    push ds
    mov si, [save_off]
    mov ds, [save_seg]
    rep movsb
    pop ds
    mov [save_off], si
    pop es
    mov ax, [fa_lastcl]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call write_data_sector
    pop cx
    jc .fa_ioerr
    sub [write_remaining], cx
.fa_newclusters:
    cmp word [write_remaining], 0
    je .fa_update
    mov ax, [write_remaining]
    add ax, 511
    mov cl, 9
    shr ax, cl
    mov bx, ax
    call alloc_chain
    test ax, ax
    jz .fa_nospace
    mov [write_cur_cluster], ax
    mov dx, ax
    mov ax, [fa_lastcl]
    call set_fat_entry              ; связать цепочку
.fa_wloop:
    cmp word [write_remaining], 0
    je .fa_update
    push es
    mov ax, 0x3000
    mov es, ax
    xor di, di
    mov cx, 512
    xor al, al
    rep stosb
    xor di, di
    mov cx, [write_remaining]
    cmp cx, 512
    jbe .fa_amt
    mov cx, 512
.fa_amt:
    push cx
    push ds
    mov si, [save_off]
    mov ds, [save_seg]
    rep movsb
    pop ds
    mov [save_off], si
    mov ax, [write_cur_cluster]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call write_data_sector
    pop cx
    pop es
    jc .fa_ioerr
    sub [write_remaining], cx
    mov ax, [write_cur_cluster]
    call fat_next
    mov [write_cur_cluster], ax
    jmp .fa_wloop
.fa_update:
    call write_fats
    jc .fa_ioerr
    call load_dir                   ; буфер каталога затёрт чтением
    jc .fa_ioerr
    call find_dir_entry
    jnc .fa_ioerr
    mov ax, [save_len]
    add [es:si + 28], ax
    adc word [es:si + 30], 0
    call store_dir
    jc .fa_ioerr
.fa_ok:
    clc
    jmp .fa_ret
.fa_isdir:
    mov si, err_isdir
    jmp .fa_fail
.fa_ro:
    mov si, rm_ro
    jmp .fa_fail
.fa_nospace:
    mov si, write_nospace
    jmp .fa_fail
.fa_ioerr:
    mov si, cat_err
.fa_fail:
    stc
.fa_ret_flags:
.fa_ret:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; mv SRC DST — перенос записи каталога (файлы и каталоги, без копирования данных)
mv_command:
    pusha
    push es
    mov si, input_buffer
    add si, 2
    call path_save
    call resolve_path
    jc .mv_fail
    cmp byte [rp_isdir], 1
    je .mv_usage
    mov [arg2_ptr], si
    cmp byte [cat_name], '.'
    je .mv_usage
    mov si, cat_name
    mov di, old_name
    call copy_name
    ; --- взять запись из исходного каталога ---
    call load_dir
    jc .mv_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jnc .mv_nf
    mov di, mv_entry
    mov cx, 32
.mv_cp:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    loop .mv_cp
    mov ax, [cur_dir]
    mov [mv_src_dir], ax
    ; --- назначение ---
    call path_restore
    mov si, [arg2_ptr]
    cmp byte [si], 0
    je .mv_usage
    call resolve_dest
    jc .mv_fail
    ; тот же каталог и то же имя — ничего не делаем
    mov ax, [cur_dir]
    cmp ax, [mv_src_dir]
    jne .mv_check_loop
    mov si, cat_name
    mov di, old_name
    mov cx, 11
.mv_same:
    mov al, [si]
    cmp al, [di]
    jne .mv_check_loop
    inc si
    inc di
    loop .mv_same
    mov si, mv_ok
    jmp .mv_fail
.mv_check_loop:
    ; нельзя переносить каталог внутрь самого себя
    test byte [mv_entry + 11], 0x10
    jz .mv_insert
    mov ax, [cur_dir]
    mov cx, 64
.mv_walk:
    test ax, ax
    jz .mv_insert
    cmp ax, [mv_entry + 26]
    je .mv_loop_err
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .mv_ioerr
    mov ax, 0x2000
    mov es, ax
    mov ax, [es:32 + 26]            ; ".."
    loop .mv_walk
.mv_insert:
    call read_fat
    jc .mv_ioerr
    call load_dir
    jc .mv_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jc .mv_exists
    call find_free_slot
    jnc .mv_nospace
    mov di, si
    mov si, mv_entry
    mov cx, 32
    rep movsb                       ; DS:mv_entry -> ES:DI
    sub di, 32
    push di
    mov si, cat_name
    mov cx, 11
    rep movsb                       ; новое имя
    pop di
    call write_fats
    jc .mv_ioerr
    call store_dir
    jc .mv_ioerr
    ; у перенесённого каталога обновить ".."
    test byte [mv_entry + 11], 0x10
    jz .mv_delete_src
    mov ax, [mv_entry + 26]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .mv_ioerr
    push ds
    mov ax, 0x3000
    mov es, ax
    mov ax, 0x2000
    mov ds, ax
    xor si, si
    xor di, di
    mov cx, 256
    rep movsw
    pop ds
    mov ax, [cur_dir]
    mov [es:32 + 26], ax
    mov ax, [mv_entry + 26]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call write_data_sector
    jc .mv_ioerr
.mv_delete_src:
    mov ax, [mv_src_dir]
    mov [cur_dir], ax
    call load_dir
    jc .mv_ioerr
    mov ax, 0x2000
    mov es, ax
    mov si, old_name
    mov di, cat_name
    call copy_name
    call find_dir_entry
    jnc .mv_nf
    mov byte [es:si], 0xE5
    call store_dir
    jc .mv_ioerr
    mov si, mv_ok
    jmp .mv_fail
.mv_usage:
    mov si, mv_usage
    jmp .mv_fail
.mv_nf:
    mov si, cat_nfound
    jmp .mv_fail
.mv_exists:
    mov si, write_exists
    jmp .mv_fail
.mv_nospace:
    mov si, write_nospace
    jmp .mv_fail
.mv_loop_err:
    mov si, mv_loop
    jmp .mv_fail
.mv_ioerr:
    mov si, cat_err
.mv_fail:
    call print_string
    call path_restore
    pop es
    popa
    ret

;=================== view (BMP) ===================
; view FILE.BMP — режим 13h (320x200x256). BMP без сжатия: 8 бит (своя палитра),
; 24/32 бит (палитра RGB 3-3-2). Большие картинки уменьшаются целым шагом,
; маленькие центрируются. Нужен 386+ (32-битные регистры).
VIEW_MAX equ 0x3F000             ; 0x60000..0x9F000

view_command:
    pusha
    push es
    mov si, input_buffer
    add si, 4
    call path_save
    call resolve_path
    jc .vw_fail
    cmp byte [rp_isdir], 1
    je .vw_usage
    call cpu_probe
    cmp byte [cpu_level], 2
    jb .vw_cpu
    mov word [rf_limit], VIEW_MAX & 0xFFFF
    mov word [rf_limit + 2], VIEW_MAX >> 16
    call read_file
    jc .vw_fail
    call bmp_parse
    jc .vw_fail
    call bmp_show
    call wait_key
    call clear_screen               ; mode 3
    call draw_ui
    jmp .vw_done
.vw_cpu:
    mov si, view_cpu
    jmp .vw_fail
.vw_usage:
    mov si, view_usage
.vw_fail:
    call print_string
.vw_done:
    call path_restore
    pop es
    popa
    ret

; Разбор заголовка BMP в CP_SEG:0. CF=1 ошибка (SI -> сообщение)
bmp_parse:
    push eax
    push ebx
    push ecx
    push edx
    push es
    mov ax, CP_SEG
    mov es, ax
    cmp word [rf_size], 54
    jb .bp_bad
    cmp word [es:0], 'BM'
    jne .bp_bad
    mov eax, [es:10]
    mov [bmp_data], eax
    mov eax, [es:18]
    cmp eax, 0
    jle .bp_bad
    cmp eax, 20000
    ja .bp_big
    mov [bmp_w], ax
    mov byte [bmp_topdown], 0
    mov eax, [es:22]
    test eax, eax
    jz .bp_bad
    jns .bp_hpos
    neg eax
    mov byte [bmp_topdown], 1
.bp_hpos:
    cmp eax, 20000
    ja .bp_big
    mov [bmp_h], ax
    cmp dword [es:30], 0            ; BI_RGB
    jne .bp_unsup
    mov ax, [es:28]
    mov [bmp_bpp], ax
    cmp ax, 8
    je .bp_bpp_ok
    cmp ax, 24
    je .bp_bpp_ok
    cmp ax, 32
    jne .bp_unsup
.bp_bpp_ok:
    ; stride = ((w*bpp + 31) / 32) * 4
    movzx eax, word [bmp_w]
    movzx ebx, word [bmp_bpp]
    mul ebx
    add eax, 31
    shr eax, 5
    shl eax, 2
    mov [bmp_stride], eax
    ; строка должна умещаться в 64 КБ (адресуем 16-битным смещением)
    cmp eax, 0xF000
    ja .bp_big
    ; палитра: смещение 14 + размер инфозаголовка, число цветов
    mov eax, [es:14]
    add eax, 14
    mov [bmp_pal], ax
    mov eax, [es:46]
    test eax, eax
    jnz .bp_ncol
    mov eax, 256
.bp_ncol:
    cmp eax, 256
    jbe .bp_ncol_ok
    mov eax, 256
.bp_ncol_ok:
    mov [bmp_ncol], ax
    ; шаг уменьшения
    mov cx, 1
.bp_step:
    mov ax, 320
    mul cx
    cmp ax, [bmp_w]
    jb .bp_step_inc
    mov ax, 200
    mul cx
    cmp ax, [bmp_h]
    jae .bp_step_ok
.bp_step_inc:
    inc cx
    jmp .bp_step
.bp_step_ok:
    mov [bmp_step], cx
    mov ax, [bmp_w]
    xor dx, dx
    div cx
    mov [bmp_dw], ax
    mov ax, [bmp_h]
    xor dx, dx
    div cx
    mov [bmp_dh], ax
    clc
    jmp .bp_ret
.bp_bad:
    mov si, view_bad
    jmp .bp_fail
.bp_big:
    mov si, view_big
    jmp .bp_fail
.bp_unsup:
    mov si, view_unsup
.bp_fail:
    stc
.bp_ret:
    pop es
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; Вывод картинки
bmp_show:
    pushad
    push ds
    push es
    mov ax, 0x0013
    int 0x10
    ; --- палитра ---
    mov dx, 0x3C8
    xor al, al
    out dx, al
    inc dx
    cmp word [bmp_bpp], 8
    jne .bs_pal332
    mov ax, CP_SEG
    mov es, ax
    mov si, [bmp_pal]
    mov cx, [bmp_ncol]
.bs_pal8:
    mov al, [es:si + 2]             ; R
    shr al, 2
    out dx, al
    mov al, [es:si + 1]             ; G
    shr al, 2
    out dx, al
    mov al, [es:si]                 ; B
    shr al, 2
    out dx, al
    add si, 4
    loop .bs_pal8
    jmp .bs_draw
.bs_pal332:
    xor cx, cx
.bs_p332:
    mov al, cl
    shr al, 5
    mov ah, 9
    mul ah                          ; R: 0..7 -> 0..63
    out dx, al
    mov al, cl
    shr al, 2
    and al, 7
    mov ah, 9
    mul ah
    out dx, al
    mov al, cl
    and al, 3
    mov ah, 21                      ; B: 0..3 -> 0..63
    mul ah
    out dx, al
    inc cl
    jnz .bs_p332
.bs_draw:
    ; --- пиксели ---
    mov ax, 0xA000
    mov es, ax
    ; байт на пиксель исходника * шаг -> bmp_xstep
    mov ax, [bmp_bpp]
    shr ax, 3
    mul word [bmp_step]
    mov [bmp_xstep], ax
    mov ax, 200
    sub ax, [bmp_dh]
    shr ax, 1
    mov [bmp_yoff], ax
    mov ax, 320
    sub ax, [bmp_dw]
    shr ax, 1
    mov [bmp_xoff], ax
    xor bp, bp                      ; y
.bs_row:
    cmp bp, [cs:bmp_dh]
    jae .bs_done
    ; исходная строка
    mov ax, bp
    mul word [cs:bmp_step]          ; AX = y*step
    cmp byte [cs:bmp_topdown], 1
    je .bs_srcy
    mov bx, [cs:bmp_h]
    dec bx
    sub bx, ax
    mov ax, bx
.bs_srcy:
    movzx eax, ax
    mul dword [cs:bmp_stride]       ; EDX:EAX
    add eax, [cs:bmp_data]
    add eax, CP_SEG * 16
    mov ebx, eax
    shr ebx, 4
    mov ds, bx                      ; DS = сегмент строки
    and eax, 15
    mov si, ax
    ; адрес на экране
    mov ax, bp
    add ax, [cs:bmp_yoff]
    mov bx, 320
    mul bx
    add ax, [cs:bmp_xoff]
    mov di, ax
    mov cx, [cs:bmp_dw]
    mov bx, [cs:bmp_xstep]
    cmp word [cs:bmp_bpp], 8
    jne .bs_px_rgb
.bs_px8:
    mov al, [si]
    stosb
    add si, bx
    loop .bs_px8
    jmp .bs_next
.bs_px_rgb:
    mov al, [si + 2]                ; R
    and al, 0xE0
    mov ah, [si + 1]                ; G
    and ah, 0xE0
    shr ah, 3
    or al, ah
    mov ah, [si]                    ; B
    shr ah, 6
    or al, ah
    stosb
    add si, bx
    loop .bs_px_rgb
.bs_next:
    inc bp
    jmp .bs_row
.bs_done:
    pop es
    pop ds
    popad
    ret

;=================== play (WAV через Sound Blaster 16) ===================
; play FILE.WAV — PCM 8 бит, моно/стерео, 5–45 кГц. Файл стримится с диска
; блоками по 32 КБ в два буфера (0x90000 / 0x98000, одна DMA-страница;
; сегменты 5000h/7000h/8000h заняты окнами gui, поэтому буферы звука лежат вне их),
; воспроизведение через DSP SB16 (порт 0x220, DMA 1). Любая клавиша — стоп.
; Конвертация: ffmpeg -i song.ogg -ac 1 -ar 11025 -acodec pcm_u8 song.wav
SB_BASE  equ 0x220
WAV_BUF0 equ 0x9000
WAV_BUF1 equ 0x9800
WAV_BLK  equ 32768

play_command:
    pusha
    push es
    ; необязательный второй аргумент: sb / hda / spk — принудительное устройство
    mov byte [play_force], 0xFF
    mov si, input_buffer
    add si, 4
.pl_arg0:
    lodsb
    cmp al, ' '
    je .pl_arg0                     ; пробелы перед именем
    test al, al
    jz .pl_arg_done
.pl_arg:
    lodsb
    test al, al
    jz .pl_arg_done
    cmp al, ' '
    jne .pl_arg
    mov byte [si - 1], 0            ; отрезать имя файла
    mov di, play_opt_sb
    call str_match
    jnc .pl_a1
    mov byte [play_force], 0
    jmp .pl_arg_done
.pl_a1:
    mov di, play_opt_hda
    call str_match
    jnc .pl_arg_done
    mov byte [play_force], 2
.pl_arg_done:
    ; --- FILE.SNG (песня синтезатора): play X.SNG -> synth X.SNG -p ---
    mov si, input_buffer
    add si, 4
.pl_sng0:
    lodsb
    cmp al, ' '
    je .pl_sng0
    dec si
    mov bx, si                      ; BX -> имя файла
.pl_sng1:
    lodsb
    test al, al
    jnz .pl_sng1
    sub si, 5                       ; SI -> последние 4 символа
    cmp si, bx
    jb .pl_not_sng
    cmp byte [si], '.'
    jne .pl_not_sng
    mov al, [si + 1]
    and al, 0xDF
    cmp al, 'S'
    jne .pl_not_sng
    mov al, [si + 2]
    and al, 0xDF
    cmp al, 'N'
    jne .pl_not_sng
    mov al, [si + 3]
    and al, 0xDF
    cmp al, 'G'
    jne .pl_not_sng
    ; собрать "synth NAME -p" в sng_cmd и выполнить
    mov si, play_sng_pfx
    mov di, sng_cmd
.pl_sng2:
    lodsb
    stosb
    test al, al
    jnz .pl_sng2
    dec di
    mov si, bx
.pl_sng3:
    lodsb
    stosb
    test al, al
    jnz .pl_sng3
    dec di
    mov si, play_sng_sfx
.pl_sng4:
    lodsb
    stosb
    test al, al
    jnz .pl_sng4
    mov si, sng_cmd
    mov di, input_buffer
.pl_sng5:
    lodsb
    stosb
    test al, al
    jnz .pl_sng5
    call app_try_run
    jnc .pl_sng_ret
    mov si, play_sng_nosynth
    call print_string
.pl_sng_ret:
    pop es
    popa
    ret
.pl_not_sng:
    mov si, input_buffer
    add si, 4
    call path_save
    call resolve_path
    jc .pl_fail
    cmp byte [rp_isdir], 1
    je .pl_usage
    call load_dir
    jc .pl_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jnc .pl_nf
    test byte [es:si + 11], 0x10
    jnz .pl_isdir
    mov ax, [es:si + 26]
    mov [cat_cluster], ax
    mov ax, [es:si + 28]
    mov [wav_remain], ax
    mov ax, [es:si + 30]
    mov [wav_remain + 2], ax
    call read_fat
    jc .pl_ioerr
    ; --- заголовок: первый сектор ---
    mov ax, [cat_cluster]
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector
    jc .pl_ioerr
    call wav_parse
    jnc .pl_ok_hdr
    mov si, [wav_err]
    jmp .pl_fail
.pl_ok_hdr:
    ; --- устройство: SB16 -> Intel HDA (или принудительно) ---
    mov word [wav_blk], WAV_BLK
    mov word [wav_sec_left], 0
    mov al, [play_force]
    cmp al, 0xFF
    jne .pl_forced
    mov byte [play_dev], 0
    call sb_reset
    jnc .pl_dev_ok
    mov byte [play_dev], 2
    call hda_init
    jnc .pl_dev_ok
    jmp .pl_nodev
.pl_forced:
    mov [play_dev], al
    cmp al, 0
    jne .pl_f1
    call sb_reset
    jc .pl_nodev
    jmp .pl_dev_ok
.pl_f1:
    cmp al, 2
    jne .pl_dev_ok
    call hda_init
    jc .pl_nodev
.pl_dev_ok:
    mov si, play_msg
    call print_string
    mov si, cat_name
    mov cx, 11
.pl_pn:
    cmp cx, 3                       ; перед расширением — точка
    jne .pl_pn_ch
    mov al, '.'
    call print_char
.pl_pn_ch:
    lodsb
    cmp al, ' '
    je .pl_pn_skip
    call print_char
.pl_pn_skip:
    loop .pl_pn
    mov si, play_info1
    call print_string
    mov ax, [wav_rate]
    call print_dec_ax
    mov si, play_info2
    call print_string
    mov si, play_mono
    cmp word [wav_chan], 1
    je .pl_ch
    mov si, play_stereo
.pl_ch:
    call print_string
    ; длительность = size / (rate*chan)
    mov ax, [wav_rate]
    mul word [wav_chan]
    mov bx, ax
    mov dx, [wav_size + 2]
    mov ax, [wav_size]
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    pop ax
    div bx
    call print_dec_ax
    mov si, play_dev_sb
    cmp byte [play_dev], 0
    je .pl_pdev
    mov si, play_dev_hda
.pl_pdev:
    call print_string
    mov si, play_info3
    call print_string
    cmp byte [play_dev], 2
    je .pl_hda
    in al, 0x21                     ; замаскировать IRQ5 (SB16) — обработчика у нас нет
    mov [sb_pic_mask], al
    or al, 0x20
    out 0x21, al
    mov dx, SB_BASE + 0xE
    in al, dx                       ; сбросить возможное старое прерывание
    ; --- DSP: динамик, частота ---
    mov al, 0xD1
    call sb_write
    mov al, 0x41
    call sb_write
    mov al, [wav_rate + 1]
    call sb_write
    mov al, [wav_rate]
    call sb_write
.pl_stream:
    ; --- стриминг ---
    mov word [wav_skip], 0
    mov ax, [wav_data]
    mov [wav_skip], ax              ; пропустить заголовок внутри потока
    mov ax, [wav_size]
    mov [wav_remain], ax
    mov ax, [wav_size + 2]
    mov [wav_remain + 2], ax
    mov word [wav_cur], WAV_BUF0
    mov ax, WAV_BUF0
    call wav_fill                   ; CX = байт в буфере
    jcxz .pl_done
.pl_loop:
    mov ax, [wav_cur]
    call sb_play_block              ; старт DMA на AX:0, длина CX
    ; пока играет — читаем следующий блок в другой буфер
    mov ax, [wav_cur]
    xor ax, WAV_BUF0 ^ WAV_BUF1
    mov [wav_next], ax
    call wav_fill
    push cx
.pl_wait:
    mov ah, 0x11
    int 0x16
    jnz .pl_key
    call sb_dma_done
    jnc .pl_wait
    pop cx
    jcxz .pl_done
    mov ax, [wav_next]
    mov [wav_cur], ax
    jmp .pl_loop
.pl_key:
    pop cx
    mov ah, 0x10                    ; расширенное чтение: серые стрелки (E0) на реальном BIOS
    int 0x16
.pl_done:
    mov al, 0xD0                    ; стоп DMA
    call sb_write
    mov al, 0xD3                    ; динамик выкл
    call sb_write
    call sb_reset
    mov al, [sb_pic_mask]
    out 0x21, al
    mov si, newline
    jmp .pl_fail
.pl_nodev:
    mov si, play_nodev
    call print_string
    cmp byte [play_force], 0
    je .pl_nodev_nl
    mov si, play_hda_stage          ; на каком этапе отвалился HDA (для отладки на железе)
    call print_string
    mov al, [hda_stage]
    call print_char
    mov al, ')'
    call print_char
.pl_nodev_nl:
    mov si, newline
    jmp .pl_fail
;---------------- воспроизведение через Intel HDA ----------------
.pl_hda:
    call hda_print_info             ; строка диагностики: кодек, пин, ЦАП
    ; шаг ресэмплинга 16.16 = rate / 48000
    movzx eax, word [wav_rate]
    shl eax, 16
    xor edx, edx
    mov ebx, 48000
    div ebx
    mov [hda_step], eax
    mov dword [hda_pos], 0
    mov word [hda_inlen], 0
    mov byte [hda_in_eof], 0
    mov word [wav_blk], 2048        ; порция исходных данных для ресэмплера
    mov word [wav_sec_left], 0
    mov ax, [wav_data]
    mov [wav_skip], ax
    mov ax, [wav_size]
    mov [wav_remain], ax
    mov ax, [wav_size + 2]
    mov [wav_remain + 2], ax
    mov byte [hda_eof], 0
    mov ax, HDA_BUF0
    call hda_fill_half              ; CX = реальных кадров
    jcxz .pl_hda_end0
    mov ax, HDA_BUF1
    call hda_fill_half
    jcxz .pl_hda_eof1
    jmp .pl_hda_go
.pl_hda_eof1:
    mov byte [hda_eof], 1           ; половина 1 — тишина, реальные данные только в 0
.pl_hda_go:
    call hda_default_stream
    call hda_stream_setup
    jc .pl_hda_err
    call hda_stream_run
    mov byte [hda_cur], 0           ; какая половина сейчас играет
.pl_hda_loop:
    mov ah, 0x11
    int 0x16
    jnz .pl_hda_key
    call hda_playing_half           ; AL = 0/1
    cmp al, [hda_cur]
    je .pl_hda_loop
    ; половина hda_cur доиграла
    cmp byte [hda_eof], 0
    jne .pl_hda_stop                ; в ней была тишина после конца файла -> всё
    mov [hda_cur], al               ; теперь играет другая
    mov ax, HDA_BUF0
    cmp byte [hda_cur], 1
    je .pl_hda_rf
    mov ax, HDA_BUF1
.pl_hda_rf:
    call hda_fill_half
    jcxz .pl_hda_last
    jmp .pl_hda_loop
.pl_hda_last:
    mov byte [hda_eof], 1           ; тишина записана; ждём, пока доиграет реальная половина
    jmp .pl_hda_loop
.pl_hda_key:
    mov ah, 0x10                    ; расширенное чтение: серые стрелки (E0) на реальном BIOS
    int 0x16
.pl_hda_stop:
    call hda_stream_stop
.pl_hda_end0:
    mov si, newline
    jmp .pl_fail
.pl_hda_err:
    mov si, play_hda_err
    jmp .pl_fail
.pl_nf:
    mov si, cat_nfound
    jmp .pl_fail
.pl_isdir:
    mov si, err_isdir
    jmp .pl_fail
.pl_ioerr:
    mov si, cat_err
    jmp .pl_fail
.pl_usage:
    mov si, play_usage
.pl_fail:
    call print_string
    call path_restore
    pop es
    popa
    ret

;===================================================================
; Intel High Definition Audio — встроенный звук материнских плат (2005+).
; Контроллер ищется через PCI BIOS, его регистры (MMIO выше 1 МБ) читаются
; из реального режима через FS с 4-ГБ лимитом («unreal mode»). Команды кодеку
; идут через Immediate Command Interface, поэтому кольца CORB/RIRB не нужны.
; Выход: пин Line Out (зелёный разъём), иначе наушники, иначе динамики.
; Поток: 16 бит стерео (8-битный WAV расширяется на лету), два буфера по 16 КБ,
; слежение за позицией по LPIB. Нужен 386+.
;===================================================================
HDA_BUF0 equ 0x3400                 ; физически 0x34000, 16 КБ (свободная область под сегментом программ)
HDA_BUF1 equ 0x3800                 ; 0x38000
HDA_BDL  equ 0x3C00                 ; 0x3C000 — список буферов (BDL)
HDA_HALF equ 16384

; FS := база 0, лимит 4 ГБ (сохраняется, пока FS не перезагрузят)
unreal_fs:
    pushf
    cli
    push eax
    push bx
    xor eax, eax
    mov ax, cs
    shl eax, 4
    add eax, gdt_start
    mov [gdt_desc + 2], eax
    lgdt [gdt_desc]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp short .pm
.pm:
    mov bx, 0x08
    mov fs, bx
    and al, 0xFE
    mov cr0, eax
    jmp short .rm
.rm:
    xor bx, bx
    mov fs, bx
    pop bx
    pop eax
    popf
    ret

gdt_start:
    dq 0
    dw 0xFFFF, 0x0000
    db 0x00, 0x92, 0xCF, 0x00
gdt_desc:
    dw 23
    dd 0

enable_a20:
    mov ax, 0x2401
    int 0x15
    jnc .a20_ok
    in al, 0x92                     ; Fast A20
    test al, 2
    jnz .a20_ok
    or al, 2
    and al, 0xFE
    out 0x92, al
.a20_ok:
    ret

; --- доступ к регистрам: EDX = смещение ---
hda_rd32:
    push ebx
    mov ebx, [hda_base]
    add ebx, edx
    mov eax, [fs:ebx]
    pop ebx
    ret
hda_wr32:
    push ebx
    mov ebx, [hda_base]
    add ebx, edx
    mov [fs:ebx], eax
    pop ebx
    ret
hda_rd16:
    push ebx
    mov ebx, [hda_base]
    add ebx, edx
    mov ax, [fs:ebx]
    pop ebx
    ret
hda_wr16:
    push ebx
    mov ebx, [hda_base]
    add ebx, edx
    mov [fs:ebx], ax
    pop ebx
    ret
hda_rd8:
    push ebx
    mov ebx, [hda_base]
    add ebx, edx
    mov al, [fs:ebx]
    pop ebx
    ret
hda_wr8:
    push ebx
    mov ebx, [hda_base]
    add ebx, edx
    mov [fs:ebx], al
    pop ebx
    ret

; Ждать, пока (reg32[EDX] & ECX) == EBX. CF=1 по таймауту (~0.1 с)
hda_poll:
    push eax
    push si
    mov si, 0x8000
.hp_loop:
    call hda_rd32
    and eax, ecx
    cmp eax, ebx
    je .hp_ok
    in al, 0x80
    in al, 0x80
    dec si
    jnz .hp_loop
    stc
    jmp .hp_ret
.hp_ok:
    clc
.hp_ret:
    pop si
    pop eax
    ret

; Пауза CX тиков BIOS (55 мс)
wait_ticks:
    push ax
    push es
    push dx
    mov ax, 0x0040
    mov es, ax
    mov dx, [es:0x6C]
.wt_loop:
    mov ax, [es:0x6C]
    sub ax, dx
    cmp ax, cx
    jb .wt_loop
    pop dx
    pop es
    pop ax
    ret

; Найти контроллер и подготовить кодек. CF=1 если нет/ошибка. Результат кэшируется.
; hda_stage: 0 нет 386 / 1 PCI-поиск / 2 контроллер найден / 3 BAR0 / 4 сброс /
; 5 выход из сброса / 6 ожидание кодеков / 7 кодеки есть / 8 опрос кодеков /
; A аудиогруппа найдена / P выходной пин выбран / D ЦАП найден
hda_init:
    pushad
    cmp byte [cpu_level], 2
    jb .hi_fail
    cmp byte [hda_ready], 1
    je .hi_ok
    cmp byte [hda_ready], 2
    je .hi_fail                     ; уже пробовали — нет
    mov byte [hda_ready], 2
    ; PCI: класс 04.03 (HD Audio) — сканируем конфигурационное пространство
    mov byte [hda_stage], '1'
    call hda_pci_scan
    jc .hi_fail
    mov [hda_pci], bx
    mov byte [hda_stage], '2'
    xor di, di                      ; vendor:device контроллера
    call pci_rd32
    mov [hda_ctrl_id], ecx
    mov di, 0x04                    ; command: память + bus master
    call pci_rd32
    or ecx, 0x06
    call pci_wr32
    mov di, 0x10                    ; BAR0 (64-битный — берём младшую часть)
    call pci_rd32
    and ecx, 0xFFFFFFF0
    jz .hi_fail
    mov [hda_base], ecx
    mov byte [hda_stage], '3'
    call enable_a20
    call unreal_fs
    ; сброс контроллера
    mov byte [hda_stage], '4'
    mov edx, 0x08                   ; GCTL
    xor eax, eax
    call hda_wr32
    mov ecx, 1
    xor ebx, ebx
    call hda_poll
    jc .hi_fail
    mov cx, 1
    call wait_ticks
    mov edx, 0x08
    mov byte [hda_stage], '5'
    mov eax, 1
    call hda_wr32
    mov ecx, 1
    mov ebx, 1
    call hda_poll
    jc .hi_fail
    mov cx, 2                       ; кодекам нужно >0.5 мс, чтобы заявить о себе
    mov byte [hda_stage], '6'
    call wait_ticks
    mov edx, 0x0E                   ; STATESTS
    call hda_rd16
    and ax, 0x7FFF
    jz .hi_fail
    mov [hda_codecs], ax
    mov byte [hda_stage], '7'
    mov edx, 0x68                   ; ICIS: сбросить флаг ответа
    mov ax, 2
    call hda_wr16
    mov edx, 0x20                   ; прерывания контроллера не нужны
    xor eax, eax
    call hda_wr32
    ; перебрать кодеки
    mov byte [hda_stage], '8'
    xor cx, cx
.hi_cad:
    bt word [hda_codecs], cx
    jnc .hi_next
    mov [hda_cad], cl
    call hda_codec_setup
    jnc .hi_found
.hi_next:
    inc cx
    cmp cx, 15
    jb .hi_cad
    jmp .hi_fail
.hi_found:
    mov byte [hda_ready], 1
.hi_ok:
    call unreal_fs
    popad
    clc
    ret
.hi_fail:
    popad
    stc
    ret

; Команда кодеку: EAX = verb (32 бита) -> EAX = ответ. CF по таймауту.
hda_cmd:
    push ebx
    push ecx
    push edx
    mov edx, 0x68
    xor ebx, ebx
    mov ecx, 1
    call hda_poll                   ; дождаться, пока ICB свободен
    jc .hc_ret
    mov edx, 0x60                   ; ICOI
    call hda_wr32
    mov edx, 0x68
    mov ax, 1                       ; ICB
    call hda_wr16
    mov ecx, 2
    mov ebx, 2
    call hda_poll                   ; IRV — ответ готов
    jc .hc_ret
    mov edx, 0x64                   ; ICII
    call hda_rd32
    mov ebx, eax
    mov edx, 0x68
    mov ax, 2                       ; сбросить IRV
    call hda_wr16
    mov eax, ebx
    clc
.hc_ret:
    pop edx
    pop ecx
    pop ebx
    ret

; Команда узлу: BL = NID, EAX = verb+payload (20 бит) -> EAX ответ
hda_node:
    push ebx
    and eax, 0x000FFFFF
    movzx ebx, bl
    shl ebx, 20
    or eax, ebx
    movzx ebx, byte [hda_cad]
    shl ebx, 28
    or eax, ebx
    pop ebx
    jmp hda_cmd

; BL = NID: параметр EAX (0..) -> EAX
hda_param:
    or eax, 0xF0000
    jmp hda_node

; Смещение (0 дБ) выходного усилителя узла BL -> AL (если у узла нет — у AFG)
hda_amp_offset:
    push ebx
    mov eax, 0x12
    call hda_param
    test eax, eax
    jnz .ao_got
    mov bl, [hda_afg]
    mov eax, 0x12
    call hda_param
.ao_got:
    and al, 0x7F
    pop ebx
    ret

hda_amp_offset_in:
    push ebx
    mov eax, 0x0D
    call hda_param
    test eax, eax
    jnz .ai_got
    mov bl, [hda_afg]
    mov eax, 0x0D
    call hda_param
.ai_got:
    and al, 0x7F
    pop ebx
    ret

; Найти аудиогруппу, выходной пин и ЦАП, разблокировать путь. CF при неудаче.
hda_codec_setup:
    pushad
    mov byte [hda_afg], 0
    mov byte [hda_pin], 0
    mov byte [hda_dac], 0
    xor bl, bl
    mov eax, 0x04                   ; корень: подузлы
    call hda_param
    jc .cs_fail
    mov cl, al                      ; количество
    shr eax, 16
    mov bl, al                      ; первый
    test cl, cl
    jz .cs_fail
.cs_fg:
    mov eax, 0x05                   ; тип группы
    call hda_param
    and al, 0x7F
    cmp al, 1                       ; Audio Function Group
    je .cs_afg
    inc bl
    dec cl
    jnz .cs_fg
    jmp .cs_fail
.cs_afg:
    mov [hda_afg], bl
    mov byte [hda_stage], 'A'
    push bx
    xor bl, bl
    mov eax, 0x00                   ; vendor/device кодека
    call hda_param
    mov [hda_codec_id], eax
    pop bx
    mov eax, 0x70500                ; AFG -> D0
    call hda_node
    mov cx, 2
    call wait_ticks
    ; виджеты
    mov bl, [hda_afg]
    mov eax, 0x04
    call hda_param
    mov cl, al
    shr eax, 16
    mov bl, al
    mov byte [hda_best], 0xFF
    test cl, cl
    jz .cs_fail
.cs_w:
    mov eax, 0x09                   ; возможности виджета
    call hda_param
    shr eax, 20
    and al, 0x0F
    cmp al, 4                       ; Pin Complex?
    jne .cs_wn
    mov eax, 0x0C                   ; pin caps
    call hda_param
    test al, 0x10                   ; выход возможен?
    jz .cs_wn
    mov eax, 0xF1C00                ; configuration default
    call hda_node
    mov edx, eax
    shr edx, 30
    cmp dl, 1                       ; 01 = ни к чему не подключён
    je .cs_wn
    shr eax, 20
    and al, 0x0F                    ; default device
    mov ah, 0                       ; оценка: Line Out лучше всего
    cmp al, 0
    je .cs_score
    mov ah, 1
    cmp al, 2                       ; HP Out
    je .cs_score
    mov ah, 2
    cmp al, 1                       ; Speaker
    jne .cs_wn
.cs_score:
    cmp ah, [hda_best]
    jae .cs_wn
    mov [hda_best], ah
    mov [hda_pin], bl
    mov [hda_pindev], al
.cs_wn:
    inc bl
    dec cl
    jnz .cs_w
    cmp byte [hda_pin], 0
    je .cs_fail
    mov byte [hda_stage], 'P'
    ; путь от пина к ЦАП (до 4 шагов)
    mov bl, [hda_pin]
    mov ch, 4
.cs_path:
    mov eax, 0x09
    call hda_param
    mov edx, eax
    shr edx, 20
    and dl, 0x0F                    ; тип
    jz .cs_isdac
    ; разблокировать усилители узла и выбрать вход 0
    test al, 0x04                   ; выходной усилитель есть
    jz .cs_noout
    push eax
    call hda_amp_offset
    mov ah, 0xB0                    ; out, L+R, без mute
    mov edx, eax
    and edx, 0xFFFF
    mov eax, 0x30000
    or eax, edx
    call hda_node
    pop eax
.cs_noout:
    test al, 0x02                   ; входной усилитель есть
    jz .cs_noin
    push eax
    call hda_amp_offset_in
    mov ah, 0x70                    ; in, L+R, индекс 0, без mute
    mov edx, eax
    and edx, 0xFFFF
    mov eax, 0x30000
    or eax, edx
    call hda_node
    pop eax
.cs_noin:
    mov eax, 0x70500                ; D0
    call hda_node
    mov eax, 0x70100                ; выбрать соединение 0
    call hda_node
    mov eax, 0x0E                   ; длина списка соединений
    call hda_param
    test al, 0x7F
    jz .cs_fail
    mov eax, 0xF0200                ; список соединений, запись 0
    call hda_node
    and al, 0x7F
    mov bl, al
    dec ch
    jnz .cs_path
    jmp .cs_fail
.cs_isdac:
    mov [hda_dac], bl
    mov byte [hda_stage], 'D'
    mov eax, 0x70500                ; D0
    call hda_node
    call hda_amp_offset
    mov ah, 0xB0
    mov edx, eax
    and edx, 0xFFFF
    mov eax, 0x30000
    or eax, edx
    call hda_node
    ; пин: включить выход (и HP-усилитель для наушников), EAPD
    mov bl, [hda_pin]
    mov eax, 0x70740
    cmp byte [hda_pindev], 2
    jne .cs_pc
    mov eax, 0x707C0
.cs_pc:
    call hda_node
    mov eax, 0x70C02
    call hda_node
    popad
    clc
    ret
.cs_fail:
    popad
    stc
    ret

; Заполнить половину AX:0 (16 КБ = 4096 кадров 16 бит стерео 48 кГц) из потока
; 8-битного WAV с ресэмплингом (ближайший сэмпл, шаг [hda_step] 16.16).
; Исходные данные берутся порциями через wav_fill в WAV_BUF0. CX = реальных кадров.
hda_fill_half:
    push eax
    push ebx
    push dx
    push si
    push di
    push es
    mov es, ax
    xor di, di
    xor dx, dx                      ; счётчик реальных кадров
.fh_frame:
    cmp di, HDA_HALF
    jae .fh_done
.fh_idx:
    mov eax, [hda_pos]
    shr eax, 16                     ; индекс кадра в текущей порции
    cmp ax, [hda_inlen]
    jb .fh_sample
    cmp byte [hda_in_eof], 1
    je .fh_pad
    movzx ebx, word [hda_inlen]     ; порция израсходована — следующая
    shl ebx, 16
    sub [hda_pos], ebx
    push cx
    mov ax, WAV_BUF0
    call wav_fill                   ; CX байт
    mov ax, cx
    pop cx
    cmp word [wav_chan], 1
    je .fh_il
    shr ax, 1
.fh_il:
    mov [hda_inlen], ax
    test ax, ax
    jnz .fh_idx
    mov byte [hda_in_eof], 1
    jmp .fh_idx
.fh_sample:
    mov si, ax
    cmp word [wav_chan], 1
    je .fh_mono
    shl si, 1
.fh_mono:
    push ds
    mov bx, WAV_BUF0
    mov ds, bx
    lodsb
    sub al, 0x80
    mov ah, al
    xor al, al
    stosw                           ; левый
    cmp word [cs:wav_chan], 1
    je .fh_r
    lodsb
    sub al, 0x80
    mov ah, al
    xor al, al
.fh_r:
    stosw                           ; правый
    pop ds
    mov eax, [hda_step]
    add [hda_pos], eax
    inc dx
    jmp .fh_frame
.fh_pad:
    xor ax, ax
    mov cx, HDA_HALF
    sub cx, di
    shr cx, 1
    rep stosw
.fh_done:
    mov cx, dx
    pop es
    pop di
    pop si
    pop dx
    pop ebx
    pop eax
    ret

; Поиск HD Audio напрямую через порты PCI (CF8/CFC). -> BX = bus/dev/fn, CF=1 если нет
hda_pci_scan:
    push eax
    push ecx
    push dx
    xor bx, bx
.ps_next:
    mov eax, 0x80000000
    movzx ecx, bx
    shl ecx, 8
    or eax, ecx
    or al, 0x08                     ; регистр 08h: класс
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    shr eax, 16
    cmp ax, 0x0403
    je .ps_found
    inc bx
    jnz .ps_next
    stc
    jmp .ps_ret
.ps_found:
    clc
.ps_ret:
    pop dx
    pop ecx
    pop eax
    ret

; Чтение/запись dword конфигурации PCI: BX = адрес, DI = регистр, ECX = значение
pci_rd32:
    push eax
    push dx
    mov eax, 0x80000000
    movzx ecx, bx
    shl ecx, 8
    or eax, ecx
    movzx ecx, di
    and cl, 0xFC
    or eax, ecx
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    mov ecx, eax
    pop dx
    pop eax
    ret
pci_wr32:
    push eax
    push dx
    push ecx
    mov eax, 0x80000000
    movzx ecx, bx
    shl ecx, 8
    or eax, ecx
    movzx ecx, di
    and cl, 0xFC
    or eax, ecx
    mov dx, 0xCF8
    out dx, eax
    pop ecx
    mov dx, 0xCFC
    mov eax, ecx
    out dx, eax
    pop dx
    pop eax
    ret

; Строка диагностики: "HDA: ctrl VVVV:DDDD codec VVVVDDDD pin XX dac YY"
hda_print_info:
    pushad
    mov si, hda_info1
    call print_string
    mov ax, [hda_ctrl_id]
    call print_hex_word
    mov al, ':'
    call print_char
    mov ax, [hda_ctrl_id + 2]
    call print_hex_word
    mov si, hda_info2
    call print_string
    mov ax, [hda_codec_id + 2]
    call print_hex_word
    mov ax, [hda_codec_id]
    call print_hex_word
    mov si, hda_info3
    call print_string
    mov al, [hda_pin]
    call print_hex_byte
    mov si, hda_info4
    call print_string
    mov al, [hda_dac]
    call print_hex_byte
    mov si, newline
    call print_string
    popad
    ret

; Настроить выходной поток 0: BDL из двух половин, 48 кГц 16 бит стерео
hda_stream_setup:
    pushad
    push es
    call unreal_fs
    mov edx, 0x00                   ; GCAP: число входных потоков -> смещение первого выходного
    call hda_rd16
    shr ax, 8
    and ax, 0x0F
    shl ax, 5
    add ax, 0x80
    mov [hda_sd], ax
    ; сброс потока
    movzx edx, word [hda_sd]
    xor al, al
    call hda_wr8
    mov al, 1
    call hda_wr8
    mov ecx, 1
    mov ebx, 1
    call hda_poll
    jc .ss_fail
    xor al, al
    call hda_wr8
    mov ecx, 1
    xor ebx, ebx
    call hda_poll
    jc .ss_fail
    ; BDL: две половины подряд по [hda_bufaddr] длиной [hda_halfsz]
    mov ax, HDA_BDL
    mov es, ax
    xor di, di
    mov eax, [hda_bufaddr]
    stosd
    xor eax, eax
    stosd
    mov eax, [hda_halfsz]
    stosd
    xor eax, eax
    stosd
    mov eax, [hda_bufaddr]
    add eax, [hda_halfsz]
    stosd
    xor eax, eax
    stosd
    mov eax, [hda_halfsz]
    stosd
    xor eax, eax
    stosd
    movzx edx, word [hda_sd]
    add edx, 0x18                   ; BDPL / BDPU
    mov eax, HDA_BDL << 4
    call hda_wr32
    add edx, 4
    xor eax, eax
    call hda_wr32
    movzx edx, word [hda_sd]
    add edx, 0x08                   ; CBL
    mov eax, [hda_halfsz]
    shl eax, 1
    call hda_wr32
    movzx edx, word [hda_sd]
    add edx, 0x0C                   ; LVI
    mov ax, 1
    call hda_wr16
    movzx edx, word [hda_sd]
    add edx, 0x12                   ; формат
    mov ax, [hda_fmt]               ; по умолчанию 0011h: 48 кГц, 16 бит, 2 канала
    call hda_wr16
    movzx edx, word [hda_sd]
    add edx, 0x02                   ; номер потока 1
    mov al, 0x10
    call hda_wr8
    ; ЦАП: формат и поток 1 / канал 0
    mov bl, [hda_dac]
    movzx eax, word [hda_fmt]
    or eax, 0x20000                 ; формат ЦАП = формат потока
    call hda_node
    mov eax, 0x70610
    call hda_node
    pop es
    popad
    clc
    ret
.ss_fail:
    pop es
    popad
    stc
    ret

hda_stream_run:
    pushad
    movzx edx, word [hda_sd]
    call hda_rd8
    or al, 0x02                     ; RUN
    call hda_wr8
    popad
    ret

hda_stream_stop:
    pushad
    call unreal_fs
    movzx edx, word [hda_sd]
    call hda_rd8
    and al, 0xFD
    call hda_wr8
    mov bl, [hda_dac]
    mov eax, 0x70600                ; ЦАП отвязать от потока
    call hda_node
    popad
    ret

; AL = 0/1 — какая половина буфера играет сейчас (по LPIB)
hda_playing_half:
    push edx
    push eax
    call unreal_fs                  ; BIOS мог перезагрузить FS
    movzx edx, word [hda_sd]
    add edx, 0x04
    call hda_rd32
    mov edx, eax
    pop eax
    xor al, al
    cmp edx, [hda_halfsz]
    jb .ph_ret
    mov al, 1
    sub edx, [hda_halfsz]
.ph_ret:
    mov [hda_lpib_in], dx           ; позиция внутри половины
    pop edx
    ret

; параметры потока по умолчанию (для play): буферы ядра, 32 КБ, 48 кГц стерео 16 бит
hda_default_stream:
    mov dword [hda_bufaddr], HDA_BUF0 << 4
    mov dword [hda_halfsz], HDA_HALF
    mov word [hda_fmt], 0x0011
    ret

; Разбор RIFF/WAVE в 0x2000:0 -> wav_rate, wav_chan, wav_data (смещение), wav_size
wav_parse:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    mov ax, 0x2000
    mov es, ax
    cmp word [es:0], 'RI'
    jne .wp_bad
    cmp word [es:2], 'FF'
    jne .wp_bad
    cmp word [es:8], 'WA'
    jne .wp_bad
    cmp word [es:10], 'VE'
    jne .wp_bad
    mov byte [wav_have_fmt], 0
    mov si, 12
.wp_chunk:
    cmp si, 500
    jae .wp_bad
    mov ax, [es:si]
    mov bx, [es:si + 2]
    mov cx, [es:si + 4]             ; размер (младшее слово)
    mov dx, [es:si + 6]
    cmp ax, 'fm'
    jne .wp_not_fmt
    cmp bx, 't '
    jne .wp_not_fmt
    cmp word [es:si + 8], 1         ; PCM
    jne .wp_unsup
    mov ax, [es:si + 10]
    cmp ax, 1
    jb .wp_unsup
    cmp ax, 2
    ja .wp_unsup
    mov [wav_chan], ax
    cmp word [es:si + 14], 0        ; rate < 65536
    jne .wp_unsup
    mov ax, [es:si + 12]
    cmp ax, 5000
    jb .wp_unsup
    cmp ax, 45000
    ja .wp_unsup
    mov [wav_rate], ax
    cmp word [es:si + 22], 8        ; только 8 бит
    jne .wp_unsup
    mov byte [wav_have_fmt], 1
    jmp .wp_next
.wp_not_fmt:
    cmp ax, 'da'
    jne .wp_next
    cmp bx, 'ta'
    jne .wp_next
    cmp byte [wav_have_fmt], 1
    jne .wp_bad
    mov ax, si
    add ax, 8
    mov [wav_data], ax
    mov [wav_size], cx
    mov [wav_size + 2], dx
    ; размер data не больше остатка файла
    mov ax, [wav_remain]
    sub ax, [wav_data]
    mov bx, [wav_remain + 2]
    sbb bx, 0
    cmp bx, dx
    ja .wp_ok
    jb .wp_clamp
    cmp ax, cx
    jae .wp_ok
.wp_clamp:
    mov [wav_size], ax
    mov [wav_size + 2], bx
.wp_ok:
    clc
    jmp .wp_ret
.wp_next:
    add si, 8
    add si, cx
    test cx, 1
    jz .wp_chunk
    inc si                          ; чанки выровнены на 2
    jmp .wp_chunk
.wp_bad:
    mov word [wav_err], play_bad
    jmp .wp_fail
.wp_unsup:
    mov word [wav_err], play_unsup
.wp_fail:
    stc
.wp_ret:
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Заполнить буфер AX:0 ровно [wav_blk] байтами потока (меньше — только в конце
; файла). CX = сколько скопировано. Текущий сектор держится в 0x2000:0,
; wav_sec_pos/wav_sec_left — сколько из него ещё не отдано.
; Перед первым вызовом: wav_sec_left=0, wav_skip=смещение данных, wav_remain=размер.
wav_fill:
    push ax
    push bx
    push dx
    push si
    push di
    push es
    mov es, ax
    xor di, di
.wf_loop:
    mov cx, [wav_blk]
    sub cx, di
    jbe .wf_done                    ; буфер полон
    cmp word [wav_sec_left], 0
    jne .wf_copy
    ; --- следующий сектор ---
    mov ax, [wav_remain]
    or ax, [wav_remain + 2]
    jz .wf_done
    mov ax, [cat_cluster]
    cmp ax, [fat_eoc]
    jae .wf_done
    add ax, [data_lba]              ; кластер -> LBA (1 сектор на кластер)
    call read_data_sector           ; -> 0x2000:0
    jc .wf_done
    mov ax, [cat_cluster]
    call fat_next
    mov [cat_cluster], ax
    mov ax, [wav_skip]              ; пропуск заголовка (только в первом секторе)
    mov word [wav_skip], 0
    mov [wav_sec_pos], ax
    mov bx, 512
    sub bx, ax
    cmp word [wav_remain + 2], 0    ; не больше, чем осталось данных
    jne .wf_sl
    cmp bx, [wav_remain]
    jbe .wf_sl
    mov bx, [wav_remain]
.wf_sl:
    mov [wav_sec_left], bx
    sub [wav_remain], bx
    sbb word [wav_remain + 2], 0
    jmp .wf_loop
.wf_copy:
    cmp cx, [wav_sec_left]
    jbe .wf_n
    mov cx, [wav_sec_left]
.wf_n:
    mov si, [wav_sec_pos]
    add [wav_sec_pos], cx
    sub [wav_sec_left], cx
    push ds
    mov ax, 0x2000
    mov ds, ax
    rep movsb
    pop ds
    jmp .wf_loop
.wf_done:
    mov cx, di
    pop es
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

; ---- Sound Blaster 16 ----
; сброс DSP; CF=1 если карты нет
sb_reset:
    push ax
    push cx
    push dx
    mov dx, SB_BASE + 0x6
    mov al, 1
    out dx, al
    mov cx, 100
.sr_d1:
    in al, 0x80                     ; ~1 мкс
    loop .sr_d1
    xor al, al
    out dx, al
    mov cx, 2000
.sr_wait:
    mov dx, SB_BASE + 0xE
    in al, dx
    test al, 0x80
    jz .sr_next
    mov dx, SB_BASE + 0xA
    in al, dx
    cmp al, 0xAA
    je .sr_ok
.sr_next:
    in al, 0x80
    loop .sr_wait
    stc
    jmp .sr_ret
.sr_ok:
    clc
.sr_ret:
    pop dx
    pop cx
    pop ax
    ret

; записать AL в DSP
sb_write:
    push ax
    push cx
    push dx
    mov ah, al
    mov dx, SB_BASE + 0xC
    mov cx, 0xFFFF
.sw_wait:
    in al, dx
    test al, 0x80
    jz .sw_go
    loop .sw_wait
.sw_go:
    mov al, ah
    out dx, al
    pop dx
    pop cx
    pop ax
    ret

; Запустить одиночный DMA-перенос буфера AX:0 длиной CX через канал 1
sb_play_block:
    push ax
    push bx
    push cx
    push dx
    mov bx, ax                      ; сегмент
    dec cx                          ; DMA/DSP хотят длину-1
    ; физический адрес = seg*16 (смещение 0): страница = seg>>12, адрес = seg<<4
    mov al, 0x05                    ; маска канала 1
    out 0x0A, al
    xor al, al
    out 0x0C, al                    ; сброс триггера
    mov al, 0x49                    ; одиночный, чтение из памяти, канал 1
    out 0x0B, al
    mov ax, bx
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    out 0x02, al                    ; адрес lo
    mov al, ah
    out 0x02, al                    ; адрес hi
    mov ax, bx
    mov al, ah
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    out 0x83, al                    ; страница
    mov al, cl
    out 0x03, al                    ; счётчик lo
    mov al, ch
    out 0x03, al                    ; счётчик hi
    mov al, 0x01                    ; снять маску
    out 0x0A, al
    ; DSP: 8-бит вывод, одиночный
    mov al, 0xC0
    call sb_write
    mov al, 0x00                    ; unsigned mono
    cmp word [wav_chan], 1
    je .sp_mode
    mov al, 0x20                    ; unsigned stereo
    shr cx, 1                       ; длина для DSP — в сэмплах на канал
.sp_mode:
    call sb_write
    mov al, cl
    call sb_write
    mov al, ch
    call sb_write
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; CF=1 когда блок доигран: бит 0 регистра микшера 0x82 (8-битное прерывание
; ожидает). Подтверждаем чтением порта 0x22E.
sb_dma_done:
    push ax
    push dx
    mov dx, SB_BASE + 0x4
    mov al, 0x82
    out dx, al
    inc dx
    in al, dx
    test al, 0x01
    jz .dd_no
    mov dx, SB_BASE + 0xE
    in al, dx                       ; ack
    stc
    jmp .dd_ret
.dd_no:
    clc
.dd_ret:
    pop dx
    pop ax
    ret

;=================== cd / pwd / пути ===================
; Сохранить/восстановить текущий каталог (cur_dir + cur_path)
path_save:
    pusha
    mov ax, [cur_dir]
    mov [sav_dir], ax
    mov si, cur_path
    mov di, sav_path
    mov cx, 64
.ps_cp:
    lodsb
    mov [di], al
    inc di
    loop .ps_cp
    popa
    ret

path_restore:
    pusha
    mov ax, [sav_dir]
    mov [cur_dir], ax
    mov si, sav_path
    mov di, cur_path
    mov cx, 64
.pr_cp:
    lodsb
    mov [di], al
    inc di
    loop .pr_cp
    popa
    ret

; Войти в подкаталог cat_name (или ".."). CF=1 ошибка, SI -> сообщение
cd_enter:
    push ax
    push es
    push si                         ; SI вызывающего сохраняем (указатель на путь)
    call load_dir
    jc .ce_ioerr
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jnc .ce_nf
    test byte [es:si + 11], 0x10
    jz .ce_notdir
    mov ax, [es:si + 26]
    mov [cur_dir], ax
    cmp byte [cat_name], '.'
    jne .ce_push
    call path_pop
    jmp .ce_ok
.ce_push:
    call path_push
.ce_ok:
    pop si
    clc
    jmp .ce_ret
.ce_nf:
    mov si, cd_nfound
    jmp .ce_fail
.ce_notdir:
    mov si, cd_notdir
    jmp .ce_fail
.ce_ioerr:
    mov si, cat_err
.ce_fail:
    add sp, 2                       ; выбросить сохранённый SI
    stc
.ce_ret:
    pop es
    pop ax
    ret

; resolve_path: DS:SI -> путь ("a.txt", "docs/a.txt", "/docs", "../x", "~").
; Проходит по каталогам (меняя cur_dir/cur_path), имя последнего компонента
; кладёт в cat_name, SI остаётся за ним. [rp_isdir]=1, если цель — сам
; каталог, в который мы вошли (путь пуст, кончается на '/', "." или "..").
; CF=1 ошибка, SI -> сообщение. Вызывающий сам делает path_save/path_restore.
resolve_path:
    push ax
    push bx
    mov byte [rp_isdir], 0
.rp_skip:
    cmp byte [si], ' '
    jne .rp_start
    inc si
    jmp .rp_skip
.rp_start:
    mov al, [si]
    test al, al
    jnz .rp_nonempty
    mov si, err_noarg
    jmp .rp_fail
.rp_nonempty:
    cmp al, '~'
    jne .rp_chk_root
    inc si
    jmp .rp_root
.rp_chk_root:
    cmp al, '/'
    je .rp_root
    cmp al, 0x5C
    jne .rp_comp
.rp_root:
    mov word [cur_dir], 0
    mov byte [cur_path + 1], 0
.rp_slashes:
    mov al, [si]
    cmp al, '/'
    je .rp_sl
    cmp al, 0x5C
    jne .rp_comp
.rp_sl:
    inc si
    jmp .rp_slashes
.rp_comp:
    mov al, [si]
    test al, al
    jz .rp_end_dir
    cmp al, ' '
    je .rp_end_dir
    cmp al, '.'
    jne .rp_named
    mov bx, 1
    cmp byte [si + 1], '.'
    jne .rp_dots
    inc bx
.rp_dots:
    mov al, [si + bx]
    call is_sep
    jne .rp_named                   ; ".name" / "..x" — обычное имя
    add si, bx
    cmp bx, 1
    je .rp_slashes                  ; "." — остаёмся
    cmp word [cur_dir], 0
    je .rp_slashes                  ; ".." из корня — остаёмся
    push di
    push cx
    mov di, cat_name
    mov cx, 11
    mov al, ' '
.rp_pad:
    mov [di], al
    inc di
    loop .rp_pad
    pop cx
    pop di
    mov word [cat_name], '..'
    call cd_enter
    jc .rp_fail
    jmp .rp_slashes
.rp_named:
    call parse_filename
    jc .rp_fail
    mov al, [si]
    cmp al, '/'
    je .rp_into
    cmp al, 0x5C
    je .rp_into
    clc                             ; последний компонент — имя в cat_name
    jmp .rp_ret
.rp_into:
    call cd_enter
    jc .rp_fail
    jmp .rp_slashes
.rp_end_dir:
    mov byte [rp_isdir], 1
    clc
    jmp .rp_ret
.rp_fail:
    stc
.rp_ret:
    pop bx
    pop ax
    ret

cd_command:
    pusha
    mov si, input_buffer
    add si, 2
    call path_save
    call skip_spaces
    cmp byte [si], 0
    jne .cd_res
    mov word [cur_dir], 0
    mov byte [cur_path + 1], 0
    jmp .cd_done
.cd_res:
    call resolve_path
    jc .cd_fail
    cmp byte [rp_isdir], 1
    je .cd_done
    call cd_enter
    jc .cd_fail
    jmp .cd_done
.cd_fail:
    call print_string
    call path_restore
.cd_done:
    popa
    ret

; добавить "/" + cat_name (8.3 без пробелов) к cur_path
path_push:
    pusha
    mov di, cur_path
.pp_end:
    cmp byte [di], 0
    je .pp_at_end
    inc di
    jmp .pp_end
.pp_at_end:
    mov ax, di
    sub ax, cur_path
    cmp ax, 48
    ja .pp_ret                      ; слишком глубоко — путь не наращиваем
    mov byte [di], '/'
    inc di
    mov si, cat_name
    mov cx, 8
.pp_name:
    lodsb
    cmp al, ' '
    je .pp_name_done
    mov [di], al
    inc di
.pp_name_done:
    loop .pp_name
    mov si, cat_name + 8
    cmp byte [si], ' '
    je .pp_term
    mov byte [di], '.'
    inc di
    mov cx, 3
.pp_ext:
    lodsb
    cmp al, ' '
    je .pp_ext_done
    mov [di], al
    inc di
.pp_ext_done:
    loop .pp_ext
.pp_term:
    mov byte [di], 0
.pp_ret:
    popa
    ret

; убрать последний компонент cur_path
path_pop:
    pusha
    mov di, cur_path + 1
    mov bx, cur_path + 1
.po_scan:
    mov al, [di]
    test al, al
    jz .po_cut
    cmp al, '/'
    jne .po_next
    mov bx, di
.po_next:
    inc di
    jmp .po_scan
.po_cut:
    mov byte [bx], 0
    popa
    ret

; печать пути вида /DOCS/SUB (корень — "/")
print_path:
    push si
    mov si, cur_path + 1
    cmp byte [si], 0
    jne .pr_go
    mov si, path_root
.pr_go:
    call print_string
    pop si
    ret

pwd_command:
    call print_path
    push si
    mov si, newline
    call print_string
    pop si
    ret


;=================== Внешние программы (.FAP, Ferrix App Image) ===================
; Формат файла: заголовок 16 байт + код.
;   0  db "FAPI"      4 db версия формата (1)   5 db флаги (0)
;   6  dw entry       (смещение точки входа; образ грузится по APP_SEG:0100h)
;   8  времена: 8 байт резерв
; Память программы (tiny-модель, как .COM): CS=DS=ES=SS=APP_SEG,
;   0000h-007Fh служебная область (0000h dw версия API), 0080h-00FFh аргументы
;   (ASCIIZ), 0100h образ файла, стек растёт от FFFEh. Возврат: int 80h/AH=0 или retf.
;
; int 80h (AH = функция; CF=1 при ошибке там, где указано):
;   00 exit                       01 putc AL
;   02 puts DS:SI (ASCIIZ)        03 getkey -> AX (ждёт; AL=0/E0 — расширенная, AH=скан)
;   04 keyhit -> AX (0 = нет, ZF)  05 setcursor DH=строка DL=столбец
;   06 getcursor -> DH,DL          07 cls
;   08 readfile DS:SI путь, ES:DI буфер, CX макс -> AX длина, CF
;   09 writefile DS:SI путь, ES:DI данные, CX длина -> CF
;   0A ticks -> DX:AX (18.2 Гц)    0B printdec DX
;   0C getcwd ES:DI (ASCIIZ, "/" для корня)   0D sleep CX тиков
;   0E uiredraw (очистить экран и нарисовать баннер оболочки)
;   0F rand -> AX (0..65535)       10 cursor CX=2000h спрятать / 0607h показать
;   11 localtime -> CH час CL мин DH сек DL день  12 username ES:DI <- ASCIIZ
;   13 beep (короткий сигнал)      14 kbflush (очистить буфер клавиатуры)
;   15 putat DH строка DL столбец AL символ BL атрибут
;   16 fillrect DH,DL верх-лево CH,CL высота,ширина AL символ BL атрибут
;   17 putsat DH,DL DS:SI ASCIIZ BL атрибут
;   readfile при ошибке: AX = 1 нет файла/пути, 2 слишком большой, 3 ошибка диска
API_MAX  equ 0x24

api_install:
    push es
    xor ax, ax
    mov es, ax
    cli
    mov word [es:API_INT * 4], api_int
    mov word [es:API_INT * 4 + 2], KSEG
    sti
    pop es
    ret

api_int:
    cld
    cmp word [cs:wm_seg], 0
    je .ai_normal
    ; оконный менеджер установлен: вызовы из других сегментов отдаём ему
    push bp
    mov bp, sp
    push ax
    mov ax, [bp + 4]                ; CS вызывающего
    cmp ax, [cs:wm_seg]
    pop ax
    pop bp
    je .ai_normal
    call far [cs:wm_handler]        ; регистры программы как есть; результат — в регистрах и CF/ZF
    push bp
    mov bp, sp
    push ax
    pushf
    pop ax
    and ax, 0x0041                  ; CF и ZF
    and word [bp + 6], 0xFFBE
    or [bp + 6], ax
    pop ax
    pop bp
    iret
.ai_normal:
    cmp ah, 0
    je app_exit_far
    push bp
    mov bp, sp                      ; [bp+6] = FLAGS возврата
    push ds
    push es
    mov [cs:api_uds], ds
    mov [cs:api_ues], es
    push bx                         ; BX программы сохраняется
    mov bx, KSEG
    mov ds, bx
    mov es, bx
    and byte [bp + 6], 0xFE         ; CF = 0
    cmp ah, API_MAX
    jae .ai_bad
    mov bl, ah
    xor bh, bh
    shl bx, 1
    mov bx, [api_tab + bx]
    mov [api_fn], bx
    mov bx, [bp - 6]                ; BX программы — входной параметр многих функций
    ; курсор мыши убирается на время вызова, чтобы вывод не портил сохранённый атрибут
    cmp ah, 0x03                    ; GETKEY, SLEEP, MOUSESHOW — без скрытия (ждут/сами рисуют)
    je .ai_call
    cmp ah, 0x0D
    je .ai_call
    cmp ah, 0x1F
    je .ai_call
    call mouse_undraw
    call [api_fn]
    call mouse_draw
    jmp .ai_ret
.ai_call:
    call [api_fn]
    jmp .ai_ret
.ai_bad:
    or byte [bp + 6], 1
.ai_ret:
    pop bx
    pop es
    pop ds
    pop bp
    iret

api_tab:
    dw api_nop, api_putc, api_puts, api_getkey, api_keyhit, api_setcur
    dw api_getcur, api_cls, api_readfile, api_writefile, api_ticks
    dw api_printdec, api_getcwd, api_sleep, api_uiredraw
    dw api_rand, api_cursor, api_localtime, api_username, api_beep, api_kbflush
    dw api_putat, api_fillrect, api_putsat
    dw api_readdir, api_shell, api_exec, api_stat, api_readat, api_append
    dw api_mouse, api_mouseshow, api_chdir, api_wm, api_audio, api_date

api_rand:
    mov ax, [rand_seed]
    mov bx, 25173
    mul bx
    add ax, 13849
    mov [rand_seed], ax
    push es
    xor bx, bx
    mov es, bx
    add ax, [es:0x046C]             ; подмешать таймер
    pop es
    mov [rand_seed], ax
    ret
api_cursor:
    mov ah, 0x01
    int 0x10
    ret
api_localtime:
    call get_local_time
    mov ch, [lt_h]
    mov cl, [lt_mi]
    mov dh, [lt_s]
    mov dl, [lt_d]
    ret
; 23 date -> CX год, DH месяц, DL день, AL день недели (0 = воскресенье), AH = 0
api_date:
    call get_local_time
    mov cx, [lt_y]
    mov dh, [lt_mo]
    mov dl, [lt_d]
    ; день недели по Зеллеру (Sakamoto): y -= m<3; (y + y/4 - y/100 + y/400 + t[m-1] + d) % 7
    push bx
    push dx
    mov ax, cx
    cmp dh, 3
    jae .ad_m
    dec ax
.ad_m:
    mov bx, ax                      ; bx = y
    xor dx, dx
    mov cx, 4
    div cx                          ; ax = y/4
    add bx, ax
    mov ax, [lt_y]
    cmp byte [lt_mo], 3
    jae .ad_m2
    dec ax
.ad_m2:
    push ax
    xor dx, dx
    mov cx, 100
    div cx
    sub bx, ax                      ; - y/100
    pop ax
    xor dx, dx
    mov cx, 400
    div cx
    add bx, ax                      ; + y/400
    pop dx                          ; dh месяц, dl день
    push dx
    mov al, dh
    xor ah, ah
    push bx
    mov bx, ax
    mov al, [lt_dow_t + bx - 1]
    pop bx
    add bx, ax
    mov al, dl
    xor ah, ah
    add bx, ax
    mov ax, bx
    xor dx, dx
    mov cx, 7
    div cx
    mov ax, dx                      ; остаток = день недели
    pop dx
    pop bx
    mov cx, [lt_y]
    ret
api_username:
    push si
    push di
    mov es, [api_ues]
    mov si, user_name
.un_cp:
    lodsb
    stosb
    test al, al
    jnz .un_cp
    pop di
    pop si
    mov bx, KSEG
    mov es, bx
    ret
api_beep:
    sti                             ; beep_short ждёт тик таймера
    call beep_short
    ret
api_kbflush:
    sti
    mov ah, 0x11
    int 0x16
    jz .kf_done
    mov ah, 0x10
    int 0x16
    jmp api_kbflush
.kf_done:
    ret
; ES:DI <- видеоадрес (DH,DL); портит DI
api_vaddr:
    push ax
    push dx
    mov ax, 0xB800
    mov es, ax
    mov al, dh
    mov ah, 160
    mul ah
    mov dh, 0
    shl dx, 1
    add ax, dx
    mov di, ax
    pop dx
    pop ax
    ret
api_putat:
    push ax
    push di
    call api_vaddr
    mov ah, bl
    stosw
    pop di
    pop ax
    mov bx, KSEG
    mov es, bx
    ret
api_fillrect:
    push ax
    push di
    push cx
    push dx
    call api_vaddr
    mov ah, bl
.fr_row:
    push cx
    push di
    xor ch, ch
    rep stosw
    pop di
    pop cx
    add di, 160
    dec ch
    jnz .fr_row
    pop dx
    pop cx
    pop di
    pop ax
    mov bx, KSEG
    mov es, bx
    ret
api_putsat:
    push ax
    push si
    push di
    call api_vaddr
    mov ah, bl
.pa_loop:
    mov ds, [cs:api_uds]
    lodsb
    mov bx, KSEG
    mov ds, bx
    test al, al
    jz .pa_done
    stosw
    jmp .pa_loop
.pa_done:
    pop di
    pop si
    pop ax
    mov bx, KSEG
    mov es, bx
    ret

api_uiredraw:
    call clear_screen
    call draw_ui
    ret

api_nop:
    ret
api_putc:
    call print_char
    ret
api_puts:
    push si
.ap_loop:
    mov ds, [cs:api_uds]
    lodsb
    mov bx, KSEG
    mov ds, bx
    test al, al
    jz .ap_done
    call print_char
    jmp .ap_loop
.ap_done:
    pop si
    ret
api_getkey:
    sti
    mov ah, 0x10
    int 0x16
    ret
api_keyhit:
    sti
    mov ah, 0x11
    int 0x16
    jnz .ak_yes
    xor ax, ax
    or byte [bp + 6], 0x40          ; ZF = 1
    ret
.ak_yes:
    and byte [bp + 6], 0xBF         ; ZF = 0
    ret
api_setcur:
    mov ah, 0x02
    xor bh, bh
    int 0x10
    ret
api_getcur:
    push es
    xor dx, dx
    mov es, dx
    mov dx, [es:0x0450]
    pop es
    ret
api_cls:
    call clear_screen
    ret
api_ticks:
    push es
    xor ax, ax
    mov es, ax
    mov ax, [es:0x046C]
    mov dx, [es:0x046E]
    pop es
    ret
api_printdec:
    mov ax, dx
    call print_dec_ax
    ret
api_sleep:
    sti
    call wait_ticks
    ret
api_getcwd:
    push si
    push di
    mov es, [api_ues]
    mov si, cur_path + 1
    cmp byte [si], 0
    jne .gc_cp
    mov si, path_root
.gc_cp:
    lodsb
    stosb
    test al, al
    jnz .gc_cp
    pop di
    pop si
    mov bx, KSEG
    mov es, bx
    ret


; 18: READDIR — DS:SI путь ("" = текущий), ES:DI буфер, CX макс. записей -> AX записей (по 32 байта)
api_readdir:
    push cx
    push si
    push di
    mov [rd_max], cx
    call api_copy_path
    call path_save
    cmp byte [api_path], 0
    je .rd_here
    mov si, api_path
    call resolve_path
    jc .rd_fail
    cmp byte [rp_isdir], 1
    je .rd_here
    call cd_enter                   ; последний компонент — каталог?
    jc .rd_fail
.rd_here:
    call load_dir
    jc .rd_fail
    mov es, [api_ues]
    push ds
    mov ax, 0x2000
    mov ds, ax
    xor si, si
    mov cx, [cs:dir_nent]
    xor dx, dx                      ; счётчик
.rd_loop:
    jcxz .rd_end
    mov al, [si]
    test al, al
    jz .rd_end
    cmp al, 0xE5
    je .rd_next
    mov al, [si + 11]
    and al, 0x0F
    cmp al, 0x0F                    ; LFN
    je .rd_next
    test byte [si + 11], 0x08       ; метка тома
    jnz .rd_next
    cmp dx, [cs:rd_max]
    jae .rd_end
    push cx
    push si
    mov cx, 32
    rep movsb
    pop si
    pop cx
    inc dx
.rd_next:
    add si, 32
    dec cx
    jmp .rd_loop
.rd_end:
    pop ds
    mov ax, dx
    call path_restore
    clc
    jmp .rd_ret
.rd_fail:
    call path_restore
    or byte [bp + 6], 1
    xor ax, ax
.rd_ret:
    mov bx, KSEG
    mov es, bx
    pop di
    pop si
    pop cx
    ret

; 19: SHELL — выполнить строку оболочки DS:SI (вывод — на экран с текущей позиции курсора).
; Запуск программ изнутри программы запрещён (см. EXEC)
api_shell:
    push si
    push di
    call api_copy_path
    mov si, api_path
    call ib_set
    sti
    call exec_line
    pop di
    pop si
    ret

; 1A: EXEC — после выхода программы выполнить команду DS:SI и перезапустить программу
api_exec:
    push si
    push di
    call api_copy_path
    mov si, api_path
    mov di, chain_cmd
.ex_cp:
    lodsb
    mov [di], al
    inc di
    test al, al
    jnz .ex_cp
    mov byte [chain_flag], 1
    mov [chain_pause], dl           ; DL=1: после команды ждать клавишу
    pop di
    pop si
    ret

; 1B: STAT — DS:SI путь -> DX:AX размер, CL атрибут; CF=1 нет
api_stat:
    push si
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .st_fail
    cmp byte [rp_isdir], 1
    je .st_dir
    call load_dir
    jc .st_fail
    push es
    mov ax, 0x2000
    mov es, ax
    call find_dir_entry
    jnc .st_fail_es
    mov cl, [es:si + 11]
    mov ax, [es:si + 28]
    mov dx, [es:si + 30]
    pop es
    call path_restore
    clc
    jmp .st_ret
.st_dir:
    mov cl, 0x10
    xor ax, ax
    xor dx, dx
    call path_restore
    clc
    jmp .st_ret
.st_fail_es:
    pop es
.st_fail:
    call path_restore
    or byte [bp + 6], 1
.st_ret:
    pop si
    ret

; 1C: READAT — DS:SI путь, ES:DI буфер, BX сектор файла (512-байтный), CX макс. байт -> AX прочитано
api_readat:
    push si
    push di
    push cx
    push bx
    mov [api_savecx], cx
    mov [api_savedi], di
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .ra_fail
    cmp byte [rp_isdir], 1
    je .ra_fail
    mov es, [api_ues]
    mov cx, [api_savecx]
    mov di, [api_savedi]
    mov bx, [bp - 6]                ; BX программы (сохранён в api_int: bp, ds, es, bx)
    call file_read_chunk
    jc .ra_fail
    call path_restore
    clc
    jmp .ra_ret
.ra_fail:
    call path_restore
    or byte [bp + 6], 1
    xor ax, ax
.ra_ret:
    mov bx, KSEG
    mov es, bx
    pop bx
    pop cx
    pop di
    pop si
    ret

; 1D: APPEND — DS:SI путь, ES:DI данные, CX длина -> CF=1 ошибка
api_append:
    push si
    push di
    push cx
    mov [save_len], cx
    mov [save_off], di
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .ap_fail
    cmp byte [rp_isdir], 1
    je .ap_fail
    mov ax, [api_ues]
    mov [save_seg], ax
    call file_append
    jc .ap_fail
    call path_restore
    clc
    jmp .ap_ret
.ap_fail:
    call path_restore
    or byte [bp + 6], 1
.ap_ret:
    pop cx
    pop di
    pop si
    ret

; 1E: MOUSE -> CX столбец, DX строка, AL кнопки (bit0 левая, bit1 правая), AH = 1 если мышь есть
api_mouse:
    mov cx, [mouse_col]
    mov dx, [mouse_row]
    mov al, [mouse_btn]
    mov ah, [mouse_present]
    ret

; 1F: MOUSESHOW — CL = 1 показать курсор мыши, 0 спрятать
api_mouseshow:
    call mouse_show
    ret

; 20: CHDIR — DS:SI путь -> CF=1 ошибка (меняет текущий каталог оболочки)
; 21: WM — оконный менеджер. AL=0 установить обработчик (DX = смещение в сегменте вызывающего,
;     CL = строк экрана 25/50 для мыши); AL=1 снять; AL=2 загрузить программу: DS:SI путь,
;     DX = сегмент, ES:DI аргументы (ASCIIZ) -> AX точка входа; CF=1 ошибка
; 22: AUDIO — потоковый PCM-выход через Intel HDA (нужен 386+ и контроллер HDA).
;     AL=0 открыть: ES:DI буфер из двух половин подряд, CX = размер половины в байтах
;          (кратно 128, <= 32768), BX = формат SDFMT (0011h = 48 кГц 16 бит стерео,
;          0010h = моно; 0110h = 24 кГц моно...). Воспроизведение — по кругу: программа
;          заполняет ту половину, которая сейчас не играет. CF=1 нет HDA/ошибка
;     AL=1 опрос: -> AL = играющая половина (0/1), DX = позиция в ней (байт)
;     AL=2 закрыть (остановить поток)
api_audio:
    cmp al, 0
    je .au_open
    cmp al, 1
    je .au_poll
    cmp al, 2
    je .au_close
    jmp .au_fail
.au_open:
    cmp byte [hda_api_on], 0
    jne .au_fail
    push cx
    push bx
    sti                             ; hda_init ждёт по таймеру BIOS
    call hda_init
    pop bx
    pop cx
    jc .au_fail
    mov [hda_fmt], bx
    push eax
    movzx eax, cx
    mov [hda_halfsz], eax
    movzx eax, word [api_ues]
    shl eax, 4
    movzx ecx, di
    add eax, ecx
    mov [hda_bufaddr], eax
    pop eax
    call hda_stream_setup
    jc .au_fail
    call hda_stream_run
    mov byte [hda_api_on], 1
    ret
.au_poll:
    cmp byte [hda_api_on], 0
    je .au_fail
    call hda_playing_half
    mov dx, [hda_lpib_in]
    ret
.au_close:
    cmp byte [hda_api_on], 0
    je .au_fail
    call hda_stream_stop
    mov byte [hda_api_on], 0
    ret
.au_fail:
    or byte [bp + 6], 1
    ret

api_wm:
    cmp al, 0
    je .wm_install
    cmp al, 1
    je .wm_remove
    cmp al, 2
    je .wm_load
    cmp al, 3
    je .wm_conseg
    or byte [bp + 6], 1
    ret
.wm_conseg:
    ; CX = сегмент консольного вывода ядра (print_char), 0 = B800h; AX <- прежний
    mov ax, [con_seg]
    test cx, cx
    jnz .wm_c1
    mov cx, 0xB800
.wm_c1:
    mov [con_seg], cx
    ret
.wm_install:
    mov [wm_handler], dx
    mov ax, [bp + 4]
    mov [wm_handler + 2], ax
    mov byte [mouse_rowsh], 4
    cmp cl, 50
    jne .wm_i1
    mov byte [mouse_rowsh], 3
.wm_i1:
    mov [wm_seg], ax
    ret
.wm_remove:
    mov word [wm_seg], 0
    mov word [con_seg], 0xB800
    mov byte [mouse_rowsh], 4
    ret
.wm_load:
    push si
    push di
    push cx
    push dx
    push dx
    mov [api_savedi], di
    mov [api_savecx], cx
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .wl_fail
    cmp byte [rp_isdir], 1
    je .wl_fail
    mov word [rf_limit], APP_MAX
    mov word [rf_limit + 2], 0
    call read_file
    jc .wl_fail
    cmp word [save_len], 16
    jb .wl_fail
    mov ax, CP_SEG
    mov es, ax
    cmp word [es:0], 0x4146         ; "FA"
    jne .wl_fail
    cmp word [es:2], 0x4950         ; "PI"
    jne .wl_fail
    mov dx, [es:6]                  ; точка входа
    pop es                          ; целевой сегмент
    push es
    push ds
    mov cx, [save_len]
    mov ax, CP_SEG
    mov ds, ax
    xor si, si
    mov di, 0x0100
    rep movsb
    pop ds
    xor di, di
    mov cx, 0x40
    xor ax, ax
    rep stosw
    mov word [es:0], 3              ; версия API
    mov ax, [api_savecx]
    mov [es:0x10], ax               ; сегмент «видеопамяти» (виртуальный экран окна)
    ; аргументы из пользовательского ES:DI -> seg:0080
    push ds
    mov ds, [cs:api_ues]
    mov si, [cs:api_savedi]
    mov di, 0x80
    mov cx, 127
.wl_args:
    lodsb
    stosb
    test al, al
    loopnz .wl_args
    mov byte [es:di], 0
    pop ds
    call path_restore
    pop dx
    pop dx
    pop cx
    pop di
    pop si
    mov ax, [es:0x106]              ; точка входа из заголовка
    mov bx, KSEG
    mov es, bx
    ret
.wl_fail:
    call path_restore
    pop dx
    pop dx
    pop cx
    pop di
    pop si
    mov bx, KSEG
    mov es, bx
    or byte [bp + 6], 1
    ret

api_chdir:
    push si
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .cd_fail
    cmp byte [rp_isdir], 1
    je .cd_ok
    call cd_enter
    jc .cd_fail
.cd_ok:
    clc
    jmp .cd_ret
.cd_fail:
    call path_restore
    or byte [bp + 6], 1
.cd_ret:
    pop si
    ret

;=================== Мышь (PS/2 через BIOS int 15h) ===================
; Координаты в знакоместах; курсор — инверсия атрибута знакоместа.
mouse_init:
    pusha
    push es
    mov byte [mouse_present], 0
    mov ax, 0xC205                  ; инициализация, пакет 3 байта
    mov bh, 3
    int 0x15
    jc .mi_done
    mov ax, 0xC203                  ; разрешение 8 отсчётов/мм
    mov bh, 3
    int 0x15
    mov ax, 0xC207                  ; обработчик
    push cs
    pop es
    mov bx, mouse_handler
    int 0x15
    jc .mi_done
    mov ax, 0xC200                  ; включить
    mov bh, 1
    int 0x15
    jc .mi_done
    mov byte [mouse_present], 1
    mov word [mouse_x], 320
    mov word [mouse_y], 200
    mov word [mouse_col], 40
    mov word [mouse_row], 12
.mi_done:
    pop es
    popa
    ret

mouse_handler:
    push ds
    pusha
    mov ax, KSEG
    mov ds, ax
    mov bp, sp
    mov ax, [bp + 28]               ; статус
    mov [mouse_btn], al
    and byte [mouse_btn], 3
    mov bx, [bp + 26]               ; dx
    mov cx, [bp + 24]               ; dy
    test al, 0x10
    jz .mh_x
    mov bh, 0xFF
.mh_x:
    test al, 0x20
    jz .mh_y
    mov ch, 0xFF
.mh_y:
    add bx, [mouse_x]
    jns .mh_x1
    xor bx, bx
.mh_x1:
    cmp bx, 639
    jbe .mh_x2
    mov bx, 639
.mh_x2:
    mov [mouse_x], bx
    mov ax, [mouse_y]
    sub ax, cx                      ; вверх = +dy
    jns .mh_y1
    xor ax, ax
.mh_y1:
    cmp ax, 399
    jbe .mh_y2
    mov ax, 399
.mh_y2:
    mov [mouse_y], ax
    mov cl, [mouse_rowsh]
    shr ax, cl                      ; строка = y/16 (y/8 в режиме 50 строк)
    mov cl, 3
    shr bx, cl                      ; столбец = x/8
    cmp ax, [mouse_row]
    jne .mh_moved
    cmp bx, [mouse_col]
    je .mh_ret
.mh_moved:
    call mouse_undraw
    mov [mouse_row], ax
    mov [mouse_col], bx
    call mouse_draw
.mh_ret:
    popa
    pop ds
    retf

; инверсия атрибута под курсором (если курсор видим)
mouse_draw:
    cmp byte [mouse_vis], 0
    je .md_ret
    cmp byte [mouse_drawn], 0
    jne .md_ret
    push ax
    push bx
    push cx
    push es
    call mouse_cell
    mov al, [es:bx]
    mov [mouse_saved], al
    mov cl, 4
    rol al, cl                      ; поменять фон и текст местами
    and al, 0x77
    mov [es:bx], al
    mov byte [mouse_drawn], 1
    pop es
    pop cx
    pop bx
    pop ax
.md_ret:
    ret
mouse_undraw:
    cmp byte [mouse_drawn], 0
    je .mu_ret
    push ax
    push bx
    push es
    call mouse_cell
    mov al, [mouse_saved]
    mov [es:bx], al
    mov byte [mouse_drawn], 0
    pop es
    pop bx
    pop ax
.mu_ret:
    ret
; ES:BX -> байт атрибута знакоместа курсора
mouse_cell:
    push ax
    push dx
    mov ax, 0xB800
    mov es, ax
    mov ax, [mouse_row]
    mov dx, 160
    mul dx
    mov bx, [mouse_col]
    shl bx, 1
    add bx, ax
    inc bx
    pop dx
    pop ax
    ret
; CL = 1 показать / 0 спрятать
mouse_show:
    pushf
    cli
    test cl, cl
    jz .ms_hide
    cmp byte [mouse_present], 0
    je .ms_ret
    mov byte [mouse_vis], 1
    call mouse_draw
    jmp .ms_ret
.ms_hide:
    call mouse_undraw
    mov byte [mouse_vis], 0
.ms_ret:
    popf
    ret

; скопировать ASCIIZ путь из пользовательского DS:SI в api_path (макс. 79)
api_copy_path:
    push si
    push di
    push cx
    mov di, api_path
    mov cx, 79
.cp_loop:
    mov ds, [cs:api_uds]
    lodsb
    mov bx, KSEG
    mov ds, bx
    stosb
    test al, al
    jz .cp_done
    loop .cp_loop
    mov byte [di], 0
.cp_done:
    pop cx
    pop di
    pop si
    ret

api_readfile:
    push cx
    push si
    push di
    mov [api_savecx], cx
    mov [api_savedi], di
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .arf_nf
    cmp byte [rp_isdir], 1
    je .arf_nf
    mov cx, [api_savecx]
    mov di, [api_savedi]
    mov [rf_limit], cx
    mov word [rf_limit + 2], 0
    call read_file
    jnc .arf_ok
    mov ax, 3
    cmp si, cp_toobig
    jne .arf_chk
    mov ax, 2
    jmp .arf_err
.arf_chk:
    cmp si, cat_nfound
    jne .arf_err
.arf_nf:
    mov ax, 1
.arf_err:
    or byte [bp + 6], 1
    jmp .arf_done
.arf_ok:
    mov cx, [save_len]
    push ds
    mov ax, CP_SEG
    mov ds, ax
    mov es, [cs:api_ues]
    xor si, si
    rep movsb
    pop ds
    mov ax, [save_len]
.arf_done:
    call path_restore
    mov bx, KSEG
    mov es, bx
    pop di
    pop si
    pop cx
    ret

api_writefile:
    push cx
    push si
    push di
    call api_copy_path
    call path_save
    mov si, api_path
    call resolve_path
    jc .awf_err
    cmp byte [rp_isdir], 1
    je .awf_err
    mov [save_len], cx
    mov [save_off], di
    mov ax, [api_ues]
    mov [save_seg], ax
    call save_file
    jnc .awf_done
.awf_err:
    or byte [bp + 6], 1
.awf_done:
    call path_restore
    pop di
    pop si
    pop cx
    ret

; run FILE [ARGS] — .SH скрипт или .FAP программа (по расширению)
; sh FILE.SH — выполнить скрипт
sh_command:
    pusha
    mov si, input_buffer
    add si, 2
    call skip_spaces
    cmp byte [si], 0
    je .sh_usage
    call script_run
    popa
    ret
.sh_usage:
    mov si, sh_usage
    call print_string
    popa
    ret

run_command:
    pusha
    mov si, input_buffer
    add si, 3
    call skip_spaces
    cmp byte [si], 0
    je .rc_usage
    ; найти расширение последнего компонента
    mov di, si
.rc_scan:
    lodsb
    cmp al, ' '
    je .rc_scan_end
    test al, al
    jnz .rc_scan
.rc_scan_end:
    dec si                          ; SI -> конец имени
    mov bx, si
.rc_back:
    cmp bx, di
    je .rc_app
    dec bx
    cmp byte [bx], '/'
    je .rc_app
    cmp byte [bx], '.'
    jne .rc_back
    mov al, [bx + 1]
    call to_upper
    cmp al, 'S'
    jne .rc_app
    mov al, [bx + 2]
    call to_upper
    cmp al, 'H'
    jne .rc_app
    mov si, di
    call script_run
    jmp .rc_done
.rc_app:
    mov si, di
    call app_load_path              ; SI -> "path args"
    jc .rc_fail
    call app_exec
    jmp .rc_done
.rc_usage:
    mov si, run_usage
    jmp .rc_msg
.rc_fail:
    mov si, app_err
.rc_msg:
    call print_string
.rc_done:
    popa
    ret

; Неизвестная команда: попробовать NAME.FAP в текущем каталоге, затем в корне.
; SI = input_buffer. CF=0 — программа выполнена
app_try_run:
    pusha
    mov si, input_buffer
    mov di, api_path
    xor cx, cx
.atr_name:
    lodsb
    cmp al, ' '
    je .atr_name_end
    test al, al
    jz .atr_name_end
    cmp al, '.'
    je .atr_no                      ; имя с точкой/путём — не команда
    cmp al, '/'
    je .atr_no
    cmp cx, 8
    jae .atr_no
    stosb
    inc cx
    jmp .atr_name
.atr_name_end:
    dec si
    push si                         ; -> аргументы
    mov si, app_ext
    mov cx, 5
    rep movsb                       ; ".FAP",0
    pop si
    push si
    mov si, api_path
    call app_load_file              ; текущий каталог
    pop si
    jnc .atr_go
    ; /SYSTEM/SYSAPPS/NAME.FAP, затем корень
    push si
    mov si, sysapps_path
    call app_prefix_path
    mov si, api_path2
    call app_load_file
    pop si
    jnc .atr_go
    push si
    mov si, root_path
    call app_prefix_path
    mov si, api_path2
    call app_load_file
    pop si
    jc .atr_no
.atr_go:
    call app_set_args               ; SI -> аргументы
    call app_exec
    popa
    clc
    ret
.atr_no:
    popa
    stc
    ret

; api_path2 = строка DS:SI (префикс каталога) + api_path (имя)
app_prefix_path:
    push ax
    push di
    mov di, api_path2
.app_p1:
    lodsb
    test al, al
    jz .app_p2
    stosb
    jmp .app_p1
.app_p2:
    mov si, api_path
.app_p3:
    lodsb
    stosb
    test al, al
    jnz .app_p3
    pop di
    pop ax
    ret

; SI -> "path [args]": загрузить программу и сохранить аргументы. CF=1 ошибка
app_load_path:
    push si
    push di
    mov di, api_path2
.alp_cp:
    lodsb
    cmp al, ' '
    je .alp_end
    stosb
    test al, al
    jnz .alp_cp
    dec si
.alp_end:
    mov byte [di], 0
    push si
    mov si, api_path2
    call app_load_file
    pop si
    jc .alp_ret
    call app_set_args
    clc
.alp_ret:
    pop di
    pop si
    ret

; Загрузить файл по пути DS:SI в APP_SEG:0100h, проверить сигнатуру. CF=1 ошибка
app_load_file:
    pusha
    push es
    cmp byte [app_depth], 0
    jne .alf_nested
    call path_save
    push si
    mov di, app_lastpath            ; запомнить путь для перезапуска (EXEC-цепочка)
    mov cx, 80
.alf_sv:
    lodsb
    stosb
    test al, al
    loopnz .alf_sv
    pop si
    call resolve_path
    jc .alf_fail
    cmp byte [rp_isdir], 1
    je .alf_fail
    mov word [rf_limit], APP_MAX
    mov word [rf_limit + 2], 0
    call read_file
    jc .alf_fail
    cmp word [save_len], 16
    jb .alf_fail
    mov ax, CP_SEG
    mov es, ax
    cmp word [es:0], 0x4146         ; "FA"
    jne .alf_fail
    cmp word [es:2], 0x4950         ; "PI"
    jne .alf_fail
    mov ax, [es:6]
    mov [app_entry], ax
    ; копия CP_SEG:0 -> APP_SEG:0100h
    push ds
    mov cx, [save_len]
    mov ax, APP_SEG
    mov es, ax
    mov ax, CP_SEG
    mov ds, ax
    xor si, si
    mov di, 0x0100
    rep movsb
    pop ds
    ; служебная область
    xor di, di
    mov cx, 0x80
    xor ax, ax
    rep stosw
    mov word [es:0], 3              ; версия API
    mov word [es:0x10], 0xB800      ; сегмент видеопамяти для прямого вывода
    call path_restore
    pop es
    popa
    clc
    ret
.alf_nested:
    mov si, app_nested_msg
    call print_string
    pop es
    popa
    stc
    ret
.alf_fail:
    call path_restore
    pop es
    popa
    stc
    ret

; SI -> аргументы (с ведущими пробелами) -> APP_SEG:0080h (до 126 байт)
app_set_args:
    pusha
    push es
    call skip_spaces
    mov ax, APP_SEG
    mov es, ax
    mov di, 0x80
    mov cx, 126
.asa_cp:
    lodsb
    stosb
    test al, al
    jz .asa_done
    loop .asa_cp
    mov byte [es:di], 0
.asa_done:
    pop es
    popa
    ret

; Запуск загруженной программы; возврат сюда после exit/retf
app_exec:
    pusha
    push ds
    push es
.ae_again:
    inc byte [app_depth]
    mov byte [chain_flag], 0
    mov [app_ss], ss
    mov [app_sp], sp
    mov ax, APP_SEG
    cli
    mov ss, ax
    mov sp, 0xFFFE
    sti
    mov ds, ax
    mov es, ax
    push word KSEG                  ; retf из программы -> app_exit_far
    push word app_exit_far
    push ax                         ; far-переход на точку входа
    push word [cs:app_entry]
    mov si, 0x80                    ; DS:SI -> аргументы
    xor ax, ax
    xor bx, bx
    xor cx, cx
    xor dx, dx
    xor di, di
    xor bp, bp
    retf
app_exit_far:
    cli
    mov ax, KSEG
    mov ds, ax
    mov es, ax
    mov ss, [app_ss]
    mov sp, [app_sp]
    sti
    cld
    dec byte [app_depth]
    xor cl, cl
    call mouse_show                 ; курсор мыши после программы всегда спрятан
    cmp byte [hda_api_on], 0        ; программа забыла закрыть звуковой поток
    je .ae_snd
    call hda_stream_stop
    mov byte [hda_api_on], 0
.ae_snd:
    cmp byte [chain_flag], 0
    je .ae_done
    ; EXEC-цепочка: выполнить команду, затем перезапустить программу с теми же аргументами
    mov byte [chain_flag], 0
    push ds
    pop es
    mov si, app_lastpath
    mov di, app_savepath
    mov cx, 80
    rep movsb
    push ds
    mov ax, APP_SEG
    mov ds, ax
    mov si, 0x80
    mov di, app_saveargs
    mov cx, 128
    rep movsb
    pop ds
    mov si, chain_cmd
    call ib_set
    call exec_line
    cmp byte [chain_pause], 0
    je .ae_reload
    mov si, chain_pause_msg
    call print_string
    mov ah, 0x10
    int 0x16
.ae_reload:
    ; перезагрузить исходную программу
    mov si, app_savepath
    call app_load_file
    jc .ae_done
    push ds
    pop es
    mov si, app_saveargs
    mov di, app_cmdbuf
    mov cx, 128
    rep movsb
    mov si, app_cmdbuf
    call app_set_args
    jmp app_exec.ae_again
.ae_done:
    pop es
    pop ds
    popa
    ret

;=================== Скрипты (.SH) ===================
; Файл копируется в SCR_SEG:SCRIPT_OFF, строки выполняются через exec_line.
; '#' — комментарий. Вложенный run скрипта из скрипта запрещён.
SCRIPT_OFF equ 0x9000
SCRIPT_MAX equ 0x6000

script_run:
    pusha
    push es
    cmp byte [script_busy], 0
    jne .sr_nested
    call path_save
    call resolve_path
    jc .sr_fail
    cmp byte [rp_isdir], 1
    je .sr_fail
    mov word [rf_limit], SCRIPT_MAX
    mov word [rf_limit + 2], 0
    call read_file
    call path_restore
    jc .sr_fail2
    push ds
    mov cx, [save_len]
    mov [script_len], cx
    mov ax, SCR_SEG
    mov es, ax
    mov ax, CP_SEG
    mov ds, ax
    xor si, si
    mov di, SCRIPT_OFF
    rep movsb
    pop ds
    mov byte [script_busy], 1
    mov word [script_pos], 0
.sr_line:
    mov ax, [script_pos]
    cmp ax, [script_len]
    jae .sr_end
    mov ax, SCR_SEG
    mov es, ax
    mov si, [script_pos]
    add si, SCRIPT_OFF
    mov di, input_buffer
    xor cx, cx
.sr_copy:
    mov ax, [script_pos]
    cmp ax, [script_len]
    jae .sr_eol
    mov al, [es:si]
    inc si
    inc word [script_pos]
    cmp al, 10
    je .sr_eol
    cmp al, 13
    je .sr_copy
    cmp cx, 1000
    jae .sr_copy
    mov [di], al
    inc di
    inc cx
    jmp .sr_copy
.sr_eol:
    mov byte [di], 0
    ; пропустить ведущие пробелы, пустые строки и комментарии
    mov si, input_buffer
    call skip_spaces
    cmp byte [si], 0
    je .sr_line
    cmp byte [si], '#'
    je .sr_line
    cmp si, input_buffer
    je .sr_exec
    mov di, input_buffer
.sr_shift:
    lodsb
    stosb
    test al, al
    jnz .sr_shift
.sr_exec:
    push ds
    pop es
    call exec_line
    jmp .sr_line
.sr_end:
    mov byte [script_busy], 0
    jmp .sr_ret
.sr_nested:
    mov si, script_nested
    jmp .sr_msg
.sr_fail:
    call path_restore
.sr_fail2:
    mov si, script_err
.sr_msg:
    call print_string
.sr_ret:
    pop es
    popa
    ret

; AUTOEXEC.SH в корне (если есть) — выполняется при старте
autoexec_run:
    pusha
    call path_save
    mov bx, autoexec_path
    call sys_dir_enter
    jnc .ae_find
    mov bx, autoexec_root
.ae_find:
    mov si, autoexec_name
    mov di, cat_name
    mov cx, 11
    rep movsb
    call load_dir
    jc .ae_done
    call find_dir_entry
    jnc .ae_done
    call path_restore
    mov si, bx
    call script_run
    popa
    ret
.ae_done:
    call path_restore
    popa
    ret



; Имя записи FAT (ES:SI, 11 байт) -> ASCIIZ "NAME.EXT" в DS:DI
fm_name_to_str:
    push ax
    push cx
    push si
    push di
    mov cx, 8
.nts_name:
    mov al, [es:si]
    inc si
    cmp al, ' '
    je .nts_name_sp
    mov [di], al
    inc di
.nts_name_sp:
    loop .nts_name
    cmp byte [es:si], ' '
    je .nts_term
    mov byte [di], '.'
    inc di
    mov cx, 3
.nts_ext:
    mov al, [es:si]
    inc si
    cmp al, ' '
    je .nts_ext_sp
    mov [di], al
    inc di
.nts_ext_sp:
    loop .nts_ext
.nts_term:
    mov byte [di], 0
    pop di
    pop si
    pop cx
    pop ax
    ret

;=================== list_root_dir ===================
list_root_dir:
    pusha
    push es
    call path_save
    mov si, input_buffer
    add si, 2
    cmp byte [input_buffer], 'd'    ; "dir" vs "ls"
    jne .lr_arg
    inc si
.lr_arg:
    call skip_spaces
    mov byte [ls_long], 0
    cmp word [si], '-l'             ; ls -l — по одному файлу в строке, с длинными именами
    jne .lr_noflag
    mov byte [ls_long], 1
    add si, 2
    call skip_spaces
.lr_noflag:
    cmp byte [si], 0
    je .lr_go
    call resolve_path
    jc .lr_patherr
    cmp byte [rp_isdir], 1
    je .lr_go
    call cd_enter
    jc .lr_patherr
.lr_go:
    mov si, dir_header
    call print_cstring
    mov byte [con_attr], 0x0F
    call print_path
    mov byte [con_attr], 0x07
    mov si, dir_header2
    call print_string
    call load_dir
    jc .lr_read_err
    mov word [dir_count], 0
    mov word [dir_total], 0
    mov word [dir_total + 2], 0
    mov ax, 0x2000
    mov es, ax
    xor si, si
    mov byte [lfn_valid], 0
    mov cx, [dir_nent]
    test cx, cx
    jnz .lr_entry
    jmp .lr_end
.lr_entry:
    mov al, [es:si]
    test al, al
    jz .lr_end
    cmp al, 0xE5
    je .lr_nolfn
    mov al, [es:si + 11]
    and al, 0x0F
    cmp al, 0x0F
    je .lr_lfn
    test byte [es:si + 11], 0x08
    jnz .lr_nolfn
    push cx
    push si
    test byte [es:si + 11], 0x10
    jz .lr_nm_file
    mov byte [con_attr], 0x0E       ; каталоги — жёлтым
.lr_nm_file:
    call print_fat_name
    mov al, ' '
    call print_char
    pop si
    test byte [es:si + 11], 0x10
    jz .lr_file
    push si
    mov si, dir_marker
    call print_string
    pop si
    mov byte [con_attr], 0x07
    jmp .lr_after
.lr_file:
    mov byte [con_attr], 0x08       ; размеры — серым
    mov ax, [es:si + 28]
    mov dx, [es:si + 30]
    call print_dec_32
    mov byte [con_attr], 0x07
.lr_after:
    cmp byte [ls_long], 0
    jne .lr_long
    call ls_next_col                ; многоколоночный вывод: выровнять на границу колонки
    jmp .lr_count
.lr_long:
    cmp byte [lfn_valid], 0
    je .lr_eol
    push si
    mov al, ' '
    call print_char
    mov al, ' '
    call print_char
    mov si, lfn_buf
    call print_string
    pop si
.lr_eol:
    mov al, 13
    call print_char
    mov al, 10
    call print_char
.lr_count:
    mov byte [lfn_valid], 0
    inc word [dir_count]
    mov ax, [es:si + 28]
    add [dir_total], ax
    mov ax, [es:si + 30]
    adc [dir_total + 2], ax
    pop cx
    jmp .lr_skip
.lr_lfn:
    call lfn_collect
    jmp .lr_skip
.lr_nolfn:
    mov byte [lfn_valid], 0
.lr_skip:
    add si, 32
    dec cx
    jz .lr_end
    jmp .lr_entry
.lr_end:
    call ls_col_pos
    test dl, dl
    jz .lr_end_nl
    mov si, newline
    call print_string
.lr_end_nl:
    mov si, newline
    call print_string
    mov byte [con_attr], 0x08
    mov si, dir_footer1
    call print_string
    mov ax, [dir_count]
    call print_dec_ax
    mov si, dir_footer2
    call print_string
    mov ax, [dir_total]
    mov dx, [dir_total + 2]
    call print_dec_32
    mov si, dir_footer3
    call print_string
    mov byte [con_attr], 0x07
    jmp .lr_done
.lr_read_err:
    mov si, dir_err
.lr_patherr:
    call print_string
.lr_done:
    call path_restore
    pop es
    popa
    ret

; Текущий столбец курсора -> DL (из BDA)
ls_col_pos:
    push ds
    xor dx, dx
    mov ds, dx
    mov dl, [0x0450]
    pop ds
    ret

; Многоколоночный ls: дополнить пробелами до следующей границы LS_COLW;
; если следующая колонка не помещается в 80 символов — перевод строки
LS_COLW equ 26
ls_next_col:
    pusha
    call ls_col_pos
    mov al, dl
    xor ah, ah
    mov cl, LS_COLW
    div cl                          ; AH = позиция внутри колонки
    inc al
    mul cl                          ; AX = начало следующей колонки
    cmp ax, 80 - LS_COLW + 1
    jae .nc_nl
    mov cx, ax
.nc_pad:
    call ls_col_pos
    xor dh, dh
    cmp dx, cx
    jae .nc_done
    mov al, ' '
    call print_char
    jmp .nc_pad
.nc_nl:
    mov al, 13
    call print_char
    mov al, 10
    call print_char
.nc_done:
    popa
    ret

; Собрать кусок длинного имени из LFN-записи ES:SI в lfn_buf
; (13 символов UCS-2 на запись; порядковый номер в байте 0, бит 0x40 = последняя)
lfn_collect:
    pusha
    mov al, [es:si]
    test al, 0x40
    jz .lc_ord
    mov byte [lfn_valid], 1
    mov byte [lfn_buf + 260], 0
.lc_ord:
    and ax, 0x1F
    jz .lc_ret
    dec ax
    cmp ax, 20
    jae .lc_ret
    mov bx, ax
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bx
    add ax, bx
    add ax, bx
    add ax, bx
    add ax, bx                      ; *13
    mov di, lfn_buf
    add di, ax
    push si
    add si, 1
    mov cx, 5
    call .lc_copy
    pop si
    push si
    add si, 14
    mov cx, 6
    call .lc_copy
    pop si
    add si, 28
    mov cx, 2
    call .lc_copy
    test byte [es:si - 32], 0x40
    jz .lc_ret
    mov byte [di], 0                ; последняя запись — терминатор
.lc_ret:
    popa
    ret
.lc_copy:
    mov ax, [es:si]
    add si, 2
    test ax, ax
    jz .lc_term
    cmp ax, 0xFFFF
    je .lc_term
    cmp ah, 0
    je .lc_ascii
    mov al, '?'
.lc_ascii:
    mov [di], al
    inc di
    loop .lc_copy
    ret
.lc_term:
    mov byte [di], 0
    ret

; Имя 8.3 из ES:SI в виде NAME.EXT, дополненное пробелами до 13 символов
print_fat_name:
    pusha
    mov bx, si
    xor dx, dx                      ; напечатано символов
    mov cx, 8
    xor di, di
.pn_name:
    mov al, [es:bx + di]
    cmp al, ' '
    je .pn_name_done
    call print_char
    inc dx
    inc di
    loop .pn_name
.pn_name_done:
    cmp byte [es:bx + 8], ' '
    je .pn_pad
    mov al, '.'
    call print_char
    inc dx
    mov cx, 3
    mov di, 8
.pn_ext:
    mov al, [es:bx + di]
    cmp al, ' '
    je .pn_pad
    call print_char
    inc dx
    inc di
    loop .pn_ext
.pn_pad:
    cmp dx, 13
    jae .pn_done
    mov al, ' '
    call print_char
    inc dx
    jmp .pn_pad
.pn_done:
    popa
    ret

;=================== FAT helpers ===================
; Ищет cat_name в корне (0x2000:0). CF=1 найдено, SI = смещение записи
find_dir_entry:
    push es
    push cx
    push di
    push dx
    mov ax, 0x2000
    mov es, ax
    xor si, si
    mov cx, [dir_nent]
    jcxz .fd_not_found
.fd_loop:
    mov al, [es:si]
    test al, al
    jz .fd_not_found
    cmp al, 0xE5
    je .fd_skip
    mov al, [es:si + 11]
    and al, 0x0F
    cmp al, 0x0F
    je .fd_skip
    test byte [es:si + 11], 0x08
    jnz .fd_skip
    push cx
    push si
    mov di, cat_name
    mov dx, 11
.fd_cmp:
    mov al, [es:si]
    cmp al, [di]
    jne .fd_mismatch
    inc si
    inc di
    dec dx
    jnz .fd_cmp
    pop si
    pop cx
    pop dx
    pop di
    pop cx
    pop es
    stc
    ret
.fd_mismatch:
    pop si
    pop cx
.fd_skip:
    add si, 32
    loop .fd_loop
.fd_not_found:
    pop dx
    pop di
    pop cx
    pop es
    clc
    ret

; Свободная запись в текущем каталоге. CF=1 найдено, SI = смещение.
; Если подкаталог заполнен — добавляет кластер (FAT в памяти изменяется,
; вызывающий обязан потом сделать write_fats).
find_free_slot:
    push es
    push ax
    push bx
    push cx
    push dx
    push di
    mov ax, 0x2000
    mov es, ax
    xor si, si
    mov cx, [dir_nent]
    jcxz .fs_extend
.fs_loop:
    mov al, [es:si]
    test al, al
    jz .fs_found
    cmp al, 0xE5
    je .fs_found
    add si, 32
    loop .fs_loop
.fs_extend:
    cmp word [cur_dir], 0
    je .fs_none
    cmp word [dir_sectors], DIR_MAXS
    jae .fs_none
    call find_free_cluster
    test ax, ax
    jz .fs_none
    mov dx, [fat_eocv]
    call set_fat_entry              ; новый кластер = конец цепочки
    mov dx, ax
    mov ax, [dir_last]
    call set_fat_entry              ; старый последний -> новый
    mov [dir_last], dx
    mov di, [dir_sectors]
    mov cl, 9
    shl di, cl
    mov si, di
    mov cx, 256
    xor ax, ax
    rep stosw                       ; обнулить новый сектор в буфере
    inc word [dir_sectors]
    add word [dir_nent], 16
    jmp .fs_found
.fs_none:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    pop es
    clc
    ret
.fs_found:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    pop es
    stc
    ret

; -> AX = свободный кластер (0 = нет). Поиск идёт от подсказки fat_hint (следующий за
; последним найденным), затем с начала — иначе на большом томе каждый раз читалась бы вся FAT.
find_free_cluster:
    push cx
    push dx
    mov cx, [fat_hint]
    cmp cx, 2
    jb .ff_from2
    cmp cx, [fat_nclus]
    jb .ff_loop
.ff_from2:
    mov cx, 2
.ff_loop:
    mov ax, cx
    call fat_get
    test ax, ax
    jz .ff_found
    inc cx
    cmp cx, [fat_nclus]
    jb .ff_loop
    cmp word [fat_hint], 2          ; дошли до конца — второй проход с начала
    jbe .ff_none
    mov word [fat_hint], 2
    mov cx, 2
    jmp .ff_loop
.ff_found:
    mov ax, cx
    inc cx
    mov [fat_hint], cx
    pop dx
    pop cx
    ret
.ff_none:
    xor ax, ax
    pop dx
    pop cx
    ret

; AX = кластер, DX = значение
set_fat_entry:
    call fat_put
    ret

; AX = кластер -> AX = следующий
fat_next:
    call fat_get
    ret

; освободить цепочку от AX
free_fat_chain:
    push ax
    push dx
.fc_loop:
    cmp ax, [fat_eoc]
    jae .fc_done
    cmp ax, 2
    jb .fc_done
    mov [free_cur], ax
    call fat_next
    mov [free_next], ax
    mov ax, [free_cur]
    xor dx, dx
    call fat_put
    mov ax, [free_cur]
    cmp ax, [fat_hint]
    jae .fc_advance
    mov [fat_hint], ax              ; освобождённое место ниже подсказки — начнём с него
.fc_advance:
    mov ax, [free_next]
    jmp .fc_loop
.fc_done:
    pop dx
    pop ax
    ret

alloc_chain:
    push bx
    push cx
    push dx
    push si
    push di
    test bx, bx
    jz .ac_none
    call find_free_cluster
    test ax, ax
    jz .ac_none
    mov [alloc_first], ax
    mov di, ax
    mov dx, [fat_eocv]
    call set_fat_entry
    mov cx, bx
    dec cx
    jz .ac_done
.ac_loop:
    call find_free_cluster
    test ax, ax
    jz .ac_rollback
    push ax
    mov dx, [fat_eocv]
    call set_fat_entry
    pop ax
    push ax
    mov dx, ax
    mov ax, di
    call set_fat_entry
    pop ax
    mov di, ax
    dec cx
    jnz .ac_loop
.ac_done:
    mov ax, [alloc_first]
    jmp .ac_ret
.ac_rollback:
    mov ax, [alloc_first]
    call free_fat_chain
.ac_none:
    xor ax, ax
.ac_ret:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

;=================== ОБЩЕЕ ===================
clear_screen:
    mov ax, 0x0003
    int 0x10
    ret

draw_ui:
    pusha
    mov si, boot_art
    call print_cstring
    popa
    ret

print_prompt:
    pusha
    push es
    mov ah, 0x03
    mov bh, 0
    int 0x10
    push dx
    mov ax, 0xB800
    mov es, ax
    xor ax, ax
    mov al, dh
    mov bl, 80
    mul bl
    xor bx, bx
    mov bl, dl
    add ax, bx
    shl ax, 1
    mov di, ax
    pop dx
    mov si, prm_user
    mov ah, 0x0A
    call pp_string
    mov si, prm_colon
    mov ah, 0x08
    call pp_string
    mov si, cur_path
    mov ah, 0x0B
    call pp_string
    mov si, prm_dollar
    mov ah, 0x0F
    call pp_string
    mov ax, di
    shr ax, 1
    xor dx, dx
    mov bx, 80
    div bx
    mov dh, al
    mov ah, 0x02
    mov bh, 0
    int 0x10
    pop es
    popa
    ret

pp_string:
.pp_loop:
    lodsb
    test al, al
    jz .pp_done
    stosw
    jmp .pp_loop
.pp_done:
    ret

print_string:
    push ax
.ps_loop:
    lodsb
    test al, al
    jz .ps_done
    call print_char
    jmp .ps_loop
.ps_done:
    pop ax
    ret

; print_cstring: строка с разметкой цвета — байт 0x01, за ним атрибут.
; В конце цвет возвращается к 0x07.
print_cstring:
    push ax
.pcs_loop:
    lodsb
    test al, al
    jz .pcs_done
    cmp al, 1
    jne .pcs_ch
    lodsb
    mov [cs:con_attr], al
    jmp .pcs_loop
.pcs_ch:
    call print_char
    jmp .pcs_loop
.pcs_done:
    mov byte [cs:con_attr], 0x07
    pop ax
    ret

; print_char: вывод символа AL прямо в видеопамять с атрибутом [con_attr].
; BIOS-телетайп (int 10h/0Eh) не трогает атрибут ячейки, а при прокрутке
; реальный BIOS заливает новую строку цветом «из-под курсора» — на железе
; текст после промпта становился зелёным. Поэтому CR/LF/BS/прокрутку делаем сами,
; а BIOS'у только сообщаем позицию курсора (int 10h/02h).
print_char:
    pusha
    push es
    push ds
    xor bx, bx
    mov ds, bx
    mov dx, [0x0450]                ; BDA: курсор страницы 0 (DH=строка, DL=столбец)
    pop ds
    mov bx, [cs:con_seg]            ; B800h или виртуальный экран окна GUI (FAPI_WM al=3)
    mov es, bx
    cmp al, 13
    je .pc_cr
    cmp al, 10
    je .pc_lf
    cmp al, 8
    je .pc_bs
    cmp al, 7
    je .pc_done                     ; bell — молча
    ; обычный символ
    push ax
    mov al, dh
    mov ah, 80
    mul ah
    xor bh, bh
    mov bl, dl
    add ax, bx
    shl ax, 1
    mov di, ax
    pop ax
    mov ah, [cs:con_attr]
    stosw
    inc dl
    cmp dl, 80
    jb .pc_set
    xor dl, dl
    jmp .pc_lf
.pc_cr:
    xor dl, dl
    jmp .pc_set
.pc_bs:
    test dl, dl
    jz .pc_set
    dec dl
    jmp .pc_set
.pc_lf:
    inc dh
    cmp dh, 25
    jb .pc_set
    ; прокрутка на строку вверх, новая строка — пробелы с атрибутом 0x07
    push ds
    push es
    pop ds
    mov si, 160
    xor di, di
    mov cx, 80 * 24
    rep movsw
    pop ds
    mov ax, 0x0720
    mov cx, 80
    rep stosw
    mov dh, 24
.pc_set:
    mov ah, 0x02
    xor bh, bh
    int 0x10
.pc_done:
    pop es
    popa
    ret

; get_string: ввод строки в DS:DI (макс. [get_max]). Если [get_hist]=1 —
; стрелки вверх/вниз листают историю (8 последних команд), Enter сохраняет.
; Редактирование: <- -> Home End перемещают курсор, символы вставляются в позицию
; курсора, Backspace удаляет перед ним, Delete — под ним. Строка перерисовывается
; целиком от запомненной позиции начала ввода (gs_base), с учётом прокрутки.
get_string:
    push es
    mov ax, ds
    mov es, ax
    mov [gs_start], di
    mov al, [hist_count]
    mov [hist_pos], al
    xor cx, cx                      ; CX = длина строки
    mov word [gs_cur], 0            ; позиция курсора в строке
    mov word [gs_old], 0            ; сколько символов нарисовано (для стирания)
    call gs_cursor_lin
    mov [gs_base], ax               ; линейная позиция начала ввода на экране
.gs_loop:
    call gs_wait_key                ; ждёт клавишу, по таймауту — заставка
    test al, al
    jz .gs_ext
    cmp al, 0xE0                    ; серые клавиши на расширенной клавиатуре
    je .gs_ext
    cmp al, 13
    je .gs_done
    cmp al, 8
    je .gs_bs
    cmp al, 9
    je .gs_tab
    cmp al, 32
    jb .gs_loop                     ; Esc и прочие управляющие — игнор
    cmp cx, [get_max]
    jae .gs_loop
    call gs_insert                  ; вставить AL в позицию курсора
    jmp .gs_loop
.gs_ext:
    cmp ah, 0x4B                    ; <-
    je .gs_left
    cmp ah, 0x4D                    ; ->
    je .gs_right
    cmp ah, 0x47                    ; Home
    je .gs_home
    cmp ah, 0x4F                    ; End
    je .gs_end
    cmp ah, 0x53                    ; Delete
    je .gs_del
    cmp byte [get_hist], 0
    je .gs_loop
    cmp ah, 0x48
    je .gs_up
    cmp ah, 0x50
    je .gs_down
    jmp .gs_loop
.gs_left:
    cmp word [gs_cur], 0
    je .gs_loop
    dec word [gs_cur]
    call gs_place_cursor
    jmp .gs_loop
.gs_right:
    mov ax, [gs_cur]
    cmp ax, cx
    jae .gs_loop
    inc word [gs_cur]
    call gs_place_cursor
    jmp .gs_loop
.gs_home:
    mov word [gs_cur], 0
    call gs_place_cursor
    jmp .gs_loop
.gs_end:
    mov [gs_cur], cx
    call gs_place_cursor
    jmp .gs_loop
.gs_del:
    mov ax, [gs_cur]
    cmp ax, cx
    jae .gs_loop
    call gs_delete
    jmp .gs_loop
.gs_bs:
    cmp word [gs_cur], 0
    je .gs_loop
    dec word [gs_cur]
    call gs_delete
    jmp .gs_loop
.gs_tab:
    call gs_tab_complete
    jmp .gs_loop
.gs_up:
    cmp byte [hist_pos], 0
    je .gs_loop
    dec byte [hist_pos]
    call gs_show_hist
    jmp .gs_loop
.gs_down:
    mov al, [hist_pos]
    cmp al, [hist_count]
    jae .gs_loop
    inc byte [hist_pos]
    call gs_show_hist
    jmp .gs_loop
.gs_done:
    mov [gs_cur], cx
    call gs_place_cursor            ; курсор в конец, чтобы вывод шёл дальше
    mov di, [gs_start]
    add di, cx
    mov byte [di], 0
    call gs_store_hist
    mov byte [get_hist], 0
    mov si, newline
    call print_string
    pop es
    ret

; Ждать клавишу (AX). При бездействии дольше [saver_min] минут запускает
; заставку [saver_mode] (1 часы, 2 matrix), затем восстанавливает экран.
gs_wait_key:
    push bx
    push cx
    push dx
    push es
    xor ax, ax
    mov es, ax
    mov bx, [es:0x046C]             ; стартовый тик
.wk_loop:
    sti
    mov ah, 0x11
    int 0x16
    jnz .wk_key
    cmp byte [saver_mode], 0
    je .wk_idle
    mov al, [saver_min]
    xor ah, ah
    mov cx, 1092                    ; тиков в минуте (18.2 * 60)
    mul cx
    mov cx, ax
    mov ax, [es:0x046C]
    sub ax, bx
    cmp ax, cx
    jb .wk_idle
    call saver_run
    mov bx, [es:0x046C]
.wk_idle:
    hlt
    jmp .wk_loop
.wk_key:
    mov ah, 0x10
    int 0x16
    pop es
    pop dx
    pop cx
    pop bx
    ret

; Заставка: сохранить экран и курсор, показать, восстановить
saver_run:
    pusha
    push ds
    push es
    xor ax, ax
    mov es, ax
    mov dx, [es:0x0450]             ; курсор
    push dx
    mov ax, SCR_SEG
    mov es, ax
    mov ax, 0xB800
    mov ds, ax
    xor si, si
    mov di, 0x8000
    mov cx, 2000
    rep movsw
    mov ax, KSEG
    mov ds, ax
    cmp byte [saver_mode], 2
    je .sv_matrix
    call digital_clock
    jmp .sv_restore
.sv_matrix:
    call matrix_effect
.sv_restore:
    mov ax, SCR_SEG
    mov ds, ax
    mov ax, 0xB800
    mov es, ax
    mov si, 0x8000
    xor di, di
    mov cx, 2000
    rep movsw
    pop dx
    mov ah, 0x02
    xor bh, bh
    int 0x10
    pop es
    pop ds
    popa
    ret

; saver                      — показать
; saver off | clock [MIN] | matrix [MIN]
saver_command:
    pusha
    mov si, input_buffer
    add si, 5
    call skip_spaces
    mov al, [si]
    test al, al
    jz .sc_show
    call to_upper
    cmp al, 'O'
    je .sc_off
    mov ah, 1
    cmp al, 'C'
    je .sc_set
    mov ah, 2
    cmp al, 'M'
    je .sc_set
    jmp .sc_bad
.sc_off:
    mov byte [saver_mode], 0
    jmp .sc_save
.sc_set:
    mov [saver_mode], ah
.sc_word:
    lodsb
    cmp al, ' '
    je .sc_min
    test al, al
    jnz .sc_word
    jmp .sc_save
.sc_min:
    call skip_spaces
    cmp byte [si], 0
    je .sc_save
    call parse_uint
    test ax, ax
    jz .sc_bad
    cmp ax, 99
    ja .sc_bad
    mov [saver_min], al
.sc_save:
    call cfg_save
    mov si, tz_set_msg
    call print_string
.sc_show:
    mov si, saver_show
    call print_string
    mov al, [saver_mode]
    mov si, saver_s_off
    test al, al
    jz .sc_pr
    mov si, saver_s_clock
    cmp al, 1
    je .sc_pr
    mov si, saver_s_matrix
.sc_pr:
    call print_string
    cmp byte [saver_mode], 0
    je .sc_nl
    mov si, saver_after
    call print_string
    mov al, [saver_min]
    xor ah, ah
    call print_dec_ax
    mov si, saver_minutes
    call print_string
.sc_nl:
    mov si, newline
    call print_string
    popa
    ret
.sc_bad:
    mov si, saver_bad
    call print_string
    popa
    ret

; ---------- Tab: автодополнение ----------
; Слово = от последнего пробела до курсора. В начале строки (режим шелла) —
; имена команд из help_tab, иначе — файлы/каталоги (с учётом пути "dir/na").
; Один вариант — дописывается целиком (+ '/' каталогу, пробел файлу/команде),
; несколько — общий префикс, а если он уже набран — список вариантов.
gs_tab_complete:
    push ax
    push bx
    push dx
    push si
    push di
    ; --- выделить слово ---
    mov bx, [gs_start]
    mov di, [gs_cur]
.tc_back:
    test di, di
    jz .tc_word
    cmp byte [bx + di - 1], ' '
    je .tc_word
    dec di
    jmp .tc_back
.tc_word:
    mov dx, di                      ; DX = начало слова
    mov si, bx
    mov ax, [gs_cur]
    sub ax, dx
    cmp ax, 60
    ja .tc_ret
    mov [gs_wl], ax
    mov [gs_wstart], dx
    ; копия слова в верхнем регистре
    push cx
    mov cx, ax
    add si, dx
    mov di, gs_word
    mov byte [gs_lower], 0
    mov byte [gs_lcheck], 1
    jcxz .tc_wcopied
.tc_wc:
    lodsb
    cmp al, '/'
    je .tc_wc_slash
    jmp .tc_wc_case
.tc_wc_slash:
    mov byte [gs_lower], 0          ; регистр определяет первая буква после '/'
    mov byte [gs_lcheck], 1
    jmp .tc_wc_store
.tc_wc_case:
    cmp di, gs_word
    je .tc_wc_first
    cmp byte [gs_lcheck], 0
    je .tc_wc_store
.tc_wc_first:
    mov byte [gs_lcheck], 0
    cmp al, 'a'
    jb .tc_wc_store
    cmp al, 'z'
    ja .tc_wc_store
    mov byte [gs_lower], 1          ; набрано строчными — дописывать строчными
.tc_wc_store:
    call to_upper
    stosb
    loop .tc_wc
.tc_wcopied:
    mov byte [di], 0
    pop cx
    mov word [gs_cnt], 0
    mov word [gs_namep], gs_word
    mov byte [gs_mode], 0
    call gs_tc_scan
    cmp word [gs_cnt], 0
    je .tc_ret
    ; --- вставить остаток общего префикса (после набранной части имени) ---
    mov si, gs_cand
    add si, [gs_wl]
    mov ax, [gs_namep]
    sub ax, gs_word
    sub si, ax                      ; для файлов слово включает "dir/"
    mov di, gs_cand
    add di, [gs_clen]
    mov bx, si
.tc_ins:
    cmp si, di
    jae .tc_ins_done
    cmp cx, [get_max]
    jae .tc_ins_done
    lodsb
    cmp byte [gs_lower], 0
    je .tc_ins_ch
    cmp al, 'A'
    jb .tc_ins_ch
    cmp al, 'Z'
    ja .tc_ins_ch
    add al, 0x20
.tc_ins_ch:
    call gs_insert
    jmp .tc_ins
.tc_ins_done:
    cmp word [gs_cnt], 1
    jne .tc_many
    ; единственный вариант: пробел после файла/команды (каталог уже с '/')
    cmp byte [di - 1], '/'
    je .tc_ret
    cmp cx, [get_max]
    jae .tc_ret
    mov al, ' '
    call gs_insert
    jmp .tc_ret
.tc_many:
    cmp si, bx
    jne .tc_ret                     ; что-то дописали — список не нужен
    cmp byte [get_hist], 0
    je .tc_ret                      ; не в шелле — без списка
    mov si, newline
    call print_string
    mov byte [gs_mode], 1
    call gs_tc_scan
    mov si, newline
    call print_string
    call print_prompt
    push ax
    call gs_cursor_lin
    mov [gs_base], ax
    pop ax
    mov word [gs_old], 0
    call gs_redraw
.tc_ret:
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

; обойти кандидатов (команды или файлы) и вызвать gs_tc_cand для каждого
gs_tc_scan:
    pusha
    push es
    push ds
    pop es
    cmp word [gs_wstart], 0
    jne .ts_files
    cmp byte [get_hist], 0
    je .ts_files
    ; --- команды ---
    mov si, help_tab
.ts_cmd:
    cmp byte [si], 0
    je .ts_done
    push si
    mov di, gs_tmp
.ts_cn:
    lodsb
    stosb
    test al, al
    jnz .ts_cn
    mov si, gs_tmp
    call gs_tc_cand
    pop si
.ts_skip:                           ; имя,0 группа описание,0
    lodsb
    test al, al
    jnz .ts_skip
    inc si
.ts_desc:
    lodsb
    test al, al
    jnz .ts_desc
    jmp .ts_cmd
.ts_files:
    ; --- файлы: часть до последнего '/' — каталог ---
    call path_save
    mov si, gs_word
    mov bx, si                      ; BX -> имя (после последнего '/')
.ts_slash:
    lodsb
    test al, al
    jz .ts_split
    cmp al, '/'
    jne .ts_slash
    mov bx, si
    jmp .ts_slash
.ts_split:
    mov [gs_namep], bx
    cmp bx, gs_word
    je .ts_list
    ; каталог: скопировать "dir/" в gs_tmp и войти
    mov si, gs_word
    mov di, gs_tmp
.ts_dc:
    lodsb
    stosb
    cmp si, bx
    jb .ts_dc
    mov byte [di], 0
    mov si, gs_tmp
    call resolve_path
    jc .ts_fdone
    cmp byte [rp_isdir], 1
    jne .ts_fdone
.ts_list:
    call load_dir
    jc .ts_fdone
    mov ax, 0x2000
    mov es, ax
    xor si, si
    mov cx, [dir_nent]
.ts_ent:
    mov al, [es:si]
    test al, al
    jz .ts_fdone
    cmp al, 0xE5
    je .ts_next
    cmp al, '.'
    je .ts_next
    mov al, [es:si + 11]
    and al, 0x0F
    cmp al, 0x0F
    je .ts_next
    test byte [es:si + 11], 0x08
    jnz .ts_next
    mov di, gs_tmp
    call fm_name_to_str             ; ES:SI -> DS:DI
    test byte [es:si + 11], 0x10
    jz .ts_isfile
    push di
.ts_de:
    cmp byte [di], 0
    je .ts_de_end
    inc di
    jmp .ts_de
.ts_de_end:
    mov word [di], '/'              ; '/',0
    pop di
.ts_isfile:
    push si
    push es
    push ds
    pop es
    mov si, gs_tmp
    call gs_tc_cand
    pop es
    pop si
.ts_next:
    add si, 32
    loop .ts_ent
.ts_fdone:
    call path_restore
.ts_done:
    pop es
    popa
    ret

; кандидат DS:SI (ASCIIZ, верхний регистр). Сравнивается с префиксом слова:
; команды — с gs_word целиком, файлы — с частью после последнего '/'.
gs_tc_cand:
    pusha
    mov di, gs_word
    cmp word [gs_wstart], 0
    jne .cc_file
    cmp byte [get_hist], 0
    je .cc_file
    jmp .cc_cmp
.cc_file:
    mov di, [gs_namep]
.cc_cmp:
    push si
.cc_loop:
    mov al, [di]
    test al, al
    jz .cc_match
    mov ah, [si]
    xchg al, ah
    call to_upper                   ; команды в help_tab строчные
    cmp al, ah
    jne .cc_no
    inc si
    inc di
    jmp .cc_loop
.cc_no:
    pop si
    jmp .cc_ret
.cc_match:
    pop si
    cmp byte [gs_mode], 0
    jne .cc_print
    inc word [gs_cnt]
    cmp word [gs_cnt], 1
    jne .cc_common
    ; первый: скопировать целиком
    mov di, gs_cand
    xor cx, cx
.cc_cp:
    lodsb
    stosb
    inc cx
    test al, al
    jnz .cc_cp
    dec cx
    mov [gs_clen], cx
    jmp .cc_ret
.cc_common:
    ; укоротить общий префикс
    mov di, gs_cand
    xor cx, cx
.cc_cm:
    cmp cx, [gs_clen]
    jae .cc_ret
    mov al, [si]
    test al, al
    jz .cc_cut
    cmp al, [di]
    jne .cc_cut
    inc si
    inc di
    inc cx
    jmp .cc_cm
.cc_cut:
    mov [gs_clen], cx
    jmp .cc_ret
.cc_print:
    call print_string
    mov al, ' '
    call print_char
    call print_char
.cc_ret:
    popa
    ret

; вставить AL в [gs_start]+[gs_cur], сдвинув хвост вправо; CX++
gs_insert:
    push ax
    push si
    push di
    push cx
    mov si, [gs_start]
    add si, cx
    mov di, si
    dec si                          ; последний символ
    sub cx, [gs_cur]                ; сколько сдвигать
    std
    rep movsb
    cld
    mov di, [gs_start]
    add di, [gs_cur]
    mov [di], al
    pop cx
    inc cx
    inc word [gs_cur]
    call gs_redraw
    pop di
    pop si
    pop ax
    ret

; удалить символ в позиции [gs_cur]; CX--
gs_delete:
    push si
    push di
    push cx
    mov di, [gs_start]
    add di, [gs_cur]
    mov si, di
    inc si
    sub cx, [gs_cur]
    dec cx
    rep movsb
    pop cx
    dec cx
    call gs_redraw
    pop di
    pop si
    ret

; перерисовать строку с позиции gs_base, стереть лишнее, курсор на gs_cur
gs_redraw:
    push ax
    push bx
    push cx
    push si
    mov ax, [gs_base]
    call gs_set_cursor
    mov si, [gs_start]
    push cx
.rd_print:
    jcxz .rd_printed
    lodsb
    call print_char
    dec cx
    jmp .rd_print
.rd_printed:
    pop cx
    mov bx, 1                       ; пробелов для стирания хвоста
    mov ax, [gs_old]
    cmp ax, cx
    jbe .rd_pad
    sub ax, cx
    add bx, ax
.rd_pad:
    push bx
.rd_sp:
    mov al, ' '
    call print_char
    dec bx
    jnz .rd_sp
    pop bx
    mov [gs_old], cx
    ; если экран прокрутился — сдвинуть базу
    mov ax, [gs_base]
    add ax, cx
    add ax, bx                      ; ожидаемая позиция курсора
    push ax
    call gs_cursor_lin
    pop bx
    cmp ax, bx
    jae .rd_place
    sub bx, ax
    sub [gs_base], bx
.rd_place:
    call gs_place_cursor
    pop si
    pop cx
    pop bx
    pop ax
    ret

gs_place_cursor:
    push ax
    mov ax, [gs_base]
    add ax, [gs_cur]
    call gs_set_cursor
    pop ax
    ret

; AX = линейная позиция курсора (строка*80+столбец) из BDA
gs_cursor_lin:
    push dx
    push ds
    xor ax, ax
    mov ds, ax
    mov dx, [0x0450]
    pop ds
    mov al, dh
    mov ah, 80
    mul ah
    xor dh, dh
    add ax, dx
    pop dx
    ret

; поставить курсор в линейную позицию AX
gs_set_cursor:
    push ax
    push bx
    push dx
    mov bl, 80
    div bl                          ; AL = строка, AH = столбец
    mov dh, al
    mov dl, ah
    mov ah, 0x02
    xor bh, bh
    int 0x10
    pop dx
    pop bx
    pop ax
    ret

; показать запись истории [hist_pos] вместо набранного
gs_show_hist:
    push ax
    push si
    push di
    mov di, [gs_start]
    xor cx, cx
    mov al, [hist_pos]
    cmp al, [hist_count]
    jae .sh_draw                    ; позиция "новая строка" — пусто
    call hist_slot_ptr
.sh_copy:
    lodsb
    test al, al
    jz .sh_draw
    cmp cx, [get_max]
    jae .sh_draw
    stosb
    inc cx
    jmp .sh_copy
.sh_draw:
    mov [gs_cur], cx
    call gs_redraw
    pop di
    pop si
    pop ax
    ret

; AL = логический индекс (0 = самая старая) -> SI = адрес слота
hist_slot_ptr:
    push ax
    push cx
    mov ah, [hist_head]
    sub ah, [hist_count]
    add ah, al
    and ah, 7
    mov al, ah
    xor ah, ah
    mov cl, 7
    shl ax, cl
    add ax, hist_buf
    mov si, ax
    pop cx
    pop ax
    ret

; сохранить строку [gs_start] (длина CX) в историю, если не пустая и не дубль
gs_store_hist:
    pusha
    cmp byte [get_hist], 0
    je .st_ret
    jcxz .st_ret
    cmp byte [hist_count], 0
    je .st_store
    mov al, [hist_count]
    dec al
    call hist_slot_ptr
    mov di, [gs_start]
.st_cmp:
    mov al, [si]
    cmp al, [di]
    jne .st_store
    test al, al
    jz .st_ret                      ; совпадает с последней — не дублируем
    inc si
    inc di
    jmp .st_cmp
.st_store:
    xor ah, ah
    mov al, [hist_head]
    mov cl, 7
    shl ax, cl
    add ax, hist_buf
    mov di, ax
    mov si, [gs_start]
    mov cx, 127
.st_cp:
    lodsb
    stosb
    test al, al
    jz .st_stored
    loop .st_cp
    mov byte [di], 0
.st_stored:
    inc byte [hist_head]
    and byte [hist_head], 7
    cmp byte [hist_count], 8
    jae .st_ret
    inc byte [hist_count]
.st_ret:
    popa
    ret

str_match:
    pusha
.sm_loop:
    mov al, [di]
    test al, al
    jz .sm_end
    cmp al, [si]
    jne .sm_no
    inc si
    inc di
    jmp .sm_loop
.sm_end:
    mov al, [si]
    test al, al
    jz .sm_yes
    cmp al, ' '
    jne .sm_no
.sm_yes:
    popa
    stc
    ret
.sm_no:
    popa
    clc
    ret

; parse_filename: DS:SI -> имя 8.3 в cat_name (верхний регистр, пробелы).
; Останавливается на 0 / пробеле / '/' / '\'. CF=1 если имени нет.
parse_filename:
    push ax
    push cx
    push di
.pf_skip:
    cmp byte [si], ' '
    jne .pf_check
    inc si
    jmp .pf_skip
.pf_check:
    mov al, [si]
    call is_sep
    je .pf_err
    mov di, cat_name
    mov cx, 11
    mov al, ' '
.pf_pad:
    mov [di], al
    inc di
    loop .pf_pad
    mov di, cat_name
    mov cx, 8
.pf_name:
    mov al, [si]
    call is_sep
    je .pf_done
    cmp al, '.'
    je .pf_dot
    call to_upper
    mov [di], al
    inc di
    inc si
    dec cx
    jnz .pf_name
.pf_skip_name:
    mov al, [si]
    cmp al, '.'
    je .pf_dot
    call is_sep
    je .pf_done
    inc si
    jmp .pf_skip_name
.pf_dot:
    inc si
    mov di, cat_name + 8
    mov cx, 3
.pf_ext:
    mov al, [si]
    call is_sep
    je .pf_done
    call to_upper
    mov [di], al
    inc di
    inc si
    dec cx
    jnz .pf_ext
.pf_skip_ext:
    mov al, [si]
    call is_sep
    je .pf_done
    inc si
    jmp .pf_skip_ext
.pf_done:
    clc
    jmp .pf_ret
.pf_err:
    stc
.pf_ret:
    pop di
    pop cx
    pop ax
    ret

skip_spaces:
    cmp byte [si], ' '
    jne .ss_ret
    inc si
    jmp skip_spaces
.ss_ret:
    ret

; ZF=1 если AL — разделитель пути/аргумента (0, пробел, '/', '\')
is_sep:
    cmp al, 0
    je .is_y
    cmp al, ' '
    je .is_y
    cmp al, '/'
    je .is_y
    cmp al, 0x5C
.is_y:
    ret

to_upper:
    cmp al, 'a'
    jb .tu_ret
    cmp al, 'z'
    ja .tu_ret
    sub al, 0x20
.tu_ret:
    ret

print_hex_digit:
    add al, '0'
    cmp al, '9'
    jbe .hd_ok
    add al, 7
.hd_ok:
    call print_char
    ret

print_hex_byte:
    push ax
    push bx
    mov bl, al
    shr al, 4
    call print_hex_digit
    mov al, bl
    and al, 0x0F
    call print_hex_digit
    pop bx
    pop ax
    ret

print_hex_word:
    push ax
    mov al, ah
    call print_hex_byte
    pop ax
    call print_hex_byte
    ret

print_bcd:
    push ax
    push bx
    mov bl, al
    shr al, 4
    add al, '0'
    call print_char
    mov al, bl
    and al, 0x0F
    add al, '0'
    call print_char
    pop bx
    pop ax
    ret

print_dec_ax:
    push ax
    push bx
    push cx
    push dx
    mov cx, 0
    mov bx, 10
.pd_dv:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .pd_dv
.pd_pr:
    pop dx
    mov al, dl
    add al, '0'
    call print_char
    loop .pd_pr
    pop dx
    pop cx
    pop bx
    pop ax
    ret

print_dec_32:
    pusha
    mov bx, 10
    xor cx, cx
    mov si, dx
    or si, ax
    jnz .pd32_loop
    mov al, '0'
    call print_char
    jmp .pd32_done
.pd32_loop:
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    mov si, ax
    pop ax
    div bx
    push dx
    inc cx
    mov dx, si
    test dx, dx
    jnz .pd32_loop
    test ax, ax
    jnz .pd32_loop
.pd32_print:
    pop dx
    mov al, dl
    add al, '0'
    call print_char
    loop .pd32_print
.pd32_done:
    popa
    ret

parse_uint:
    push bx
    push cx
    push dx
    xor ax, ax
.pu_loop:
    mov cl, [si]
    cmp cl, '0'
    jb .pu_done
    cmp cl, '9'
    ja .pu_done
    mov bx, 10
    mul bx
    sub cl, '0'
    xor ch, ch
    add ax, cx
    inc si
    jmp .pu_loop
.pu_done:
    pop dx
    pop cx
    pop bx
    ret

wait_key:
    sti
    mov ah, 0x10                    ; расширенное чтение: серые стрелки (E0) на реальном BIOS
    int 0x16
    ret

wait_second:
    push ax
    push bx
    push cx
    push es
    mov ax, 0x0040
    mov es, ax
    mov cx, 18
.ws_outer:
    mov bx, [es:0x6C]
.ws_inner:
    mov ax, [es:0x6C]
    cmp ax, bx
    je .ws_inner
    loop .ws_outer
    pop es
    pop cx
    pop bx
    pop ax
    ret

;=================== ФУНКЦИИ КОМАНД ===================
show_date:
    pusha
    mov si, date_msg
    call print_string
    call get_local_time
    mov ax, [lt_y]
    call print_dec_ax
    mov al, '-'
    call print_char
    mov al, [lt_mo]
    call print_dec2
    mov al, '-'
    call print_char
    mov al, [lt_d]
    call print_dec2
    mov si, newline
    call print_string
    popa
    ret

show_time:
    pusha
    mov si, time_msg
    call print_string
    call get_local_time
    mov al, [lt_h]
    call print_dec2
    mov al, ':'
    call print_char
    mov al, [lt_mi]
    call print_dec2
    mov al, ':'
    call print_char
    mov al, [lt_s]
    call print_dec2
    call tz_print_short
    mov si, newline
    call print_string
    popa
    ret

show_memory:
    pusha
    mov si, mem_conv
    call print_string
    int 0x12
    call print_dec_ax
    mov si, mem_kb
    call print_string
    mov ah, 0x88
    int 0x15
    jc .sm_noext
    call print_dec_ax
    mov si, mem_ext
    call print_string
    jmp .sm_done
.sm_noext:
    mov si, mem_noext
    call print_string
.sm_done:
    mov si, newline
    call print_string
    popa
    ret

echo_command:
    pusha
    mov si, input_buffer
    add si, 4
.ec_skip:
    cmp byte [si], ' '
    jne .ec_pr
    inc si
    jmp .ec_skip
.ec_pr:
    cmp byte [si], 0
    je .ec_nl
    call print_string
.ec_nl:
    mov si, newline
    call print_string
    popa
    ret

matrix_effect:
    pusha
    push es
    mov ax, 0xB800
    mov es, ax
    call clear_screen
    mov word [mx_t1], 0
    mov word [mx_t2], 0
    mov word [mx_t3], 0
    xor bx, bx
.me_init:                           ; начальные высоты = 0
    mov byte [mx_h + bx], 0
    inc bx
    cmp bx, 80
    jb .me_init
.me_frame:
    ; фазы волн: медленная, быстрая и «дыхание» амплитуды
    add word [mx_t1], 3
    sub word [mx_t2], 5
    inc word [mx_t3]
    ; случайный сдвиг фазы (мерцание волны)
    call mx_rand
    test al, 0x1F
    jnz .me_nojit
    add [mx_t1], ah
.me_nojit:
    xor cx, cx                      ; столбец
.me_col:
    ; цель = 12 + sin(2*col + t1) + sin(5*col + t2)*amp
    mov bx, cx
    shl bx, 1
    add bx, [mx_t1]
    and bx, 63
    mov al, [mx_sine + bx]
    cbw
    mov dx, ax
    mov bx, cx
    mov ax, cx
    shl ax, 2
    add bx, ax                      ; 5*col
    add bx, [mx_t2]
    and bx, 63
    mov al, [mx_sine + bx]
    cbw
    ; амплитуда второй волны «дышит»: 1/2 или 1/4
    sar ax, 1
    test byte [mx_t3], 0x40
    jz .me_a1
    sar ax, 1
.me_a1:
    add dx, ax
    add dx, 12
    ; случайный джиттер -1..+1
    call mx_rand
    and ax, 3
    dec ax
    cmp ax, 2
    je .me_nj
    add dx, ax
.me_nj:
    cmp dx, 1
    jge .me_lo
    mov dx, 1
.me_lo:
    cmp dx, 24
    jle .me_hi
    mov dx, 24
.me_hi:
    ; плавное движение к цели (не более 2 строк за кадр)
    mov bx, cx
    mov al, [mx_h + bx]
    cbw
    cmp ax, dx
    je .me_set
    jl .me_up
    dec ax
    cmp ax, dx
    je .me_set
    dec ax
    jmp .me_set
.me_up:
    inc ax
    cmp ax, dx
    je .me_set
    inc ax
.me_set:
    mov [mx_h + bx], al
    ; отрисовать столбец: снизу вверх AL строк цифр, выше — пусто
    mov dh, al                      ; высота
    mov di, cx
    shl di, 1
    add di, 24 * 160                ; нижняя строка
    mov dl, 0                       ; счётчик строк от низа
.me_row:
    cmp dl, dh
    jae .me_blank
    ; цифра: с вероятностью 1/4 обновить
    call mx_rand
    cmp byte [es:di], ' '           ; пустая клетка — заполнить сразу
    je .me_put
    test ah, 3
    jnz .me_keep
.me_put:
    and al, 1
    add al, '0'
    mov [es:di], al
.me_keep:
    ; цвет: верхняя клетка — ярко-белая, 2 следующие — ярко-зелёные, остальное зелёное,
    ; самый низ (3 строки) — тёмно-зелёный
    mov al, 0x02
    mov ah, dh
    sub ah, dl                      ; расстояние до вершины (1 = вершина)
    cmp ah, 1
    jne .me_c2
    mov al, 0x0F
    jmp .me_cset
.me_c2:
    cmp ah, 3
    ja .me_c3
    mov al, 0x0A
    jmp .me_cset
.me_c3:
    cmp dl, 3
    jae .me_cset
    mov al, 0x08
.me_cset:
    mov [es:di + 1], al
    jmp .me_next
.me_blank:
    mov word [es:di], 0x0720
.me_next:
    sub di, 160
    inc dl
    cmp dl, 25
    jb .me_row
    inc cx
    cmp cx, 80
    jb .me_col
    ; задержка ~ 1 тик (55 мс) — ждём смены счётчика BIOS
    push es
    push cx
    xor ax, ax
    mov es, ax
    mov cx, [es:0x046C]
.me_dly:
    sti
    hlt
    cmp cx, [es:0x046C]
    je .me_dly
    pop cx
    pop es
    mov ah, 0x11
    int 0x16
    jnz .me_out
    jmp .me_frame
.me_out:
    mov ah, 0x10                    ; расширенное чтение: серые стрелки (E0) на реальном BIOS
    int 0x16
    pop es
    popa
    call clear_screen
    ret

; LCG -> AX
mx_rand:
    push bx
    push dx
    mov ax, [rand_seed]
    mov bx, 25173
    mul bx
    add ax, 13849
    mov [rand_seed], ax
    pop dx
    pop bx
    ret

mx_sine: db 0,1,3,4,5,7,8,9,10,11,12,12,13,13,14,14,14,14,14,13,13,12,12,11,10,9,8,7,5,4,3,1,0,-1,-3,-4,-5,-7,-8,-9,-10,-11,-12,-12,-13,-13,-14,-14,-14,-14,-14,-13,-13,-12,-12,-11,-10,-9,-8,-7,-5,-4,-3,-1
mx_h:    times 80 db 0
mx_t1:   dw 0
mx_t2:   dw 0
mx_t3:   dw 0

ascii_table:
    pusha
    call clear_screen
    mov si, ascii_header
    call print_string
    mov bx, 32
.at_row:
    mov di, 4
.at_col:
    mov al, bl
    call print_hex_byte
    mov al, ' '
    call print_char
    mov al, bl
    call print_char
    mov al, ' '
    call print_char
    inc bx
    dec di
    jnz .at_col
    mov si, newline
    call print_string
    cmp bx, 128
    jb .at_row
    call wait_key
    call clear_screen
    popa
    ret


; знаковое десятичное число (с необязательным '-') -> AX
parse_sint:
    push bx
    cmp byte [si], '-'
    jne .psi_pos
    inc si
    call parse_uint
    neg ax
    jmp .psi_ret
.psi_pos:
    call parse_uint
.psi_ret:
    pop bx
    ret

hex_converter:
    pusha
    mov si, hex_msg
    call print_string
    mov word [get_max], 14
    mov di, hex_buffer
    call get_string
    mov si, hex_buffer
    call parse_uint
    push ax
    mov si, hex_result
    call print_string
    pop ax
    call print_hex_word
    mov si, newline
    call print_string
    popa
    ret

bin_converter:
    pusha
    mov si, bin_msg
    call print_string
    mov word [get_max], 14
    mov di, bin_buffer
    call get_string
    mov si, bin_buffer
    call parse_uint
    push ax
    mov si, bin_result
    call print_string
    pop ax
    mov bx, ax
    mov cx, 16
.bc_bit:
    shl bx, 1
    mov al, '0'
    jnc .bc_zero
    mov al, '1'
.bc_zero:
    call print_char
    loop .bc_bit
    mov si, newline
    call print_string
    popa
    ret

;=================== имя пользователя ===================
; Хранится в файле USER.CFG в корне диска (имя + CR LF). Промпт — NAME@ferrix.
USER_MAX equ 16

; Загрузить имя из USER.CFG. CF=1 если файла нет / пустой
user_load:
    pusha
    push es
    call path_save
    call sys_dir_enter
    call user_set_catname
    mov word [rf_limit], 64
    mov word [rf_limit + 2], 0
    call read_file                  ; -> CP_SEG:0, [save_len]
    jc .ul_none
    mov ax, CP_SEG
    mov es, ax
    xor si, si
    mov di, user_name
    xor cx, cx
.ul_cp:
    cmp cx, [save_len]
    jae .ul_end
    mov al, [es:si]
    inc si
    cmp al, ' '
    jbe .ul_end                     ; CR/LF/пробел — конец имени
    mov [di], al
    inc di
    inc cx
    cmp cx, USER_MAX
    jb .ul_cp
.ul_end:
    mov byte [di], 0
    test cx, cx
    jz .ul_none
    call cfg_parse_tz               ; ES:SI — остаток файла
    call user_build_prompt
    call path_restore
    pop es
    popa
    clc
    ret
.ul_none:
    call path_restore
    pop es
    popa
    stc
    ret

; Перейти в /SYSTEM (cur_dir/cur_path). Если каталога нет — остаёмся в корне, CF=1.
; Вызывающий должен сам сделать path_save/path_restore.
sys_dir_enter:
    push si
    push di
    push cx
    mov word [cur_dir], 0
    mov byte [cur_path + 1], 0
    mov si, system_dirname
    mov di, cat_name
    mov cx, 11
    rep movsb
    call cd_enter
    jnc .sde_ok
    mov word [cur_dir], 0
    mov byte [cur_path + 1], 0
    stc
.sde_ok:
    pop cx
    pop di
    pop si
    ret

; Создать /SYSTEM и /SYSTEM/SYSAPPS, если их нет (используется мастером настройки)
sys_dir_ensure:
    pusha
    push es
    push ds
    pop es
    call path_save
    call sys_dir_enter
    jnc .sdn_apps
    call path_restore
    mov si, mk_system_cmd
    call ib_set
    call mkdir_command
    call path_save
.sdn_apps:
    call sys_dir_enter
    jc .sdn_done
    mov si, sysapps_dirname
    mov di, cat_name
    mov cx, 11
    rep movsb
    call cd_enter
    jnc .sdn_done
    call path_restore
    mov si, mk_sysapps_cmd
    call ib_set
    call mkdir_command
    call path_save
.sdn_done:
    call path_restore
    pop es
    popa
    ret

; input_buffer = строка DS:SI
ib_set:
    push si
    push di
    push ax
    mov di, input_buffer
.ibs_cp:
    lodsb
    mov [di], al
    inc di
    test al, al
    jnz .ibs_cp
    pop ax
    pop di
    pop si
    ret

user_set_catname:
    push si
    push di
    push cx
    mov si, user_cfg_name
    mov di, cat_name
    mov cx, 11
    rep movsb
    pop cx
    pop di
    pop si
    ret

; Принять имя из строки DS:SI (до пробела/конца, 1..16 символов) и сохранить.
; CF=1 если имя пустое или слишком длинное
user_apply:
    pusha
    push es
    push ds
    pop es
    mov di, user_tmp
    xor cx, cx
.uap_cp:
    lodsb
    cmp al, ' '
    jbe .uap_end
    cmp cx, USER_MAX
    jae .uap_bad
    mov [di], al
    inc di
    inc cx
    jmp .uap_cp
.uap_end:
    test cx, cx
    jz .uap_bad
    mov byte [di], 0
    mov si, user_tmp
    mov di, user_name
    inc cx
    rep movsb                       ; имя вместе с нулём
    call user_build_prompt
    call cfg_save
    jc .uap_bad
    pop es
    popa
    clc
    ret
.uap_bad:
    pop es
    popa
    stc
    ret

; Приветствие по времени суток: "Good morning, NAME! Welcome back to Ferrix OS."
user_greet:
    pusha
    call get_local_time
    mov al, [lt_h]                  ; AL = час 0..23
    mov si, greet_night
    cmp al, 5
    jb .ug_say
    mov si, greet_morning
    cmp al, 12
    jb .ug_say
.ug_day:
    mov si, greet_day
    cmp al, 18
    jb .ug_say
    mov si, greet_evening
    cmp al, 23
    jb .ug_say
    mov si, greet_night
.ug_say:
    call print_string
    mov si, user_name
    call print_string
    mov si, greet_tail
    call print_string
    popa
    ret

; prm_user = user_name + "@ferrix"
user_build_prompt:
    push si
    push di
    push ax
    push es
    push ds
    pop es                          ; stosb -> наш сегмент данных
    mov si, user_name
    mov di, prm_user
.ubp_cp:
    lodsb
    test al, al
    jz .ubp_host
    stosb
    jmp .ubp_cp
.ubp_host:
    mov si, user_host
.ubp_h:
    lodsb
    stosb
    test al, al
    jnz .ubp_h
    pop es
    pop ax
    pop di
    pop si
    ret

; user          — показать имя
; user NAME     — сменить (сохраняется на диск)
; Записать USER.CFG: "NAME\r\nTZ=+07\r\nRTC=UTC|LOCAL\r\n". CF=1 при ошибке диска
cfg_save:
    pusha
    push es
    push ds
    pop es
    mov di, cfg_buf
    mov si, user_name
.cs_name:
    lodsb
    test al, al
    jz .cs_name_end
    stosb
    jmp .cs_name
.cs_name_end:
    mov ax, 0x0A0D
    stosw
    mov si, cfg_tz_key
    call cfg_put_str
    mov al, '+'
    mov bl, [tz_off]
    test bl, bl
    jns .cs_sign
    mov al, '-'
    neg bl
.cs_sign:
    stosb
    mov al, bl
    aam                             ; AH = десятки, AL = единицы
    xchg al, ah
    add ax, 0x3030
    stosw
    mov ax, 0x0A0D
    stosw
    mov si, cfg_rtc_key
    call cfg_put_str
    mov si, cfg_utc_str
    cmp byte [rtc_utc], 0
    jne .cs_rtc
    mov si, cfg_local_str
.cs_rtc:
    call cfg_put_str
    mov ax, 0x0A0D
    stosw
    mov si, cfg_saver_key
    call cfg_put_str
    mov al, [saver_mode]
    mov si, saver_s_off
    test al, al
    jz .cs_sv
    mov si, saver_s_clock
    cmp al, 1
    je .cs_sv
    mov si, saver_s_matrix
.cs_sv:
    call cfg_put_str
    mov al, ':'
    stosb
    mov al, [saver_min]
    aam
    xchg al, ah
    add ax, 0x3030
    stosw
    mov ax, 0x0A0D
    stosw
    mov cx, di
    sub cx, cfg_buf
    call sys_dir_ensure
    call path_save
    call sys_dir_enter
    call user_set_catname
    mov [save_len], cx
    mov word [save_off], cfg_buf
    mov [save_seg], ds
    call save_file
    pushf
    call path_restore
    popf
    pop es
    popa
    ret

cfg_put_str:
    lodsb
    test al, al
    jz .cps_done
    stosb
    jmp cfg_put_str
.cps_done:
    ret

; Разобрать хвост USER.CFG (ES:SI, до [save_len] байт от ES:0): TZ=+07, RTC=UTC
cfg_parse_tz:
    push ax
    push bx
    push cx
    push si
    mov byte [tz_off], 0
    mov byte [rtc_utc], 0
    mov byte [saver_mode], 1
    mov byte [saver_min], 3
.cpt_loop:
    cmp si, [save_len]
    jae .cpt_done
    mov al, [es:si]
    inc si
    cmp al, 'T'
    je .cpt_tz
    cmp al, 'R'
    je .cpt_rtc
    cmp al, 'S'
    je .cpt_saver
    jmp .cpt_loop
.cpt_saver:                         ; "AVER=" C|M|O ... ':' MM
    cmp byte [es:si], 'A'
    jne .cpt_loop
    cmp byte [es:si + 4], '='
    jne .cpt_loop
    add si, 5
    mov al, [es:si]
    mov byte [saver_mode], 0
    cmp al, 'O'
    je .cpt_sv_min
    mov byte [saver_mode], 1
    cmp al, 'C'
    je .cpt_sv_min
    mov byte [saver_mode], 2
.cpt_sv_min:
    inc si
    cmp si, [save_len]
    jae .cpt_done
    mov al, [es:si]
    cmp al, 13
    je .cpt_loop
    cmp al, ':'
    jne .cpt_sv_min
    inc si
    mov al, [es:si]
    sub al, '0'
    mov ah, 10
    mul ah
    mov cl, [es:si + 1]
    sub cl, '0'
    add al, cl
    test al, al
    jz .cpt_loop
    mov [saver_min], al
    add si, 2
    jmp .cpt_loop
.cpt_tz:                            ; ожидаем "Z=" знак цифра цифра
    cmp byte [es:si], 'Z'
    jne .cpt_loop
    cmp byte [es:si + 1], '='
    jne .cpt_loop
    add si, 2
    mov bl, [es:si]                 ; знак
    inc si
    mov al, [es:si]
    sub al, '0'
    mov ah, 10
    mul ah
    mov cl, [es:si + 1]
    sub cl, '0'
    add al, cl
    add si, 2
    cmp bl, '-'
    jne .cpt_tz_set
    neg al
.cpt_tz_set:
    mov [tz_off], al
    jmp .cpt_loop
.cpt_rtc:                           ; "TC=U" -> UTC
    cmp byte [es:si], 'T'
    jne .cpt_loop
    cmp byte [es:si + 1], 'C'
    jne .cpt_loop
    cmp byte [es:si + 2], '='
    jne .cpt_loop
    add si, 3
    cmp byte [es:si], 'U'
    jne .cpt_loop
    mov byte [rtc_utc], 1
    jmp .cpt_loop
.cpt_done:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; Разобрать смещение из DS:SI ("+7", "-5", "0", "+07") -> AL (знаковое), CF=1 если мусор
tz_parse:
    push bx
    push cx
    xor bl, bl                      ; знак
    xor cx, cx                      ; значение
    cmp byte [si], '+'
    je .tp_sign
    cmp byte [si], '-'
    jne .tp_digits
    inc bl
.tp_sign:
    inc si
.tp_digits:
    mov al, [si]
    cmp al, '0'
    jb .tp_end
    cmp al, '9'
    ja .tp_end
    sub al, '0'
    xchg ax, cx
    mov ch, 10
    mul ch
    xchg ax, cx
    add cl, al
    inc si
    cmp cl, 15
    ja .tp_bad
    jmp .tp_digits
.tp_end:
    cmp byte [si - 1], '9'
    ja .tp_bad
    cmp byte [si - 1], '0'
    jb .tp_bad                      ; ни одной цифры
    mov al, cl
    test bl, bl
    jz .tp_ok
    neg al
    cmp al, -12
    jl .tp_bad
.tp_ok:
    cmp al, 14
    jg .tp_bad
    pop cx
    pop bx
    clc
    ret
.tp_bad:
    pop cx
    pop bx
    stc
    ret

; напечатать " (UTC+7)"
tz_print_short:
    push ax
    push si
    mov si, tz_utc_pfx
    call print_string
    call tz_print_off
    mov al, ')'
    call print_char
    pop si
    pop ax
    ret

; напечатать "+7" / "-5" / "+0"
tz_print_off:
    push ax
    mov al, [tz_off]
    test al, al
    jns .tpo_plus
    neg al
    push ax
    mov al, '-'
    call print_char
    pop ax
    jmp .tpo_num
.tpo_plus:
    push ax
    mov al, '+'
    call print_char
    pop ax
.tpo_num:
    xor ah, ah
    call print_dec_ax
    pop ax
    ret

; tz            — показать
; tz +7 [utc]   — задать смещение; 'utc' = аппаратные часы идут по UTC
tz_command:
    pusha
    mov si, input_buffer
    add si, 2
.tz_sp:
    lodsb
    cmp al, ' '
    je .tz_sp
    test al, al
    jz .tz_show
    dec si
    call tz_parse
    jc .tz_bad
    mov [tz_off], al
    mov byte [rtc_utc], 0
.tz_sp2:
    lodsb
    cmp al, ' '
    je .tz_sp2
    cmp al, 'u'
    je .tz_utc
    cmp al, 'U'
    jne .tz_save
.tz_utc:
    mov byte [rtc_utc], 1
.tz_save:
    call cfg_save
    jc .tz_bad
    mov si, tz_set_msg
    call print_string
.tz_show:
    mov si, tz_show_msg
    call print_string
    call tz_print_off
    mov si, tz_rtc_local
    cmp byte [rtc_utc], 0
    je .tz_rtc
    mov si, tz_rtc_utc
.tz_rtc:
    call print_string
    mov si, time_msg
    call print_string
    call get_local_time
    mov al, [lt_h]
    call print_dec2
    mov al, ':'
    call print_char
    mov al, [lt_mi]
    call print_dec2
    mov si, newline
    call print_string
    popa
    ret
.tz_bad:
    mov si, tz_bad_msg
    call print_string
    popa
    ret

;=================== Мастер первоначальной настройки ===================
setup_wizard:
    pusha
    mov si, su_title
    call print_string
    ; --- шаг 1: имя ---
.su_name:
    mov si, su_step1
    call print_string
    mov si, user_prompt_msg
    call print_string
    mov word [get_max], USER_MAX
    mov byte [get_hist], 0
    mov di, input_buffer
    call get_string
    mov si, input_buffer
    call user_apply
    jc .su_name
    ; --- шаг 2: часовой пояс ---
.su_tz:
    mov si, su_step2
    call print_string
    mov si, su_tz_prompt
    call print_string
    mov word [get_max], 4
    mov di, input_buffer
    call get_string
    mov si, input_buffer
    cmp byte [si], 0
    jne .su_tz_parse
    mov byte [tz_off], 0            ; Enter = UTC+0
    jmp .su_rtc
.su_tz_parse:
    call tz_parse
    jc .su_tz
    mov [tz_off], al
    ; --- шаг 3: что хранят аппаратные часы ---
.su_rtc:
    mov si, su_step3
    call print_string
    mov si, su_rtc_prompt
    call print_string
    mov word [get_max], 1
    mov di, input_buffer
    call get_string
    mov al, [input_buffer]
    mov byte [rtc_utc], 0
    cmp al, '2'
    jne .su_rtc_ok
    mov byte [rtc_utc], 1
.su_rtc_ok:
    ; --- шаг 4: заставка ---
.su_saver:
    mov si, su_step4
    call print_string
    mov si, su_saver_prompt
    call print_string
    mov word [get_max], 1
    mov di, input_buffer
    call get_string
    mov al, [input_buffer]
    mov byte [saver_mode], 1
    cmp al, '3'
    jne .su_sv2
    mov byte [saver_mode], 0
    jmp .su_save
.su_sv2:
    cmp al, '2'
    jne .su_sv_min
    mov byte [saver_mode], 2
.su_sv_min:
    mov si, su_saver_min
    call print_string
    mov word [get_max], 2
    mov di, input_buffer
    call get_string
    mov byte [saver_min], 3
    mov si, input_buffer
    cmp byte [si], 0
    je .su_save
    call parse_uint
    test ax, ax
    jz .su_saver
    cmp ax, 99
    ja .su_saver
    mov [saver_min], al
.su_save:
    call cfg_save
    jc .su_err
    ; --- итог ---
    mov si, su_done1
    call print_string
    mov si, user_name
    call print_string
    mov si, su_done2
    call print_string
    call tz_print_off
    mov si, su_done3
    call print_string
    call get_local_time
    mov al, [lt_h]
    call print_dec2
    mov al, ':'
    call print_char
    mov al, [lt_mi]
    call print_dec2
    mov si, su_done4
    call print_string
    popa
    ret
.su_err:
    mov si, user_bad
    call print_string
    popa
    ret

;=================== Локальное время ===================
; AL (0..99) -> упакованный BCD
bin2bcd:
    push cx
    aam
    mov cl, 4
    shl ah, cl
    or al, ah
    pop cx
    ret

; AL (0..99) -> две десятичные цифры
print_dec2:
    push ax
    aam
    xchg al, ah
    add al, '0'
    call print_char
    mov al, ah
    add al, '0'
    call print_char
    pop ax
    ret

; Читает RTC и заполняет lt_y/lt_mo/lt_d/lt_h/lt_mi/lt_s (двоично).
; Если [rtc_utc]=1 — прибавляет [tz_off] часов с переносом даты.
get_local_time:
    pusha
    mov ah, 0x02
    int 0x1A
    mov al, ch
    call bcd2bin
    mov [lt_h], al
    mov al, cl
    call bcd2bin
    mov [lt_mi], al
    mov al, dh
    call bcd2bin
    mov [lt_s], al
    mov ah, 0x04
    int 0x1A
    mov al, ch
    call bcd2bin
    mov ah, 100
    mul ah
    push ax
    mov al, cl
    call bcd2bin
    pop bx
    add ax, bx
    mov [lt_y], ax
    mov al, dh
    call bcd2bin
    mov [lt_mo], al
    mov al, dl
    call bcd2bin
    mov [lt_d], al
    cmp byte [rtc_utc], 0
    je .glt_done
    mov al, [lt_h]
    add al, [tz_off]
    cmp al, 24
    jge .glt_next_day
    test al, al
    jl .glt_prev_day
    mov [lt_h], al
    jmp .glt_done
.glt_next_day:
    sub al, 24
    mov [lt_h], al
    inc byte [lt_d]
    call lt_days_in_month
    cmp [lt_d], al
    jbe .glt_done
    mov byte [lt_d], 1
    inc byte [lt_mo]
    cmp byte [lt_mo], 12
    jbe .glt_done
    mov byte [lt_mo], 1
    inc word [lt_y]
    jmp .glt_done
.glt_prev_day:
    add al, 24
    mov [lt_h], al
    dec byte [lt_d]
    jnz .glt_done
    dec byte [lt_mo]
    jnz .glt_pm
    mov byte [lt_mo], 12
    dec word [lt_y]
.glt_pm:
    call lt_days_in_month
    mov [lt_d], al
.glt_done:
    popa
    ret

; AL = число дней в месяце [lt_mo] года [lt_y]
lt_days_in_month:
    push bx
    mov bl, [lt_mo]
    xor bh, bh
    mov al, [lt_dim + bx - 1]
    cmp bl, 2
    jne .dim_ret
    test word [lt_y], 3
    jnz .dim_ret
    inc al                          ; високосный (1901..2099 — достаточно)
.dim_ret:
    pop bx
    ret

bcd2bin:
    push cx
    mov ch, al
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    mov cl, 10
    mul cl
    and ch, 0x0F
    add al, ch
    pop cx
    ret

user_command:
    pusha
    mov si, input_buffer
    add si, 4
.uc_sp:
    lodsb
    cmp al, ' '
    je .uc_sp
    test al, al
    jz .uc_show
    dec si
    call user_apply
    jc .uc_bad
    mov si, user_changed
    call print_string
    mov si, user_name
    call print_string
    mov si, newline
    call print_string
    popa
    ret
.uc_bad:
    mov si, user_bad
    call print_string
    popa
    ret
.uc_show:
    mov si, user_show
    call print_string
    mov si, user_name
    call print_string
    mov si, newline
    call print_string
    popa
    ret

;=================== clock: часы на весь экран ===================
; Цифры 5x7 из знакогенератора, каждая точка — 2 символа в ширину и 2 строки
; в высоту (блоки 0xDB). Строка HH:MM:SS = 6*11 + 2*3 = 72 колонки.
CLK_TOP  equ 4
CLK_LEFT equ 4
CLK_ATTR equ 0x0B

digital_clock:
    pusha
    push es
    call clear_screen
    mov ah, 0x01                    ; спрятать курсор
    mov cx, 0x2000
    int 0x10
    ; подсказка внизу
    mov ah, 0x02
    xor bh, bh
    mov dh, 23
    mov dl, 28
    int 0x10
    mov si, clock_hint
    call print_string
.dk_loop:
    call get_local_time
    mov al, [lt_h]
    call bin2bcd
    mov [clk_h], al
    mov al, [lt_mi]
    call bin2bcd
    mov [clk_m], al
    mov al, [lt_s]
    call bin2bcd
    mov [clk_s], al
    mov ax, 0xB800
    mov es, ax
    mov byte [clk_x], CLK_LEFT
    mov al, [clk_h]
    call clk_big_pair
    call clk_big_colon
    mov al, [clk_m]
    call clk_big_pair
    call clk_big_colon
    mov al, [clk_s]
    call clk_big_pair
    ; дата
    mov ah, 0x02
    xor bh, bh
    mov dh, 20
    mov dl, 35
    int 0x10
    mov al, [lt_d]
    call print_dec2
    mov al, '.'
    call print_char
    mov al, [lt_mo]
    call print_dec2
    mov al, '.'
    call print_char
    mov ax, [lt_y]
    call print_dec_ax
    mov al, ' '
    call print_char
    call tz_print_short
.dk_wait:
    sti
    mov ah, 0x11
    int 0x16
    jnz .dk_out
    call wait_second
    jmp .dk_loop
.dk_out:
    mov ah, 0x10                    ; расширенное чтение: серые стрелки (E0) на реальном BIOS
    int 0x16
    mov ah, 0x01                    ; вернуть курсор
    mov cx, 0x0607
    int 0x10
    call clear_screen
    pop es
    popa
    ret

; AL = BCD-пара -> две большие цифры
clk_big_pair:
    push ax
    shr al, 4
    call clk_big_digit
    pop ax
    and al, 0x0F
    call clk_big_digit
    ret

; AL = цифра 0..9 в позиции [clk_x]; после — clk_x += 11
clk_big_digit:
    pusha
    xor ah, ah
    mov si, ax
    shl si, 3                       ; 8 байт на цифру (7 строк + заполнитель)
    add si, clk_font
    mov dh, CLK_TOP
    mov cx, 7
.bd_row:
    lodsb
    mov bl, al
    mov dl, [clk_x]
    push cx
    mov cx, 5
.bd_bit:
    mov ax, 0x0720                  ; пусто
    test bl, 0x10
    jz .bd_put
    mov ax, (CLK_ATTR << 8) | 0xDB  ; блок
.bd_put:
    call clk_cell2
    shl bl, 1
    add dl, 2
    loop .bd_bit
    pop cx
    add dh, 2
    loop .bd_row
    add byte [clk_x], 11
    popa
    ret

; двоеточие: две точки 2x2 в строках 4-5 и 8-9 относительно верха; clk_x += 3
clk_big_colon:
    pusha
    mov ax, (CLK_ATTR << 8) | 0xDB
    mov dl, [clk_x]
    mov dh, CLK_TOP + 4
    call clk_cell2
    mov dh, CLK_TOP + 8
    call clk_cell2
    add byte [clk_x], 3
    popa
    ret

; записать AX в ячейки (DH,DL),(DH,DL+1),(DH+1,DL),(DH+1,DL+1)
clk_cell2:
    push di
    push bx
    push ax
    push dx
    mov bl, dh
    mov al, 160
    mul bl
    mov di, ax
    xor bh, bh
    mov bl, dl
    shl bx, 1
    add di, bx
    pop dx
    pop ax
    mov [es:di], ax
    mov [es:di + 2], ax
    mov [es:di + 160], ax
    mov [es:di + 162], ax
    pop bx
    pop di
    ret

clk_font:
    db 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E, 0     ; 0
    db 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E, 0     ; 1
    db 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F, 0     ; 2
    db 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E, 0     ; 3
    db 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02, 0     ; 4
    db 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E, 0     ; 5
    db 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E, 0     ; 6
    db 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08, 0     ; 7
    db 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E, 0     ; 8
    db 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C, 0     ; 9

show_banner:
    call clear_screen
    mov si, boot_art
    call print_cstring
    mov si, fetch_info
    call print_cstring
    call wait_key
    ret

;=================== help ===================
; help            — группы и список команд
; help GROUP      — команды группы с описаниями
; help COMMAND    — описание и синтаксис одной команды
; Таблица help_tab: имя,0, номер группы, описание,0 ... ; конец — 0.
HG_FILES  equ 1
HG_SYSTEM equ 2
HG_MEDIA  equ 3
HG_TOOLS  equ 4
HG_INFO   equ 6
HG_GAMES  equ 5

help_command:
    pusha
    mov si, input_buffer
    add si, 4
.hc_sp:
    lodsb
    cmp al, ' '
    je .hc_sp
    dec si
    test al, al
    jz .hc_overview
    ; группа?
    mov di, help_groups
    mov bl, 1
.hc_grp:
    cmp byte [di], 0
    je .hc_cmd
    call str_match
    jc .hc_group
.hc_gskip:
    inc di
    cmp byte [di - 1], 0
    jne .hc_gskip
    inc bl
    jmp .hc_grp
.hc_group:
    ; заголовок группы
    push si
    mov byte [con_attr], 0x0B
    mov si, help_hdr
    call print_string
    mov si, di
    call print_string
    mov si, help_hdr2
    call print_string
    mov byte [con_attr], 0x07
    pop si
    mov cl, bl
    call help_list_group
    popa
    ret
.hc_cmd:
    mov di, help_tab
.hc_cl:
    cmp byte [di], 0
    je .hc_unknown
    call str_match
    jc .hc_found
    call help_next
    jmp .hc_cl
.hc_found:
    call help_print_entry
    popa
    ret
.hc_unknown:
    mov si, help_unknown
    call print_string
    popa
    ret
.hc_overview:
    mov si, help_title
    call print_string
    mov cl, 1
    mov di, help_groups
.hc_ov:
    cmp byte [di], 0
    je .hc_ov_done
    mov al, ' '
    call print_char
    mov si, di
    mov dx, 8                        ; имя группы в колонке шириной 8
.hc_gn:
    lodsb
    test al, al
    jz .hc_pad
    call print_char
    dec dx
    jmp .hc_gn
.hc_pad:
    mov al, ' '
    call print_char
    dec dx
    jnz .hc_pad
    mov al, ':'
    call print_char
    mov al, ' '
    call print_char
    call help_names_group            ; имена команд группы CL
    mov si, newline
    call print_string
.hc_gnext:
    inc di
    cmp byte [di - 1], 0
    jne .hc_gnext
    inc cl
    jmp .hc_ov
.hc_ov_done:
    mov si, help_foot
    call print_string
    popa
    ret

; DI -> запись таблицы; перейти к следующей
help_next:
.hn_name:
    inc di
    cmp byte [di - 1], 0
    jne .hn_name
    inc di                           ; группа
.hn_desc:
    inc di
    cmp byte [di - 1], 0
    jne .hn_desc
    ret

; DI -> запись: напечатать " синтаксис  описание"
help_print_entry:
    push si
    push di
    push cx
    mov al, ' '
    call print_char
    mov si, di
.hp_n:
    lodsb
    test al, al
    jnz .hp_n
    inc si                           ; группа
    mov cx, 21                       ; синтаксис (первые 21 символ) — ярко, описание — серым
    mov byte [con_attr], 0x0F
.hp_syn:
    lodsb
    test al, al
    jz .hp_eol
    call print_char
    loop .hp_syn
    mov byte [con_attr], 0x08
    call print_string
.hp_eol:
    mov byte [con_attr], 0x07
    mov si, newline
    call print_string
    pop cx
    pop di
    pop si
    ret

; все записи группы CL с описаниями
help_list_group:
    push di
    mov di, help_tab
.hl_loop:
    cmp byte [di], 0
    je .hl_done
    call help_entry_group
    cmp al, cl
    jne .hl_next
    call help_print_entry
.hl_next:
    call help_next
    jmp .hl_loop
.hl_done:
    pop di
    ret

; имена команд группы CL через пробел
help_names_group:
    push di
    push si
    mov di, help_tab
.hg_loop:
    cmp byte [di], 0
    je .hg_done
    call help_entry_group
    cmp al, cl
    jne .hg_next
    mov si, di
    call print_string
    mov al, ' '
    call print_char
.hg_next:
    call help_next
    jmp .hg_loop
.hg_done:
    pop si
    pop di
    ret

; AL = группа записи DI
help_entry_group:
    push di
.heg:
    inc di
    cmp byte [di - 1], 0
    jne .heg
    mov al, [di]
    pop di
    ret

help_groups:
    db "files", 0, "system", 0, "media", 0, "tools", 0, "games", 0, "info", 0, 0

help_tab:
    db "ls", 0,      HG_FILES,  "ls [-l] [PATH]       list directory in columns; -l: one per line + long names", 0
    db "dir", 0,     HG_FILES,  "dir [-l] [PATH]      same as ls", 0
    db "cd", 0,      HG_FILES,  "cd PATH              change directory (.. up, / or ~ root)", 0
    db "pwd", 0,     HG_FILES,  "pwd                  print current directory", 0
    db "cat", 0,     HG_FILES,  "cat PATH             print file contents", 0
    db "touch", 0,   HG_FILES,  "touch PATH           create empty file", 0
    db "write", 0,   HG_FILES,  "write PATH TEXT      write text to file (create/overwrite)", 0
    db "mono", 0,    HG_FILES,  "mono PATH            text editor (external MONO.FAP)", 0
    db "fm", 0,      HG_FILES,  "fm                   two-panel file manager (FM.FAP, F1..F10 keys)", 0
    db "run", 0,     HG_SYSTEM, "run FILE [ARGS]      run .FAP program or .SH script", 0
    db "sh", 0,      HG_SYSTEM, "sh FILE.SH           run shell script", 0
    db "rm", 0,      HG_FILES,  "rm PATH              delete file or empty directory", 0
    db "mkdir", 0,   HG_FILES,  "mkdir PATH           create directory", 0
    db "rename", 0,  HG_FILES,  "rename OLD NEW       rename file or directory", 0
    db "cp", 0,      HG_FILES,  "cp SRC DST           copy file (any size, streaming)", 0
    db "mv", 0,      HG_FILES,  "mv SRC DST           move/rename file or directory", 0
    db "fetch", 0,   HG_SYSTEM, "fetch                system info (neofetch style)", 0
    db "cpu", 0,     HG_SYSTEM, "cpu                  processor details (CPUID)", 0
    db "mem", 0,     HG_SYSTEM, "mem                  conventional/extended memory", 0
    db "date", 0,    HG_SYSTEM, "date                 show date", 0
    db "time", 0,    HG_SYSTEM, "time                 show time", 0
    db "clock", 0,   HG_SYSTEM, "clock                analog + digital clock, date (CLOCK.FAP)", 0
    db "user", 0,    HG_SYSTEM, "user [NAME]          show or change username (saved in USER.CFG)", 0
    db "whoami", 0,  HG_SYSTEM, "whoami               print username", 0
    db "tz", 0,      HG_SYSTEM, "tz [+H [utc]]        show/set timezone; 'utc' = RTC keeps UTC", 0
    db "setup", 0,   HG_SYSTEM, "setup                rerun first-time setup (name, timezone, saver)", 0
    db "saver", 0,   HG_SYSTEM, "saver [clock|matrix|off [MIN]]  screensaver after MIN idle minutes", 0
    db "reboot", 0,  HG_SYSTEM, "reboot               restart the computer", 0
    db "shutdown", 0,HG_SYSTEM, "shutdown             power off (APM)", 0
    db "view", 0,    HG_MEDIA,  "view FILE.BMP        show 8/24/32-bit BMP picture (320x200)", 0
    db "play", 0,    HG_MEDIA,  "play FILE.WAV [sb|hda]  play 8-bit PCM WAV (SB16 / HD Audio)", 0
    db "echo", 0,    HG_TOOLS,  "echo TEXT            print text", 0
    db "calc", 0,    HG_TOOLS,  "calc [-c] [EXPR]     calculator (CALC.FAP): window mode; -c = console", 0
    db "paint", 0,   HG_TOOLS,  "paint [FILE.BMP]     16-color paint, saves BMP (PAINT.FAP, mouse)", 0
    db "iron", 0,    HG_TOOLS,  "iron SRC.ASM OUT.FAP frasm assembler -> .FAP program (IRON.FAP)", 0
    db "ferramp", 0, HG_MEDIA,  "ferramp [DIR|FILE]   music player: WAV/SNG playlist (FERRAMP.FAP)", 0
    db "synth", 0,   HG_MEDIA,  "synth [FILE.SNG]     piano + sequencer on HD Audio (SYNTH.FAP)", 0
    db "gui", 0,     HG_SYSTEM, "gui [-t N | -w BMP]  window manager (GUI.FAP): fm + apps in windows", 0
    db "hex", 0,     HG_TOOLS,  "hex N                decimal -> hexadecimal", 0
    db "bin", 0,     HG_TOOLS,  "bin N                decimal -> binary", 0
    db "ascii", 0,   HG_TOOLS,  "ascii                ASCII table", 0
    db "matrix", 0,  HG_TOOLS,  "matrix               matrix rain screensaver (any key = exit)", 0
    db "help", 0,    HG_INFO,   "help [GROUP|CMD]     this help: groups, group list or one command", 0
    db "clear", 0,   HG_TOOLS,  "clear                clear screen and redraw banner", 0
    db "banner", 0,  HG_INFO,   "banner               show the Ferrix banner", 0
    db "osinfo", 0,  HG_INFO,   "osinfo               about the OS", 0
    db "credits", 0, HG_INFO,   "credits              authors", 0
    db "snake", 0,   HG_GAMES,  "snake                snake (arrows/WASD, P pause, Esc quit)", 0
    db "tetris", 0,  HG_GAMES,  "tetris               tetris (arrows, Up rotate, Space drop)", 0
    db "mines", 0,   HG_GAMES,  "mines                minesweeper (arrows, Space open, F flag)", 0
    db "2048", 0,    HG_GAMES,  "2048                 join tiles to 2048 (arrows/WASD, R restart)", 0
    db "pong", 0,    HG_GAMES,  "pong                 pong vs CPU, first to 10 (W/S or arrows)", 0
    db "micro", 0,   HG_GAMES,  "micro FILE.CH8       CHIP-8 emulator: micro /BALL.CH8", 0
    db 0

help_title      db "== FERRIX OS COMMANDS ==", 13,10, 0
help_foot       db " Type 'help GROUP' (e.g. help files) or 'help COMMAND' for details.", 13,10, 0
help_hdr        db "== ", 0
help_hdr2       db " ==", 13,10, 0
help_unknown    db "No such command or group. Groups: files system media tools games info", 13,10, 0

;=================== ДАННЫЕ ===================
boot_drive        db 0
vol_bad_msg       db "Unsupported volume (need FAT12/16, 512-byte sectors, 1 sector/cluster, <=32 MB); assuming 1.44M floppy", 13,10, 0
disk_spt          dw 18           ; секторов на дорожку
disk_heads        dw 2            ; головок
; --- параметры тома (из BPB загрузочного сектора; по умолчанию — дискета 1,44 МБ FAT12) ---
fat_lba           dw 1            ; первый сектор FAT1
fat_spf           dw 9            ; секторов в одной FAT
fat_nfats         db 2            ; копий FAT
fat_is16          db 0            ; 1 = FAT16
root_lba          dw 19           ; первый сектор корневого каталога
root_secs         dw 14           ; секторов в корне
root_nent         dw 224          ; записей в корне
data_lba          dw 31           ; first_data_sector - 2: LBA = кластер + data_lba
fat_nclus         dw 2849         ; число кластеров + 2 (кластеры 2..fat_nclus-1)
fat_eoc           dw 0x0FF8       ; значения >= этого — конец цепочки
fat_eocv          dw 0x0FFF       ; метка конца цепочки при записи
fat_win           dw 0xFFFF       ; номер первого сектора FAT в окне (FFFF = пусто)
fat_win_n         dw 2            ; секторов в окне
fat_dirty         db 0
fat_hint          dw 2            ; с какого кластера искать свободный
fat_cache         times 1024 db 0
get_max           dw 1022
rand_seed         dw 0x1234
disk_retry_count  db 0
disk_sav_ax       dw 0
disk_sav_cx       dw 0
disk_sav_dx       dw 0
disk_sav_bx       dw 0
disk_sav_es       dw 0
alloc_first       dw 0
free_cur          dw 0
free_next         dw 0
write_remaining   dw 0
write_cur_cluster dw 0
write_nclusters   dw 0
wr_old_cluster    dw 0
save_seg          dw 0
save_off          dw 0
save_len          dw 0
old_name          times 11 db ' '
new_name          times 11 db ' '
cur_dir           dw 0             ; 0 = корень
sav_dir           dw 0
sav_path          times 64 db 0
rp_isdir          db 0
api_uds           dw 0
api_fn            dw 0
api_savecx        dw 0
api_savedi        dw 0
api_ues           dw 0
api_path          times 80 db 0
api_path2         times 80 db 0
app_entry         dw 0
app_depth         db 0
con_seg           dw 0xB800         ; куда пишет print_char (GUI подменяет на экран окна)
con_attr          db 0x07           ; текущий цвет консоли (print_cstring/print_attr меняют и возвращают 0x07)
chain_flag        db 0
chain_pause       db 0
chain_pause_msg   db 13,10,"[ press any key ]", 0
chain_cmd         times 128 db 0
app_lastpath      times 80 db 0
app_savepath      times 80 db 0
app_saveargs      times 128 db 0
app_cmdbuf        times 128 db 0
rd_max            dw 0
app_nested_msg    db "Cannot start a program from inside a program (use FAPI_EXEC)", 13,10, 0
mouse_present     db 0
mouse_vis         db 0
mouse_drawn       db 0
mouse_saved       db 0
mouse_btn         db 0
mouse_x           dw 0
mouse_y           dw 0
mouse_col         dw 0
mouse_row         dw 0
mouse_rowsh       db 4
wm_seg            dw 0
wm_handler        dw 0, 0           ; смещение, сегмент
vw_top            dw 0
vw_len            dw 0
vw_line           dw 0
                  db " ------------------------", 13,10
                  db " Tab           switch panel          Enter    open dir / run .FAP / view", 13,10
                  db " Up/Down       move cursor           PgUp/PgDn Home End", 13,10
                  db " Ins / Space   mark / unmark file    + / -    mark / unmark all files", 13,10
                  db " F2            rename                F3       view file (pager)", 13,10
                  db " F4            edit in mono          F5       copy to other panel", 13,10
                  db " F6            move to other panel   F7       make directory", 13,10
                  db " F8            delete (marked or current)", 13,10
                  db " Ctrl+R        refresh               F10/Esc  quit", 13,10
                  db " F5/F6/F8 work on marked files if any, otherwise on the current entry.", 13,10
                  db 13,10, " [ press any key ]", 0
app_ss            dw 0
app_sp            dw 0
app_ext           db ".FAP", 0
sysapps_path      db "/SYSTEM/SYSAPPS/", 0
root_path         db "/", 0
system_dirname    db "SYSTEM     "
sysapps_dirname   db "SYSAPPS    "
mk_system_cmd     db "mkdir /SYSTEM", 0
mk_sysapps_cmd    db "mkdir /SYSTEM/SYSAPPS", 0
script_busy       db 0
script_len        dw 0
script_pos        dw 0
autoexec_name     db "AUTOEXECSH "
autoexec_path     db "/SYSTEM/AUTOEXEC.SH", 0
autoexec_root     db "/AUTOEXEC.SH", 0
run_usage         db "Usage: run FILE.FAP [ARGS] | run FILE.SH", 13,10, 0
sh_usage          db "Usage: sh FILE.SH", 13,10, 0
app_err           db "Cannot load program (not found, too big or not a FAPI image)", 13,10, 0
script_err        db "Cannot read script", 13,10, 0
script_nested     db "Nested scripts are not allowed", 13,10, 0
arg2_ptr          dw 0
cp_src_dir        dw 0
cp_dst_dir        dw 0
cp_src_name       times 11 db ' '
cp_dst_name       times 11 db ' '
cs_sector         dw 0
frc_max           dw 0
frc_skip          dw 0
frc_done          dw 0
fa_size           dd 0
fa_lastcl         dw 0
fa_part           dw 0
cp_same           db "Source and destination are the same file", 13,10, 0
rf_limit          dd 0
rf_size           dd 0
bmp_data          dd 0
bmp_stride        dd 0
bmp_w             dw 0
bmp_h             dw 0
bmp_bpp           dw 0
bmp_pal           dw 0
bmp_ncol          dw 0
bmp_step          dw 0
bmp_dw            dw 0
bmp_dh            dw 0
bmp_xoff          dw 0
bmp_yoff          dw 0
bmp_xstep         dw 0
bmp_topdown       db 0
wav_rate          dw 0
wav_chan          dw 0
wav_data          dw 0
wav_size          dd 0
wav_remain        dd 0
wav_skip          dw 0
wav_cur           dw 0
wav_next          dw 0
play_dev          db 0            ; 0 = SB16, 2 = Intel HDA
wav_sec_pos       dw 0            ; wav_fill: позиция/остаток в текущем секторе
wav_sec_left      dw 0
play_force        db 0xFF
wav_blk           dw 0            ; лимит для wav_fill
hda_stage         db '0'
hda_ready         db 0            ; 0 не пробовали, 1 готов, 2 нет
hda_pci           dw 0
hda_base          dd 0
hda_codecs        dw 0
hda_cad           db 0
hda_afg           db 0
hda_pin           db 0
hda_pindev        db 0
hda_best          db 0
hda_dac           db 0
hda_sd            dw 0
hda_bufaddr       dd 0            ; физический адрес буфера потока (две половины подряд)
hda_halfsz        dd 0            ; размер половины в байтах
hda_fmt           dw 0x0011       ; формат потока (SDFMT)
hda_lpib_in       dw 0            ; позиция внутри играющей половины
hda_api_on        db 0            ; поток открыт через FAPI_AUDIO
hda_eof           db 0
hda_cur           db 0
hda_ctrl_id       dd 0
hda_codec_id      dd 0
hda_step          dd 0            ; шаг ресэмплера 16.16
hda_pos           dd 0
hda_inlen         dw 0            ; кадров в текущей порции
hda_in_eof        db 0
hda_info1         db "HDA: ctrl ", 0
hda_info2         db " codec ", 0
hda_info3         db " pin ", 0
hda_info4         db " dac ", 0
wav_have_fmt      db 0
sb_pic_mask       db 0
wav_err           dw 0            ; указатель на сообщение об ошибке wav_parse
mv_src_dir        dw 0
mv_entry          times 32 db 0
lfn_valid         db 0
lfn_buf           times 261 db 0
ls_long           db 0
dir_sectors       dw 0
dir_nent          dw 0
dir_last          dw 0
cur_path          db "~", 0
                  times 62 db 0
path_root         db "/", 0
get_hist          db 0
gs_start          dw 0
gs_cur            dw 0
gs_wl             dw 0
gs_wstart         dw 0
gs_cnt            dw 0
gs_clen           dw 0
gs_namep          dw 0
gs_mode           db 0
gs_lower          db 0
gs_lcheck         db 0
gs_word           times 64 db 0
gs_cand           times 80 db 0
gs_tmp            times 80 db 0
gs_old            dw 0
gs_base           dw 0
hist_count        db 0
hist_head         db 0
hist_pos          db 0
hist_buf          times 8*128 db 0
cpu_level         db 0
boot_ticks        dd 0
cpu_v0            times 13 db 0
cpu_leaf1         dd 0
cpu_brand         times 49 db 0

prm_user          times 24 db 0   ; NAME@ferrix (строится user_build_prompt)
user_name         times 17 db 0
user_tmp          times 20 db 0
cfg_buf           times 80 db 0
tz_off            db 0              ; смещение от UTC в часах (знаковое)
rtc_utc           db 0              ; 1 = аппаратные часы идут по UTC
lt_y              dw 0
lt_mo             db 0
lt_d              db 0
lt_h              db 0
lt_mi             db 0
lt_s              db 0
lt_dim            db 31,28,31,30,31,30,31,31,30,31,30,31
lt_dow_t          db 0,3,2,5,0,3,5,1,4,6,2,4
cfg_tz_key        db "TZ=", 0
cfg_rtc_key       db "RTC=", 0
cfg_utc_str       db "UTC", 0
cfg_local_str     db "LOCAL", 0
tz_utc_pfx        db " (UTC", 0
tz_show_msg       db "Timezone: UTC", 0
tz_rtc_local      db ", hardware clock = local time", 13,10, 0
tz_rtc_utc        db ", hardware clock = UTC", 13,10, 0
tz_set_msg        db "Saved. ", 0
tz_bad_msg        db "Usage: tz [+H [utc]]   e.g. tz +7, tz -5, tz +3 utc  (-12..+14)", 13,10, 0
su_title          db 13,10, " ===== Ferrix OS first-time setup =====", 13,10, 0
su_step1          db " Step 1/4: Username (1-16 chars, no spaces)", 13,10, 0
su_step2          db " Step 2/4: Timezone - offset from UTC in hours (-12..+14), e.g. +7, -5, 0", 13,10, 0
su_tz_prompt      db "  Timezone: UTC", 0
su_step3          db " Step 3/4: What does the hardware clock (RTC) keep?", 13,10
                  db "   1) local time  (default, Windows-style)", 13,10
                  db "   2) UTC         (Linux-style; offset will be added)", 13,10, 0
su_rtc_prompt     db "  Choice [1/2]: ", 0
su_step4          db " Step 4/4: Screensaver after idle time", 13,10
                  db "   1) big clock (default)   2) matrix rain   3) off", 13,10, 0
su_saver_prompt   db "  Choice [1/2/3]: ", 0
su_saver_min      db "  Idle minutes before it starts [3]: ", 0
cfg_saver_key     db "SAVER=", 0
saver_s_off       db "OFF", 0
saver_s_clock     db "CLOCK", 0
saver_s_matrix    db "MATRIX", 0
saver_show        db "Screensaver: ", 0
saver_after       db " after ", 0
saver_minutes     db " idle minute(s)", 0
saver_bad         db "Usage: saver off | clock [MIN] | matrix [MIN]   (MIN = 1..99)", 13,10, 0
saver_mode        db 1
saver_min         db 3
su_done1          db " Setup complete! Welcome, ", 0
su_done2          db " (UTC", 0
su_done3          db "). Local time ", 0
su_done4          db ".", 13,10, " Change later: 'user NAME', 'tz +H [utc]', 'saver ...' or 'setup'.", 13,10, 0
user_host         db "@ferrix", 0
user_cfg_name     db "USER    CFG"
user_prompt_msg   db "  Username: ", 0
user_changed      db "Username changed to ", 0
greet_morning     db " Good morning, ", 0
greet_day         db " Good afternoon, ", 0
greet_evening     db " Good evening, ", 0
greet_night       db " Good night, ", 0
greet_tail        db "! Welcome back to Ferrix OS.", 13,10, 0
user_show         db "Current user: ", 0
user_bad          db "Bad name (1-16 chars, no spaces) or disk error", 13,10, 0
clk_h             db 0
clk_m             db 0
clk_s             db 0
clk_x             db 0
clock_hint        db "[ press any key to exit ]", 0
prm_colon         db " ", 0
prm_dollar        db " ", 0xAF, " ", 0

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
    db "                    |Ferrix OS v4.0|                      ", 13,10
    db "        ======================================            ", 13,10
    db "        =        |16-bit Real Mode |         =            ", 13,10
    db "        ======================================            ", 13,10
    db "==========================================================", 13,10
    db 13,10, 0

fetch_info:
    db 1, 0x0B, "  OS      ", 1, 0x08, ": ", 1, 0x07, "Ferrix OS v4.0", 13,10
    db 1, 0x0B, "  Kernel  ", 1, 0x08, ": ", 1, 0x07, "16-bit real mode", 13,10
    db 1, 0x0B, "  Shell   ", 1, 0x08, ": ", 1, 0x07, "fsh 1.0", 13,10
    db 1, 0x0B, "  FS      ", 1, 0x08, ": ", 1, 0x07, "FAT12/FAT16 (r/w)", 13,10
    db 1, 0x0B, "  Author  ", 1, 0x08, ": ", 1, 0x07, "MrCode", 13,10, 0

cmd_reboot      db "reboot", 0
cmd_shutdown    db "shutdown", 0
cmd_date        db "date", 0
cmd_time        db "time", 0
cmd_mem         db "mem", 0
cmd_echo        db "echo", 0
cmd_matrix      db "matrix", 0
cmd_ascii       db "ascii", 0
cmd_cpu         db "cpu", 0
cmd_osinfo      db "osinfo", 0
cmd_credits     db "credits", 0
cmd_hex         db "hex", 0
cmd_bin         db "bin", 0
cmd_clock       db "clock", 0
cmd_banner      db "banner", 0
cmd_pwd         db "pwd", 0
cmd_whoami      db "whoami", 0
cmd_user        db "user", 0
cmd_tz          db "tz", 0
cmd_setup       db "setup", 0
cmd_run         db "run", 0
cmd_saver       db "saver", 0
cmd_sh          db "sh", 0
cmd_cat         db "cat", 0
cmd_rm          db "rm", 0
cmd_touch       db "touch", 0
cmd_write       db "write", 0
cmd_mkdir       db "mkdir", 0
cmd_rename      db "rename", 0
cmd_cd          db "cd", 0
cmd_cp          db "cp", 0
cmd_mv          db "mv", 0
cmd_view        db "view", 0
cmd_play        db "play", 0
cmd_ls          db "ls", 0
cmd_dir         db "dir", 0
cmd_fetch       db "fetch", 0
cmd_clear       db "clear", 0
cmd_help        db "help", 0

date_msg        db "Date: ", 0
time_msg        db "Time: ", 0
mem_conv        db "Conventional: ", 0
mem_kb          db " KB", 13,10, 0
mem_ext         db "Extended: ", 0
mem_noext       db "Extended: n/a", 13,10, 0
reboot_msg      db "REBOOTING...", 13,10, 0
shutdown_msg    db "Shutting down...", 13,10, 0
apm_fail_msg    db "APM not available.", 13,10, 0
halt_msg        db "It is now safe to turn off your computer.", 13,10, 0
unknown_msg     db "Command not found. Type 'help'", 13,10, 0

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
fetch_dash      db "-----------", 0
f_os            db "OS: ", 0
f_os_v          db "Ferrix OS 4.0 x86 (16-bit)", 0
f_host          db "Host: ", 0
f_host_v        db "IBM PC/AT compatible (BIOS ", 0
f_kernel        db "Kernel: ", 0
f_kernel_v      db "ferrix-4.0-realmode", 0
f_uptime        db "Uptime: ", 0
f_hours         db " hours, ", 0
f_mins          db " mins", 0
f_shell         db "Shell: ", 0
f_shell_v       db "fsh 1.0", 0
f_res           db "Resolution: ", 0
f_res_v         db "80x25 (text, 16 colors)", 0
f_term          db "Terminal: ", 0
f_term_v        db "VGA console", 0
f_cpu           db "CPU: ", 0
f_mem           db "Memory: ", 0
f_mem_v1        db " KB base + ", 0
f_mem_v2        db " KB ext", 0
f_mem_noext     db " KB base", 0
f_disk          db "Disk ("
f_disk_letter   db "A:): ", 0
f_disk_v        db " KB / ", 0
f_disk_v12      db " KB (FAT12)", 0
f_disk_v16      db " KB (FAT16)", 0
f_disk_err      db "n/a", 0
cpu_vendor_lbl   db "Vendor  : ", 0
cpu_family_lbl   db "Family  : ", 0
cpu_model_lbl    db "  Model: ", 0
cpu_stepping_lbl db "  Step: ", 0
cpu_brand_lbl    db "Brand   : ", 0
cpu_16bit_lbl    db "Mode    : 16-bit Real Mode", 13,10, 0
cpu_lbl          db "CPU: ", 0
cpu_386_lbl      db "80386/80486 (no CPUID)", 0
cpu_286_lbl      db "80286", 0
cpu_8086_lbl     db "8086/8088", 0


hex_msg         db "Dec: ", 0
hex_result      db "0x", 0
bin_msg         db "Dec: ", 0
bin_result      db "0b", 0
hex_buffer      times 16 db 0
bin_buffer      times 16 db 0

osinfo_msg:
    db "OS: Ferrix OS v4.0", 13,10
    db "Arch: x86 16-bit", 13,10
    db "FS: FAT12/FAT16 (r/w)", 13,10, 0

credits_msg:
    db 0xB0, "================================================", 0xB0, 13,10
    db 0xB0, "                    CREDITS                     ", 0xB0, 13,10
    db 0xB0, "================================================", 0xB0, 13,10
    db 0xB0, "  OS Name: Ferrix OS v4.0                       ", 0xB0, 13,10
    db 0xB0, "  Language: NASM Assembly                       ", 0xB0, 13,10
    db 0xB0, "  Made by: MrCode                               ", 0xB0, 13,10
    db 0xB0, "================================================", 0xB0, 13,10, 0


ascii_header:
    db "HEX CHR  HEX CHR  HEX CHR  HEX CHR", 13,10
    db "==================================", 13,10, 0

boot_log_msg      db " Kernel loaded at 1000:0000. Initializing...", 13, 10, 0
welcome_msg     db " Ready. Type 'help'.", 13,10
                db "                    ", 13,10, 0
newline         db 13,10, 0

dir_header:
    db 1, 0x08, " Volume in drive "
dir_hdr_letter:
    db "A: FERRIX OS", 13, 10
    db 1, 0x07, " Directory of ", 0
dir_header2:
    db 13, 10, 13, 10, 0
dir_footer1     db 13, 10, "        ", 0
dir_footer2     db " file(s), ", 0
dir_footer3     db " bytes total", 13, 10, 0
dir_marker      db "<DIR>", 0
dir_err         db "Disk read error", 13, 10, 0
dir_count       dw 0
dir_total       dd 0

cat_usage       db "Usage: cat FILE.TXT", 13,10, 0
cat_nfound      db "File not found", 13,10, 0
cat_err         db "Disk I/O error", 13,10, 0
err_isdir       db "Is a directory", 13,10, 0
err_noarg       db "Missing argument", 13,10, 0
cat_name        times 11 db ' '
cat_cluster     dw 0
cat_size_lo     dw 0
cat_size_hi     dw 0

rm_usage        db "Usage: rm FILE.TXT", 13,10, 0
rm_ok           db "Deleted.", 13,10, 0
rm_ro           db "File is read-only.", 13,10, 0
rm_notempty     db "Directory not empty.", 13,10, 0
cd_nfound       db "No such directory", 13,10, 0
cd_notdir       db "Not a directory", 13,10, 0
touch_usage     db "Usage: touch FILE.TXT", 13,10, 0
touch_ok        db "File created (empty).", 13,10, 0
write_usage     db "Usage: write FILE.TXT text...", 13,10, 0
write_ok        db "Written.", 13,10, 0
write_exists    db "Error: file already exists.", 13,10, 0
write_nospace   db "Error: disk full.", 13,10, 0
mkdir_usage     db "Usage: mkdir NAME", 13,10, 0
mkdir_ok        db "Directory created.", 13,10, 0
rename_usage    db "Usage: rename OLD.TXT NEW.TXT", 13,10, 0
rename_ok       db "Renamed.", 13,10, 0
cp_usage        db "Usage: cp SRC DST", 13,10, 0
cp_ok           db "Copied.", 13,10, 0
cp_toobig       db "File too large to copy (max 60 KB)", 13,10, 0
mv_usage        db "Usage: mv SRC DST", 13,10, 0
mv_ok           db "Moved.", 13,10, 0
mv_loop         db "Cannot move a directory into itself", 13,10, 0
view_usage      db "Usage: view FILE.BMP", 13,10, 0
view_bad        db "Not a BMP file", 13,10, 0
view_big        db "Image too large (max ~250 KB, width <= 20000)", 13,10, 0
view_unsup      db "Unsupported BMP: need uncompressed 8/24/32-bit", 13,10, 0
view_cpu        db "view needs a 386 or better", 13,10, 0
play_usage      db "Usage: play FILE.WAV [sb|hda]", 13,10, 0
play_bad        db "Not a WAV file", 13,10, 0
play_unsup      db "Unsupported WAV: need PCM 8-bit, mono/stereo, 5-45 kHz", 13,10
                db "  ffmpeg -i song.ogg -ac 1 -ar 11025 -acodec pcm_u8 song.wav", 13,10, 0
play_dev_sb     db " s, SB16", 0
play_dev_hda    db " s, HD Audio", 0
play_opt_sb     db "sb", 0
play_sng_pfx    db "synth ", 0
play_sng_sfx    db " -p", 0
play_sng_nosynth db "SYNTH.FAP not found (needed to play .SNG)", 13,10, 0
sng_cmd         times 96 db 0
play_opt_hda    db "hda", 0
play_nodev      db "No sound device (SB16 / HD Audio)", 0
play_hda_stage  db " (HDA init stage ", 0
play_hda_err    db "HD Audio: stream setup failed", 13,10, 0
play_msg        db "Playing: ", 0
play_info1      db "  ", 0
play_info2      db " Hz 8-bit ", 0
play_mono       db "mono, ", 0
play_stereo     db "stereo, ", 0
play_info3      db "  [any key = stop]", 13,10, 0

write_slot      dw 0
new_cluster     dw 0
input_buffer    times 1024 db 0
