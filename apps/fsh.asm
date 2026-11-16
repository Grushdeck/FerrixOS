;======================================
; File name: apps/fsh.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: fsh — оболочка Ferrix (Ferrix Shell) отдельным модулем FSH.FAP; ядро запускает её после загрузки
;======================================
; Запуск: автоматически ядром после autoexec (или командой fsh).
;   Приглашение NAME@ferrix ~/путь », редактор строки (стрелки, Home/End, Del,
;   Esc — очистить), история (стрелки вверх/вниз, 16 строк, хранится в /SYSTEM/FSH.HIS),
;   Tab — дополнение имён файлов текущего каталога.
;   Встроенные команды ядра (ls, cd, cat, help, ...) выполняются через FAPI_SHELL;
;   программы (.FAP), run и sh — через FAPI_EXEC: ядро запускает их после выхода fsh
;   и снова поднимает fsh. exit — вернуться во встроенную (запасную) оболочку ядра.

%include "fapi.inc"

    FAPI_HEADER

LINE_MAX    equ 250
HIST_N      equ 16
HIST_W      equ 128

start:
    call hist_load
main_loop:
    call show_prompt
    call read_line
    call trim_line
    cmp byte [line], 0
    je main_loop
    call hist_add
    ; exit — назад в оболочку ядра
    mov si, line
    mov di, s_exit
    call word_is
    jc do_exit
    mov si, line
    mov di, s_help
    call word_is
    jc do_help
    call need_exec                  ; программа / run / sh -> через ядро
    jc do_chain
    mov si, line
    FAPI FAPI_SHELL
    jmp main_loop
do_chain:
    call hist_save
    mov si, line
    xor dl, dl
    FAPI FAPI_EXEC
    FAPI_QUIT
do_exit:
    call hist_save
    FAPI_QUIT
do_help:
    call help_command
    jmp main_loop

;--------------- приглашение ---------------
show_prompt:
    FAPI FAPI_GETCUR
    test dl, dl
    jz .sp_col0
    FAPI_PRINT crlf
.sp_col0:
    FAPI FAPI_GETCUR
    mov [prow], dh
    xor dl, dl
    mov di, userbuf
    FAPI FAPI_USERNAME
    mov si, userbuf
    call str_len                    ; CX
    mov di, userbuf
    add di, cx
    mov si, s_host
    call str_cpy                    ; userbuf = NAME@ferrix
    mov dh, [prow]
    xor dl, dl
    mov si, userbuf
    mov bl, 0x0A
    FAPI FAPI_PUTSAT
    mov si, userbuf
    call str_len
    mov [pcol], cl
    inc byte [pcol]                 ; пробел
    ; путь: "~" + cwd (для корня просто "~")
    mov byte [pathbuf], '~'
    mov di, pathbuf + 1
    FAPI FAPI_GETCWD
    cmp word [pathbuf + 1], '/'     ; "/" и 0 -> корень
    jne .sp_path
    mov byte [pathbuf + 1], 0
.sp_path:
    mov dh, [prow]
    mov dl, [pcol]
    mov si, pathbuf
    mov bl, 0x0B
    FAPI FAPI_PUTSAT
    mov si, pathbuf
    call str_len
    add [pcol], cl
    mov dh, [prow]
    mov dl, [pcol]
    mov si, s_arrow
    mov bl, 0x0F
    FAPI FAPI_PUTSAT
    add byte [pcol], 3
    mov dh, [prow]
    mov dl, [pcol]
    FAPI FAPI_SETCUR
    ret

;--------------- редактор строки ---------------
read_line:
    FAPI FAPI_GETCUR
    movzx ax, dh
    mov bl, 80
    mul bl
    movzx bx, dl
    add ax, bx
    mov [lstart], ax                ; линейная позиция начала ввода
    mov word [llen], 0
    mov word [lcur], 0
    mov word [lold], 0
    mov byte [line], 0
    mov al, [hist_count]
    mov [hist_pos], al
.rl_loop:
    FAPI FAPI_WAITKEY               ; при простое — заставка ядра
    test al, al
    jz .rl_ext
    cmp al, 0xE0
    je .rl_ext
    cmp al, 13
    je .rl_enter
    cmp al, 8
    je .rl_bs
    cmp al, 9
    je .rl_tab
    cmp al, 27
    je .rl_esc
    cmp al, 32
    jb .rl_loop
    call line_insert
    jmp .rl_redraw
.rl_ext:
    cmp ah, 0x4B
    je .rl_left
    cmp ah, 0x4D
    je .rl_right
    cmp ah, 0x47
    je .rl_home
    cmp ah, 0x4F
    je .rl_end
    cmp ah, 0x53
    je .rl_del
    cmp ah, 0x48
    je .rl_up
    cmp ah, 0x50
    je .rl_down
    jmp .rl_loop
.rl_left:
    cmp word [lcur], 0
    je .rl_loop
    dec word [lcur]
    jmp .rl_redraw
.rl_right:
    mov ax, [lcur]
    cmp ax, [llen]
    jae .rl_loop
    inc word [lcur]
    jmp .rl_redraw
.rl_home:
    mov word [lcur], 0
    jmp .rl_redraw
.rl_end:
    mov ax, [llen]
    mov [lcur], ax
    jmp .rl_redraw
.rl_bs:
    cmp word [lcur], 0
    je .rl_loop
    dec word [lcur]
    call line_delete
    jmp .rl_redraw
.rl_del:
    mov ax, [lcur]
    cmp ax, [llen]
    jae .rl_loop
    call line_delete
    jmp .rl_redraw
.rl_esc:
    mov word [llen], 0
    mov word [lcur], 0
    mov byte [line], 0
    jmp .rl_redraw
.rl_tab:
    call tab_complete
    jmp .rl_redraw
.rl_up:
    cmp byte [hist_pos], 0
    je .rl_loop
    dec byte [hist_pos]
    call hist_fetch
    jmp .rl_redraw
.rl_down:
    mov al, [hist_pos]
    cmp al, [hist_count]
    jae .rl_loop
    inc byte [hist_pos]
    mov al, [hist_pos]
    cmp al, [hist_count]
    je .rl_esc                      ; ниже истории — пустая строка
    call hist_fetch
.rl_redraw:
    call line_draw
    jmp .rl_loop
.rl_enter:
    mov ax, [llen]
    mov [lcur], ax
    call line_draw
    FAPI_PRINT crlf
    ret

; вставить AL в позицию курсора
line_insert:
    mov cx, [llen]
    cmp cx, LINE_MAX
    jae .li_ret
    mov bx, [lstart]
    add bx, cx
    cmp bx, 80 * 25 - 2             ; не вылезать за экран (иначе он прокрутится)
    jae .li_ret
    mov si, line
    add si, cx                      ; с конца (включая 0)
    mov di, si
    inc di
    sub cx, [lcur]
    inc cx                          ; сдвинуть хвост + терминатор
    std
    rep movsb
    cld
    mov bx, [lcur]
    mov [line + bx], al
    inc word [llen]
    inc word [lcur]
.li_ret:
    ret

; удалить символ в позиции курсора
line_delete:
    mov si, line
    add si, [lcur]
    mov di, si
    inc si
    mov cx, [llen]
    sub cx, [lcur]                  ; хвост с терминатором
    rep movsb
    dec word [llen]
    ret

; перерисовать строку от lstart и поставить курсор
line_draw:
    mov ax, [lstart]
    call set_lin
    mov si, line
    FAPI FAPI_PUTS
    mov cx, [lold]
    cmp cx, [llen]
    jbe .ld_cur
    sub cx, [llen]
.ld_sp:
    push cx
    mov al, ' '
    FAPI FAPI_PUTC
    pop cx
    loop .ld_sp
.ld_cur:
    mov ax, [llen]
    mov [lold], ax
    mov ax, [lstart]
    add ax, [lcur]
    call set_lin
    ret

; AX = линейная позиция -> курсор
set_lin:
    xor dx, dx
    mov bx, 80
    div bx
    mov dh, al
    mov ax, dx
    mov dl, al
    FAPI FAPI_SETCUR
    ret

;--------------- Tab: дополнение имени файла ---------------
tab_complete:
    mov ax, [lcur]
    cmp ax, [llen]
    jne .tc_ret                     ; только в конце строки
    ; начало слова
    mov si, line
    add si, ax
    mov bx, si
.tc_back:
    cmp bx, line
    je .tc_word
    cmp byte [bx - 1], ' '
    je .tc_word
    cmp byte [bx - 1], '/'
    je .tc_word
    dec bx
    jmp .tc_back
.tc_word:
    mov [wstart], bx
    mov cx, si
    sub cx, bx
    mov [wlen], cx
    ; каталог: часть слова до последнего '/' (если есть) -> dirbuf
    mov si, [wstart]
    mov di, dirpath
    mov byte [di], 0
    cmp bx, line
    je .tc_nodir
    cmp byte [bx - 1], '/'
    jne .tc_nodir
    ; скопировать от начала аргумента до '/' включительно
    mov si, bx
.tc_dback:
    cmp si, line
    je .tc_dcopy
    cmp byte [si - 1], ' '
    je .tc_dcopy
    dec si
    jmp .tc_dback
.tc_dcopy:
    lodsb
    cmp si, bx
    ja .tc_dend
    stosb
    jmp .tc_dcopy
.tc_dend:
    mov byte [di], 0
    cmp byte [dirpath], '/'         ; "/" -> оставить, иначе убрать хвостовой '/'
    jne .tc_strip
    cmp byte [dirpath + 1], 0
    je .tc_nodir
.tc_strip:
    dec di
    mov byte [di], 0
.tc_nodir:
    mov si, dirpath
    mov di, dirbuf
    mov cx, 64
    FAPI FAPI_READDIR
    jc .tc_ret
    mov [nent], ax
    xor bx, bx                      ; индекс записи
.tc_scan:
    cmp bx, [nent]
    jae .tc_ret
    mov si, bx
    shl si, 5
    add si, dirbuf
    mov al, [si]
    cmp al, 0xE5
    je .tc_next
    test al, al
    jz .tc_ret
    test byte [si + 11], 0x08       ; метка тома
    jnz .tc_next
    call entry_name                 ; -> namebuf
    ; сравнить без регистра с началом слова
    mov si, [wstart]
    mov di, namebuf
    mov cx, [wlen]
.tc_cmp:
    jcxz .tc_match
    lodsb
    call up_al
    mov ah, al
    mov al, [di]
    inc di
    call up_al
    cmp al, ah
    jne .tc_next
    dec cx
    jmp .tc_cmp
.tc_match:
    ; заменить слово на имя
    mov si, namebuf
    mov di, [wstart]
.tc_put:
    lodsb
    test al, al
    jz .tc_done
    mov cx, di
    sub cx, line
    cmp cx, LINE_MAX
    jae .tc_done
    stosb
    jmp .tc_put
.tc_done:
    mov byte [di], 0
    mov ax, di
    sub ax, line
    mov [llen], ax
    mov [lcur], ax
    ret
.tc_next:
    inc bx
    jmp .tc_scan
.tc_ret:
    ret

; DS:SI -> запись каталога FAT -> namebuf ("NAME.EXT" или "DIR/")
entry_name:
    push si
    mov di, namebuf
    mov cx, 8
.en_base:
    lodsb
    cmp al, ' '
    je .en_bs
    stosb
.en_bs:
    loop .en_base
    cmp byte [si], ' '
    je .en_noext
    mov al, '.'
    stosb
    mov cx, 3
.en_ext:
    lodsb
    cmp al, ' '
    je .en_es
    stosb
.en_es:
    loop .en_ext
.en_noext:
    pop si
    test byte [si + 11], 0x10
    jz .en_fin
    mov al, '/'
    stosb
.en_fin:
    xor al, al
    stosb
    ret

;--------------- история ---------------
hist_add:
    ; не дублировать последнюю
    cmp byte [hist_count], 0
    je .ha_put
    movzx ax, byte [hist_count]
    dec ax
    call hist_ptr                   ; SI
    mov di, line
.ha_eq:
    mov al, [si]
    cmp al, [di]
    jne .ha_put
    test al, al
    jz .ha_ret
    inc si
    inc di
    jmp .ha_eq
.ha_put:
    cmp byte [hist_count], HIST_N
    jb .ha_room
    mov si, hist + HIST_W
    mov di, hist
    mov cx, (HIST_N - 1) * HIST_W
    rep movsb
    dec byte [hist_count]
.ha_room:
    movzx ax, byte [hist_count]
    call hist_ptr
    mov di, si
    mov si, line
    mov cx, HIST_W - 1
.ha_cp:
    lodsb
    stosb
    test al, al
    jz .ha_inc
    loop .ha_cp
    mov byte [di], 0
.ha_inc:
    inc byte [hist_count]
.ha_ret:
    ret

; AX = индекс -> SI = адрес записи
hist_ptr:
    mov si, ax
    shl si, 7
    add si, hist
    ret

; запись hist_pos -> line
hist_fetch:
    movzx ax, byte [hist_pos]
    call hist_ptr
    mov di, line
    xor cx, cx
.hf_cp:
    lodsb
    stosb
    test al, al
    jz .hf_done
    inc cx
    jmp .hf_cp
.hf_done:
    mov [llen], cx
    mov [lcur], cx
    ret

hist_load:
    mov byte [hist_count], 0
    mov si, s_histfile
    mov di, hist_count
    mov cx, 1 + HIST_N * HIST_W
    FAPI FAPI_READFILE
    jc .hl_bad
    cmp byte [hist_count], HIST_N
    jbe .hl_ok
.hl_bad:
    mov byte [hist_count], 0
.hl_ok:
    ret

hist_save:
    mov si, s_histfile
    mov di, hist_count
    mov cx, 1 + HIST_N * HIST_W
    FAPI FAPI_WRITEFILE
    ret

;--------------- что это за команда ---------------
; CF=1 — надо выполнять через ядро (FAPI_EXEC): run, sh, имя программы NAME.FAP
need_exec:
    mov si, line
    mov di, s_run
    call word_is
    jc .ne_yes
    mov si, line
    mov di, s_sh
    call word_is
    jc .ne_yes
    ; первое слово -> wordbuf (верхний регистр); с '.' или '/' — не имя программы
    mov si, line
    mov di, wordbuf
    xor cx, cx
.ne_w:
    lodsb
    cmp al, ' '
    je .ne_wend
    test al, al
    jz .ne_wend
    cmp al, '.'
    je .ne_no
    cmp al, '/'
    je .ne_no
    call up_al
    stosb
    inc cx
    cmp cx, 8
    ja .ne_no
    jmp .ne_w
.ne_wend:
    jcxz .ne_no
    mov si, s_fap
    call str_cpy                    ; wordbuf = NAME.FAP
    mov si, wordbuf                 ; текущий каталог
    call file_exists
    jc .ne_yes
    mov si, s_sysapps
    call try_prefix
    jc .ne_yes
    mov si, s_fshapps
    call try_prefix
    jc .ne_yes
    mov si, s_root
    call try_prefix
    jc .ne_yes
.ne_no:
    clc
    ret
.ne_yes:
    stc
    ret

; SI = префикс каталога: существует ли префикс + wordbuf
try_prefix:
    mov di, pathbuf
    call str_cpy
    mov si, wordbuf
    call str_cpy
    mov si, pathbuf
; DS:SI путь -> CF=1 существует (файл)
file_exists:
    FAPI FAPI_STAT
    jc .fe_no
    test cl, 0x10
    jnz .fe_no
    stc
    ret
.fe_no:
    clc
    ret

;--------------- строки ---------------
; первое слово DS:SI == ASCIIZ DS:DI (без регистра) -> CF=1
word_is:
.wi_loop:
    mov al, [di]
    call up_al
    mov ah, al
    mov al, [si]
    test ah, ah
    jz .wi_end
    call up_al
    cmp al, ah
    jne .wi_no
    inc si
    inc di
    jmp .wi_loop
.wi_end:
    test al, al
    jz .wi_yes
    cmp al, ' '
    je .wi_yes
.wi_no:
    clc
    ret
.wi_yes:
    stc
    ret

up_al:
    cmp al, 'a'
    jb .ua_ret
    cmp al, 'z'
    ja .ua_ret
    sub al, 32
.ua_ret:
    ret

; DS:SI -> CX длина
str_len:
    push si
    xor cx, cx
.sl_l:
    lodsb
    test al, al
    jz .sl_d
    inc cx
    jmp .sl_l
.sl_d:
    pop si
    ret

; копировать ASCIIZ SI -> DI, DI остаётся на терминаторе
str_cpy:
    lodsb
    stosb
    test al, al
    jnz str_cpy
    dec di
    ret

; удалить ведущие и хвостовые пробелы в line
trim_line:
    mov si, line
.tl_lead:
    cmp byte [si], ' '
    jne .tl_copy
    inc si
    jmp .tl_lead
.tl_copy:
    mov di, line
.tl_c:
    lodsb
    stosb
    test al, al
    jnz .tl_c
    dec di
.tl_tail:
    cmp di, line
    je .tl_ret
    cmp byte [di - 1], ' '
    jne .tl_ret
    dec di
    mov byte [di], 0
    jmp .tl_tail
.tl_ret:
    ret


;--------------- help ---------------
HG_FILES  equ 1
HG_SYSTEM equ 2
HG_MEDIA  equ 3
HG_TOOLS  equ 4
HG_GAMES  equ 5
HG_INFO   equ 6

; help | help GROUP | help CMD  (аргумент — в line после слова help)
help_command:
    mov si, line + 4
.hc_sp:
    cmp byte [si], ' '
    jne .hc_arg
    inc si
    jmp .hc_sp
.hc_arg:
    cmp byte [si], 0
    je .hc_overview
    ; группа?
    mov di, help_groups
    mov bl, 1
.hc_grp:
    cmp byte [di], 0
    je .hc_cmd
    call word_eq
    jc .hc_group
    call skipz
    inc bl
    jmp .hc_grp
.hc_group:
    mov ax, si
    mov si, help_hdr
    call put_s
    mov si, di
    call put_s
    mov si, help_hdr2
    call put_s
    mov di, help_tab
.hg_l:
    cmp byte [di], 0
    je .hc_ret
    call entry_group
    cmp al, bl
    jne .hg_n
    call print_entry
.hg_n:
    call help_next
    jmp .hg_l
.hc_cmd:
    mov di, help_tab
.hc_cl:
    cmp byte [di], 0
    je .hc_unknown
    call word_eq
    jc .hc_found
    call help_next
    jmp .hc_cl
.hc_found:
    call print_entry
    ret
.hc_unknown:
    mov si, help_unknown
    call put_s
.hc_ret:
    ret
.hc_overview:
    mov si, help_title
    call put_s
    mov bl, 1
    mov di, help_groups
.ov_g:
    cmp byte [di], 0
    je .ov_done
    mov al, ' '
    call put_c
    mov si, di
    mov cx, 8
.ov_n:
    lodsb
    test al, al
    jz .ov_pad
    call put_c
    dec cx
    jmp .ov_n
.ov_pad:
    mov al, ' '
    call put_c
    loop .ov_pad
    mov al, ':'
    call put_c
    ; имена команд группы BL
    push di
    mov di, help_tab
.ov_t:
    cmp byte [di], 0
    je .ov_tdone
    call entry_group
    cmp al, bl
    jne .ov_tn
    mov al, ' '
    call put_c
    mov si, di
    call put_s
.ov_tn:
    call help_next
    jmp .ov_t
.ov_tdone:
    pop di
    mov si, crlf
    call put_s
    call skipz
    inc bl
    jmp .ov_g
.ov_done:
    mov si, help_foot
    call put_s
    ret

; DI -> запись: AL = группа
entry_group:
    push di
.eg:
    inc di
    cmp byte [di - 1], 0
    jne .eg
    mov al, [di]
    pop di
    ret
; DI -> следующая запись
help_next:
    call skipz                      ; имя
    inc di                          ; группа
    call skipz                      ; описание
    ret
; DI -> за терминатор строки
skipz:
    inc di
    cmp byte [di - 1], 0
    jne skipz
    ret
; запись DI: " синтаксис(21, ярко) описание(серым)" — собирается в hbuf и печатается одним PUTS
print_entry:
    push di
    push si
    call skipz
    inc di
    mov si, di
    mov di, hbuf
    mov al, ' '
    stosb
    mov al, 1
    stosb
    mov al, 0x0F
    stosb
    mov cx, 21
.pe_syn:
    lodsb
    test al, al
    jz .pe_eol
    stosb
    loop .pe_syn
    mov al, 1
    stosb
    mov al, 0x08
    stosb
.pe_rest:
    lodsb
    stosb
    test al, al
    jnz .pe_rest
    dec di
.pe_eol:
    mov al, 13
    stosb
    mov al, 10
    stosb
    xor al, al
    stosb
    mov si, hbuf
    call put_s
    pop si
    pop di
    ret
; слово DS:SI (до пробела/0) == ASCIIZ DS:DI (без регистра) -> CF=1
word_eq:
    push si
    push di
    call word_is
    pop di
    pop si
    ret
put_s:
    push ax
    push si
    FAPI FAPI_PUTS
    pop si
    pop ax
    ret
put_c:
    push ax
    push si
    FAPI FAPI_PUTC
    pop si
    pop ax
    ret

help_groups:
    db "files", 0, "system", 0, "media", 0, "tools", 0, "games", 0, "info", 0, 0
help_title      db "== FERRIX OS COMMANDS (fsh) ==", 13,10, 0
help_foot       db " Type 'help GROUP' (e.g. help files) or 'help COMMAND' for details.", 13,10, 0
help_hdr        db "== ", 0
help_hdr2       db " ==", 13,10, 0
help_unknown    db "No such command or group. Groups: files system media tools games info", 13,10, 0
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
    db "fetch", 0,   HG_SYSTEM, "fetch                system info (neofetch style) (FETCH.FAP)", 0
    db "cpu", 0,     HG_SYSTEM, "cpu                  processor details (CPUID) (CPU.FAP)", 0
    db "mem", 0,     HG_SYSTEM, "mem                  conventional/extended memory (MEM.FAP)", 0
    db "date", 0,    HG_SYSTEM, "date                 show date (DATE.FAP)", 0
    db "time", 0,    HG_SYSTEM, "time                 show time (TIME.FAP)", 0
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
    db "echo", 0,    HG_TOOLS,  "echo TEXT            print text (ECHO.FAP)", 0
    db "calc", 0,    HG_TOOLS,  "calc [-c] [EXPR]     calculator (CALC.FAP): window mode; -c = console", 0
    db "paint", 0,   HG_TOOLS,  "paint [FILE.BMP]     16-color paint, saves BMP (PAINT.FAP, mouse)", 0
    db "iron", 0,    HG_TOOLS,  "iron SRC.ASM OUT.FAP frasm assembler -> .FAP program (IRON.FAP)", 0
    db "ferramp", 0, HG_MEDIA,  "ferramp [DIR|FILE]   music player: WAV/SNG playlist (FERRAMP.FAP)", 0
    db "synth", 0,   HG_MEDIA,  "synth [FILE.SNG]     piano + sequencer on HD Audio (SYNTH.FAP)", 0
    db "gui", 0,     HG_SYSTEM, "gui [-t N | -w BMP]  window manager (GUI.FAP): fm + apps in windows", 0
    db "fsh", 0,     HG_SYSTEM, "fsh                  Ferrix shell module (FSH.FAP, started at boot)", 0
    db "exit", 0,    HG_SYSTEM, "exit                 leave fsh (back to the kernel emergency shell)", 0
    db "hex", 0,     HG_TOOLS,  "hex N                decimal -> hexadecimal (HEX.FAP)", 0
    db "bin", 0,     HG_TOOLS,  "bin N                decimal -> binary (BIN.FAP)", 0
    db "ascii", 0,   HG_TOOLS,  "ascii                ASCII table (ASCII.FAP)", 0
    db "matrix", 0,  HG_TOOLS,  "matrix               matrix rain screensaver (any key = exit) (MATRIX.FAP)", 0
    db "help", 0,    HG_INFO,   "help [GROUP|CMD]     this help: groups, group list or one command", 0
    db "clear", 0,   HG_TOOLS,  "clear                clear screen and redraw banner", 0
    db "banner", 0,  HG_INFO,   "banner               show the Ferrix banner (BANNER.FAP)", 0
    db "osinfo", 0,  HG_INFO,   "osinfo               about the OS (OSINFO.FAP)", 0
    db "credits", 0, HG_INFO,   "credits              authors (CREDITS.FAP)", 0
    db "snake", 0,   HG_GAMES,  "snake                snake (arrows/WASD, P pause, Esc quit)", 0
    db "tetris", 0,  HG_GAMES,  "tetris               tetris (arrows, Up rotate, Space drop)", 0
    db "mines", 0,   HG_GAMES,  "mines                minesweeper (arrows, Space open, F flag)", 0
    db "2048", 0,    HG_GAMES,  "2048                 join tiles to 2048 (arrows/WASD, R restart)", 0
    db "pong", 0,    HG_GAMES,  "pong                 pong vs CPU, first to 10 (W/S or arrows)", 0
    db "micro", 0,   HG_GAMES,  "micro FILE.CH8       CHIP-8 emulator: micro /BALL.CH8", 0
    db 0

;--------------- данные ---------------
crlf        db 13,10, 0
s_host      db "@ferrix", 0
s_arrow     db " ", 0xAF, " ", 0
s_exit      db "EXIT", 0
s_help      db "HELP", 0
s_run       db "RUN", 0
s_sh        db "SH", 0
s_fap       db ".FAP", 0
s_sysapps   db "/SYSTEM/SYSAPPS/", 0
s_fshapps   db "/SYSTEM/SYSAPPS/FSH/", 0
s_root      db "/", 0
s_histfile  db "/SYSTEM/FSH.HIS", 0

prow        db 0
pcol        db 0
lstart      dw 0
llen        dw 0
lcur        dw 0
lold        dw 0
wstart      dw 0
wlen        dw 0
nent        dw 0
hist_pos    db 0

userbuf     times 40 db 0
pathbuf     times 100 db 0
dirpath     times 100 db 0
wordbuf     times 16 db 0
namebuf     times 16 db 0
line        times LINE_MAX + 8 db 0
hist_count  db 0                    ; за ним сразу записи — вместе пишутся в файл
hist        times HIST_N * HIST_W db 0
dirbuf      times 64 * 32 db 0
hbuf        times 100 db 0
