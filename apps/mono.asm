;======================================
; File name: apps/mono.asm
; Project: FERRIX-OS
; Description: mono — полноэкранный текстовый редактор (внешняя программа .FAP)
;======================================
; mono [FILE.TXT]
; Интерфейс: строка меню (F10 или щелчок мышью), текст 23 строки с горизонтальной
; прокруткой, строка состояния (имя, признак изменений, Ln/Col, размер), диалоги
; (открыть, сохранить как, поиск, замена, перейти к строке, подтверждения, справка).
; Буфер ed_buf (до ED_MAX байт), строки разделены LF. При загрузке CR выбрасывается,
; при сохранении LF -> CR LF (потоково через sv_buf).
; Клавиши: стрелки, Home/End, PgUp/PgDn, Ctrl+Home/End (начало/конец текста), Del, BS,
;   Enter, Tab (4 пробела); Ctrl+S сохранить, F2 сохранить как, Ctrl+O открыть, Ctrl+N новый,
;   Ctrl+X/Ctrl+C/Ctrl+V вырезать/копировать/вставить строку, Ctrl+Y удалить строку,
;   Ctrl+F найти, F3 найти далее, Ctrl+R заменить, Ctrl+G перейти к строке,
;   F1 справка, F10 меню, Esc выход (с вопросом о сохранении), Ctrl+Q выход без сохранения.
; Мышь: щелчок по меню / по тексту (переставить курсор).

%include "fapi.inc"

ED_MAX   equ 56000              ; текст (LF)
SV_CHUNK equ 2048               ; буфер потокового сохранения
TXT_Y    equ 1                  ; первая строка текста
TXT_ROWS equ 23                 ; строк текста
STAT_Y   equ 24                 ; строка состояния
CLIP_MAX equ 512                ; буфер строки (вырезать/копировать)
INP_MAX  equ 60                 ; длина ввода в диалоге

A_TEXT   equ 0x07
A_MENU   equ 0x70
A_MSEL   equ 0x2F               ; выбранный пункт
A_HOT    equ 0x74               ; буква-ускоритель
A_STAT   equ 0x70
A_MSG    equ 0x7C               ; сообщение в строке состояния
A_DLG    equ 0x1F
A_DLGT   equ 0x3F               ; заголовок диалога
A_INP    equ 0x0F               ; поле ввода

    FAPI_HEADER

start:
    cld
    mov byte [fname], 0
    ; --- аргумент: имя файла ---
    mov si, 0x80
    call skip_spaces
    cmp byte [si], 0
    je .noarg
    mov di, fname
    mov cx, 62
.cp:
    lodsb
    cmp al, ' '
    jbe .cpd
    stosb
    loop .cp
.cpd:
    mov byte [di], 0
.noarg:
    call ed_clear
    mov si, msg_hint
    call ed_status
    cmp byte [fname], 0
    je .run
    mov si, fname
    call ed_load                    ; ошибки показываются в статусе
.run:
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    call ed_run
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

skip_spaces:
    cmp byte [si], ' '
    jne .ss_ret
    inc si
    jmp skip_spaces
.ss_ret:
    ret

;================================================================ файл
; пустой буфер
ed_clear:
    mov word [ed_len], 0
    mov word [ed_cur], 0
    mov word [ed_top], 0
    mov word [ed_left], 0
    mov byte [ed_dirty], 0
    ret

; загрузить файл DS:SI в буфер (буфер очищается). CF=1 ошибка (сообщение уже в статусе)
ed_load:
    mov [ld_path], si
    call ed_clear
    mov si, [ld_path]
    FAPI FAPI_STAT
    jc .newfile                     ; нет файла — пустой новый
    test dx, dx
    jnz .toobig
    cmp ax, ED_MAX
    ja .toobig
    push ds
    pop es
    mov di, ed_buf
    xor bx, bx                      ; номер сектора
.ld_loop:
    mov cx, ed_buf + ED_MAX
    sub cx, di                      ; свободно
    jz .ld_done
    cmp cx, 0x8000
    jbe .ld_cx
    mov cx, 0x8000
.ld_cx:
    push cx
    mov si, [ld_path]
    FAPI FAPI_READAT
    pop cx
    jc .ioerr
    test ax, ax
    jz .ld_done
    add di, ax
    cmp ax, cx
    jb .ld_done
    add bx, 64
    jmp .ld_loop
.ld_done:
    mov cx, di
    sub cx, ed_buf
    call strip_cr                   ; CX байт -> [ed_len] без CR
    mov si, msg_loaded
    call ed_status
    clc
    ret
.ioerr:
    call ed_clear
    mov si, msg_ioerr
    call ed_status
    stc
    ret
.toobig:
    mov si, msg_toobig
    call ed_status
    stc
    ret
.newfile:
    mov si, msg_newfile
    call ed_status
    clc
    ret

; убрать CR из ed_buf (CX байт), результат -> ed_len
strip_cr:
    mov si, ed_buf
    mov di, ed_buf
    jcxz .sc_done
.sc_loop:
    lodsb
    cmp al, 13
    je .sc_skip
    stosb
.sc_skip:
    loop .sc_loop
.sc_done:
    sub di, ed_buf
    mov [ed_len], di
    ret

; сохранение в [fname]: LF -> CR LF потоково через буфер sv_buf:
; первый кусок — WRITEFILE (создать/обрезать), остальные — APPEND. CF=1 ошибка
ed_save:
    cmp byte [fname], 0
    jne .es_go
    call act_saveas                 ; имени нет — спросить
    ret
.es_go:
    mov si, ed_buf
    mov cx, [ed_len]
    mov byte [sv_first], 1
.es_chunk:
    mov di, sv_buf
.es_fill:
    jcxz .es_flush
    cmp di, sv_buf + SV_CHUNK - 2
    ja .es_flush
    lodsb
    dec cx
    cmp al, 10
    jne .es_put
    mov byte [di], 13
    inc di
.es_put:
    stosb
    jmp .es_fill
.es_flush:
    push cx
    push si
    mov cx, di
    sub cx, sv_buf
    mov si, fname
    mov di, sv_buf
    push ds
    pop es
    cmp byte [sv_first], 0
    je .es_app
    mov byte [sv_first], 0
    FAPI FAPI_WRITEFILE
    jmp .es_wr
.es_app:
    FAPI FAPI_APPEND
.es_wr:
    pop si
    pop cx
    jc .es_err
    jcxz .es_ok
    jmp .es_chunk
.es_ok:
    mov byte [ed_dirty], 0
    mov si, msg_saved
    call ed_status
    clc
    ret
.es_err:
    mov si, msg_saveerr
    call ed_status
    stc
    ret

;================================================================ главный цикл
ed_run:
.er_loop:
    call ed_adjust
    call ed_render
    call draw_menubar
    call draw_statbar
    call ed_place_cursor
    call wait_input                 ; AX = клавиша (как GETKEY) или 0 = обработано мышью
    test ax, ax
    jnz .er_key
    cmp byte [m_quit], 0
    jne .er_quit
    jmp .er_loop
.er_key:
    mov word [st_msg], 0            ; любое нажатие снимает сообщение
    test al, al
    jz .er_ext
    cmp al, 0xE0
    je .er_ext
    cmp al, 27
    je .er_esc
    cmp al, 13
    je .er_enter
    cmp al, 8
    je .er_bs
    cmp al, 9
    je .er_tab
    cmp al, 32
    jb .er_ctrl
    cmp al, 254
    ja .er_loop
    call ed_insert
    jmp .er_loop
.er_ctrl:
    ; Ctrl+буква -> действие
    mov si, ctrl_tab
.ct_l:
    cmp byte [si], 0
    je .er_loop
    cmp [si], al
    je .ct_f
    add si, 2
    jmp .ct_l
.ct_f:
    mov al, [si + 1]
    call do_action
    jc .er_quit
    jmp .er_loop
.er_enter:
    mov al, 10
    call ed_insert
    jmp .er_loop
.er_tab:
    mov cx, 4
.er_tab_l:
    mov al, ' '
    call ed_insert
    loop .er_tab_l
    jmp .er_loop
.er_bs:
    cmp word [ed_cur], 0
    je .er_loop
    dec word [ed_cur]
    call ed_delete
    jmp .er_loop
.er_ext:
    cmp ah, 0x4B
    je .er_left
    cmp ah, 0x4D
    je .er_right
    cmp ah, 0x48
    je .er_up
    cmp ah, 0x50
    je .er_down
    cmp ah, 0x47
    je .er_home
    cmp ah, 0x4F
    je .er_end
    cmp ah, 0x53
    je .er_del
    cmp ah, 0x49                    ; PgUp
    je .er_pgup
    cmp ah, 0x51                    ; PgDn
    je .er_pgdn
    cmp ah, 0x77                    ; Ctrl+Home
    je .er_chome
    cmp ah, 0x75                    ; Ctrl+End
    je .er_cend
    cmp ah, 0x3B                    ; F1
    je .er_f1
    cmp ah, 0x3C                    ; F2
    je .er_f2
    cmp ah, 0x3D                    ; F3
    je .er_f3
    cmp ah, 0x44                    ; F10
    je .er_f10
    jmp .er_loop
.er_f1:
    mov al, ACT_KEYS
    jmp .er_act
.er_f2:
    mov al, ACT_SAVEAS
    jmp .er_act
.er_f3:
    mov al, ACT_FINDNEXT
.er_act:
    call do_action
    jc .er_quit
    jmp .er_loop
.er_f10:
    xor ax, ax
    call menu_run                   ; AL = действие или 0
    test al, al
    jz .er_loop
    jmp .er_act
.er_left:
    cmp word [ed_cur], 0
    je .er_loop
    dec word [ed_cur]
    jmp .er_loop
.er_right:
    mov ax, [ed_cur]
    cmp ax, [ed_len]
    jae .er_loop
    inc word [ed_cur]
    jmp .er_loop
.er_del:
    mov ax, [ed_cur]
    cmp ax, [ed_len]
    jae .er_loop
    call ed_delete
    jmp .er_loop
.er_home:
    mov ax, [ed_cur]
    call ed_line_start
    mov [ed_cur], ax
    jmp .er_loop
.er_end:
    mov ax, [ed_cur]
    call ed_line_end
    mov [ed_cur], ax
    jmp .er_loop
.er_chome:
    mov word [ed_cur], 0
    jmp .er_loop
.er_cend:
    mov ax, [ed_len]
    mov [ed_cur], ax
    jmp .er_loop
.er_pgup:
    mov cx, TXT_ROWS - 1
.er_pgup_l:
    call ed_move_up
    loop .er_pgup_l
    jmp .er_loop
.er_pgdn:
    mov cx, TXT_ROWS - 1
.er_pgdn_l:
    call ed_move_down
    loop .er_pgdn_l
    jmp .er_loop
.er_up:
    call ed_move_up
    jmp .er_loop
.er_down:
    call ed_move_down
    jmp .er_loop
.er_esc:
    mov al, ACT_EXIT
    call do_action
    jc .er_quit
    jmp .er_loop
.er_quit:
    ret

; ждать клавишу или щелчок мыши. -> AX клавиша; AX=0 если щелчок обработан
wait_input:
.wi_loop:
    FAPI FAPI_KEYHIT
    jnz .wi_key
    call mouse_poll
    jc .wi_mouse
    hlt
    jmp .wi_loop
.wi_key:
    FAPI FAPI_GETKEY
    ret
.wi_mouse:
    xor ax, ax
    ret

; опрос мыши: CF=1 — был щелчок и он обработан
mouse_poll:
    FAPI FAPI_MOUSE
    test ah, ah
    jz .mp_no
    test al, 1
    jz .mp_rel
    cmp byte [m_down], 0
    jne .mp_no
    mov byte [m_down], 1
    mov word [st_msg], 0
    ; строка меню?
    test dx, dx
    jnz .mp_text
    call menu_title_at              ; CX столбец -> BL меню
    jc .mp_no
    mov al, bl
    xor ah, ah
    call menu_run
    test al, al
    jz .mp_yes
    call do_action
    jc .mp_quit
.mp_yes:
    stc
    ret
.mp_quit:
    ; выход по мыши через меню: имитировать Ctrl+Q на следующем шаге
    mov byte [m_quit], 1
    stc
    ret
.mp_text:
    cmp dx, TXT_Y
    jb .mp_no
    cmp dx, TXT_Y + TXT_ROWS
    jae .mp_no
    ; курсор в строку (dx-TXT_Y) от ed_top, колонку cx+ed_left
    sub dx, TXT_Y
    mov ax, [ed_top]
.mp_row:
    test dx, dx
    jz .mp_col
    call ed_next_line
    jc .mp_col_last
    dec dx
    jmp .mp_row
.mp_col_last:
    ; строк меньше, чем щёлкнули — последняя строка
    mov ax, [ed_len]
    call ed_line_start
.mp_col:
    ; AX = начало строки; колонка = cx + ed_left, не дальше конца строки
    add cx, [ed_left]
    mov bx, ax
    call ed_line_end                ; AX = конец
    add bx, cx
    cmp bx, ax
    jbe .mp_set
    mov bx, ax
.mp_set:
    mov [ed_cur], bx
    stc
    ret
.mp_rel:
    mov byte [m_down], 0
.mp_no:
    clc
    ret

;================================================================ действия
ACT_NEW      equ 1
ACT_OPEN     equ 2
ACT_SAVE     equ 3
ACT_SAVEAS   equ 4
ACT_EXIT     equ 5
ACT_CUT      equ 6
ACT_COPY     equ 7
ACT_PASTE    equ 8
ACT_DELLINE  equ 9
ACT_GOTO     equ 10
ACT_FIND     equ 11
ACT_FINDNEXT equ 12
ACT_REPLACE  equ 13
ACT_KEYS     equ 14
ACT_ABOUT    equ 15
ACT_QUIT     equ 16

; AL = действие. CF=1 — выйти из редактора
do_action:
    xor ah, ah
    dec ax
    cmp ax, 16
    jae .da_no
    shl ax, 1
    mov bx, ax
    call [act_tab + bx]
    ret
.da_no:
    clc
    ret

act_tab dw act_new, act_open, act_save, act_saveas, act_exit, act_cut, act_copy, act_paste
        dw act_delline, act_goto, act_find, act_findnext, act_replace, act_keys, act_about, act_quit

; Ctrl-код -> действие
ctrl_tab db 0x13, ACT_SAVE          ; Ctrl+S
         db 0x0F, ACT_OPEN          ; Ctrl+O
         db 0x0E, ACT_NEW           ; Ctrl+N
         db 0x18, ACT_CUT           ; Ctrl+X
         db 0x03, ACT_COPY          ; Ctrl+C
         db 0x16, ACT_PASTE         ; Ctrl+V
         db 0x19, ACT_DELLINE       ; Ctrl+Y
         db 0x06, ACT_FIND          ; Ctrl+F
         db 0x12, ACT_REPLACE       ; Ctrl+R
         db 0x07, ACT_GOTO          ; Ctrl+G
         db 0x11, ACT_QUIT          ; Ctrl+Q
         db 0

; если есть несохранённые изменения — спросить. CF=1 отмена
ask_discard:
    cmp byte [ed_dirty], 0
    je .ad_ok
    mov si, dlg_unsaved
    call dlg_yesno                  ; AL: 'Y' / 'N' / 27
    cmp al, 27
    je .ad_cancel
    cmp al, 'Y'
    jne .ad_ok
    call ed_save
    jc .ad_cancel
.ad_ok:
    clc
    ret
.ad_cancel:
    stc
    ret

act_new:
    call ask_discard
    jc .an_r
    call ed_clear
    mov byte [fname], 0
    mov si, msg_newbuf
    call ed_status
.an_r:
    clc
    ret

act_open:
    call ask_discard
    jc .ao_r
    mov si, dlg_open
    mov di, inp_buf
    mov byte [inp_buf], 0
    call dlg_input
    jc .ao_r
    cmp byte [inp_buf], 0
    je .ao_r
    mov si, inp_buf
    mov di, fname
    call str_copy
    mov si, fname
    call ed_load
.ao_r:
    clc
    ret

act_save:
    call ed_save
    clc
    ret

act_saveas:
    mov si, dlg_saveas
    mov di, inp_buf
    push si
    mov si, fname
    call str_copy                   ; подставить текущее имя
    pop si
    call dlg_input
    jc .as_r
    cmp byte [inp_buf], 0
    je .as_r
    mov si, inp_buf
    mov di, fname
    call str_copy
    call ed_save
.as_r:
    clc
    ret

act_exit:
    call ask_discard
    jc .ae_stay
    stc
    ret
.ae_stay:
    clc
    ret

act_quit:
    stc
    ret

; скопировать текущую строку (с LF) в clip
act_copy:
    call clip_line
    mov si, msg_copied
    call ed_status
    clc
    ret

act_cut:
    call clip_line
    call del_line
    mov si, msg_cut
    call ed_status
    clc
    ret

act_delline:
    call del_line
    clc
    ret

act_paste:
    mov cx, [clip_len]
    jcxz .ap_r
    ; вставить в начало текущей строки
    mov ax, [ed_cur]
    call ed_line_start
    mov [ed_cur], ax
    mov si, clip
.ap_l:
    lodsb
    call ed_insert
    loop .ap_l
.ap_r:
    clc
    ret

; текущая строка с LF -> clip
clip_line:
    mov ax, [ed_cur]
    call ed_line_start
    mov si, ax
    call ed_line_end                ; AX = LF или ed_len
    mov cx, ax
    sub cx, si
    cmp ax, [ed_len]
    jae .cl_nolf
    inc cx                          ; вместе с LF
.cl_nolf:
    cmp cx, CLIP_MAX
    jbe .cl_ok
    mov cx, CLIP_MAX
.cl_ok:
    mov [clip_len], cx
    add si, ed_buf
    mov di, clip
    push ds
    pop es
    rep movsb
    ret

; удалить текущую строку целиком
del_line:
    mov ax, [ed_cur]
    call ed_line_start
    mov [ed_cur], ax
    call ed_line_end
    mov cx, ax
    sub cx, [ed_cur]
    cmp ax, [ed_len]
    jae .dl_cnt
    inc cx
.dl_cnt:
    jcxz .dl_r
.dl_l:
    call ed_delete
    loop .dl_l
.dl_r:
    ret

act_goto:
    mov si, dlg_goto
    mov di, inp_buf
    mov byte [inp_buf], 0
    call dlg_input
    jc .ag_r
    mov si, inp_buf
    call parse_dec                  ; -> AX
    test ax, ax
    jz .ag_r
    mov cx, ax
    dec cx
    xor ax, ax
.ag_l:
    jcxz .ag_set
    call ed_next_line
    jc .ag_set
    loop .ag_l
.ag_set:
    mov [ed_cur], ax
.ag_r:
    clc
    ret

act_find:
    mov si, dlg_find
    mov di, inp_buf
    push si
    mov si, find_str
    call str_copy
    pop si
    call dlg_input
    jc .af_r
    cmp byte [inp_buf], 0
    je .af_r
    mov si, inp_buf
    mov di, find_str
    call str_copy
    call find_from_next
.af_r:
    clc
    ret

act_findnext:
    cmp byte [find_str], 0
    je act_find
    call find_from_next
    clc
    ret

; искать find_str начиная с ed_cur+1 (с переходом через начало). Нашли -> ed_cur
find_from_next:
    mov ax, [ed_cur]
    inc ax
    call find_at                    ; CF=1 нет
    jnc .ff_ok
    xor ax, ax
    call find_at
    jnc .ff_ok
    mov si, msg_notfound
    call ed_status
    ret
.ff_ok:
    mov [ed_cur], ax
    ret

; поиск find_str с позиции AX -> AX позиция; CF=1 нет
find_at:
    push bx
    push cx
    push si
    push di
    mov di, find_str
    call str_len                    ; CX = длина
    jcxz .fa_no
    mov bx, ax
.fa_pos:
    mov ax, bx
    add ax, cx
    cmp ax, [ed_len]
    ja .fa_no
    push cx
    mov si, bx
    add si, ed_buf
    mov di, find_str
.fa_cmp:
    lodsb
    cmp al, [di]
    jne .fa_next
    inc di
    loop .fa_cmp
    pop cx
    mov ax, bx
    clc
    jmp .fa_ret
.fa_next:
    pop cx
    inc bx
    jmp .fa_pos
.fa_no:
    stc
.fa_ret:
    pop di
    pop si
    pop cx
    pop bx
    ret

act_replace:
    mov si, dlg_find
    mov di, inp_buf
    push si
    mov si, find_str
    call str_copy
    pop si
    call dlg_input
    jc .ar_r
    cmp byte [inp_buf], 0
    je .ar_r
    mov si, inp_buf
    mov di, find_str
    call str_copy
    mov si, dlg_repl
    mov di, inp_buf
    mov byte [inp_buf], 0
    call dlg_input
    jc .ar_r
    mov si, inp_buf
    mov di, repl_str
    call str_copy
    mov word [repl_cnt], 0
    mov byte [repl_all], 0
    mov ax, [ed_cur]
.ar_next:
    call find_at
    jc .ar_done
    mov [ed_cur], ax
    cmp byte [repl_all], 0
    jne .ar_do
    ; показать и спросить
    call ed_adjust
    call ed_render
    call ed_place_cursor
    mov si, dlg_replq
    call dlg_yesno                  ; Y / N / A / Esc
    cmp al, 27
    je .ar_done
    cmp al, 'A'
    jne .ar_q1
    mov byte [repl_all], 1
    jmp .ar_do
.ar_q1:
    cmp al, 'Y'
    jne .ar_skip
.ar_do:
    ; удалить find_str, вставить repl_str
    mov di, find_str
    call str_len
.ar_del:
    call ed_delete
    loop .ar_del
    mov si, repl_str
.ar_ins:
    lodsb
    test al, al
    jz .ar_ins_d
    call ed_insert
    jmp .ar_ins
.ar_ins_d:
    inc word [repl_cnt]
    mov ax, [ed_cur]
    jmp .ar_next
.ar_skip:
    mov ax, [ed_cur]
    inc ax
    jmp .ar_next
.ar_done:
    mov ax, [repl_cnt]
    mov di, numbuf
    call fmt_dec
    mov si, msg_replaced
    call ed_status_num              ; "Replaced: N"
.ar_r:
    clc
    ret

act_keys:
    mov si, help_lines
    mov cx, HELP_N
    mov di, dlg_keys
    call dlg_text
    clc
    ret

act_about:
    mov si, about_lines
    mov cx, ABOUT_N
    mov di, dlg_about
    call dlg_text
    clc
    ret

;================================================================ меню
MENU_N   equ 4
menu_x   db 1, 8, 15, 24          ; столбец заголовка
menu_w   db 6, 6, 8, 6            ; ширина заголовка (с пробелами)
menu_t   dw mt_file, mt_edit, mt_search, mt_help
menu_items dw mi_file, mi_edit, mi_search, mi_help
menu_cnt db 5, 5, 3, 2
MI_W     equ 26                     ; ширина пункта (текст)
mt_file   db " File ", 0
mt_edit   db " Edit ", 0
mt_search db " Search ", 0
mt_help   db " Help ", 0
; пункты: 26 байт текста + байт действия
mi_file:
    db " New             Ctrl+N  ", ACT_NEW
    db " Open...         Ctrl+O  ", ACT_OPEN
    db " Save            Ctrl+S  ", ACT_SAVE
    db " Save as...      F2      ", ACT_SAVEAS
    db " Exit            Esc     ", ACT_EXIT
mi_edit:
    db " Cut line        Ctrl+X  ", ACT_CUT
    db " Copy line       Ctrl+C  ", ACT_COPY
    db " Paste line      Ctrl+V  ", ACT_PASTE
    db " Delete line     Ctrl+Y  ", ACT_DELLINE
    db " Go to line...   Ctrl+G  ", ACT_GOTO
mi_search:
    db " Find...         Ctrl+F  ", ACT_FIND
    db " Find next       F3      ", ACT_FINDNEXT
    db " Replace...      Ctrl+R  ", ACT_REPLACE
mi_help:
    db " Keys            F1      ", ACT_KEYS
    db " About mono              ", ACT_ABOUT
MI_LEN   equ 26                     ; длина записи (25 текст + 1 действие)

; строка меню (строка 0)
draw_menubar:
    pusha
    push es
    mov es, [0x10]
    xor di, di
    mov ax, A_MENU * 256 + ' '
    mov cx, 80
    rep stosw
    xor bx, bx
.dm_t:
    cmp bl, MENU_N
    jae .dm_done
    mov al, [menu_x + bx]
    xor ah, ah
    shl ax, 1
    mov di, ax
    push bx
    shl bx, 1
    mov si, [menu_t + bx]
    pop bx
    mov ah, A_MENU
    cmp bl, [menu_open]
    jne .dm_a
    mov ah, A_MSEL
.dm_a:
    call put_str
    ; первая буква — выделить (если меню не открыто)
    cmp byte [menu_open], 0xFF
    jne .dm_n
    mov al, [menu_x + bx]
    xor ah, ah
    inc ax
    shl ax, 1
    mov di, ax
    mov byte [es:di + 1], A_HOT
.dm_n:
    inc bx
    jmp .dm_t
.dm_done:
    mov si, msg_title
    mov di, (80 - 11) * 2
    mov ah, A_MENU
    call put_str
    pop es
    popa
    ret

; меню: AX = номер меню для открытия. -> AL действие (0 = ничего)
menu_run:
    mov [menu_open], al
    mov byte [menu_sel], 0
.mr_loop:
    call ed_render
    call draw_menubar
    call draw_dropdown
    mov cx, 0x2000
    FAPI FAPI_CURSOR
.mr_wait:
    FAPI FAPI_KEYHIT
    jnz .mr_key
    FAPI FAPI_MOUSE
    test ah, ah
    jz .mr_hlt
    test al, 1
    jz .mr_rel
    cmp byte [m_down], 0
    jne .mr_hlt
    mov byte [m_down], 1
    jmp .mr_click
.mr_rel:
    mov byte [m_down], 0
.mr_hlt:
    hlt
    jmp .mr_wait
.mr_click:
    ; строка 0 — другой заголовок; внутри списка — пункт; иначе закрыть
    test dx, dx
    jnz .mr_c1
    call menu_title_at
    jc .mr_close
    mov [menu_open], bl
    mov byte [menu_sel], 0
    jmp .mr_loop
.mr_c1:
    cmp dx, 2
    jb .mr_close
    mov ax, dx
    sub ax, 2
    cmp ax, [dd_n]
    jae .mr_close
    mov bx, [dd_x]
    cmp cx, bx
    jbe .mr_close
    add bx, MI_W
    cmp cx, bx
    jae .mr_close
    mov [menu_sel], al
    jmp .mr_enter
.mr_key:
    FAPI FAPI_GETKEY
    cmp al, 27
    je .mr_close
    cmp al, 13
    je .mr_enter
    test al, al
    jz .mr_ext
    cmp al, 0xE0
    je .mr_ext
    jmp .mr_loop
.mr_ext:
    cmp ah, 0x4B
    je .mr_left
    cmp ah, 0x4D
    je .mr_right
    cmp ah, 0x48
    je .mr_up
    cmp ah, 0x50
    je .mr_down
    cmp ah, 0x44                    ; F10 — закрыть
    je .mr_close
    jmp .mr_loop
.mr_left:
    dec byte [menu_open]
    jns .mr_l1
    mov byte [menu_open], MENU_N - 1
.mr_l1:
    mov byte [menu_sel], 0
    jmp .mr_loop
.mr_right:
    inc byte [menu_open]
    cmp byte [menu_open], MENU_N
    jb .mr_r1
    mov byte [menu_open], 0
.mr_r1:
    mov byte [menu_sel], 0
    jmp .mr_loop
.mr_up:
    mov bl, [menu_open]
    xor bh, bh
    mov cl, [menu_cnt + bx]
    dec byte [menu_sel]
    jns .mr_loop
    dec cl
    mov [menu_sel], cl
    jmp .mr_loop
.mr_down:
    mov bl, [menu_open]
    xor bh, bh
    mov cl, [menu_cnt + bx]
    inc byte [menu_sel]
    cmp [menu_sel], cl
    jb .mr_loop
    mov byte [menu_sel], 0
    jmp .mr_loop
.mr_enter:
    mov bl, [menu_open]
    xor bh, bh
    shl bx, 1
    mov si, [menu_items + bx]
    mov al, [menu_sel]
    mov ah, MI_LEN
    mul ah
    add si, ax
    mov al, [si + MI_LEN - 1]
    mov byte [menu_open], 0xFF
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    ret
.mr_close:
    mov byte [menu_open], 0xFF
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    xor al, al
    ret

; CX = столбец -> BL номер меню, заголовок которого там; CF=1 нет
menu_title_at:
    push ax
    xor bx, bx
.mt_m:
    cmp bl, MENU_N
    jae .mt_no
    mov al, [menu_x + bx]
    xor ah, ah
    cmp cx, ax
    jb .mt_mn
    add al, [menu_w + bx]
    cmp cx, ax
    jb .mt_hit
.mt_mn:
    inc bx
    jmp .mt_m
.mt_hit:
    pop ax
    clc
    ret
.mt_no:
    pop ax
    stc
    ret

; выпадающий список открытого меню
draw_dropdown:
    pusha
    push es
    mov es, [0x10]
    mov bl, [menu_open]
    xor bh, bh
    mov al, [menu_x + bx]
    xor ah, ah
    mov [dd_x], ax
    mov cl, [menu_cnt + bx]
    xor ch, ch
    mov [dd_n], cx
    shl bx, 1
    mov si, [menu_items + bx]
    ; рамка: строка 1 — верх, строки 2.. пункты, низ
    mov dx, 1
    mov ax, [dd_x]
    mov di, ax
    shl di, 1
    add di, 160
    mov ah, A_MENU
    mov al, 0xDA
    stosw
    mov al, 0xC4
    mov cx, MI_W - 1
    rep stosw
    mov al, 0xBF
    stosw
    xor bx, bx                      ; номер пункта
.dd_i:
    cmp bx, [dd_n]
    jae .dd_bot
    add di, 160 - (MI_W + 1) * 2
    mov ah, A_MENU
    mov al, 0xB3
    stosw
    mov ah, A_MENU
    cmp bl, [menu_sel]
    jne .dd_a
    mov ah, A_MSEL
.dd_a:
    mov cx, MI_LEN - 1
.dd_c:
    lodsb
    stosw
    loop .dd_c
    inc si                          ; байт действия
    mov ah, A_MENU
    mov al, 0xB3
    stosw
    inc bx
    jmp .dd_i
.dd_bot:
    add di, 160 - (MI_W + 1) * 2
    mov ah, A_MENU
    mov al, 0xC0
    stosw
    mov al, 0xC4
    mov cx, MI_W - 1
    rep stosw
    mov al, 0xD9
    stosw
    pop es
    popa
    ret

;================================================================ диалоги
DLG_X    equ 10
DLG_W    equ 60
DLG_Y    equ 8

; рамка диалога: DS:SI заголовок, CX высота (внутренних строк). Заливка A_DLG
dlg_frame:
    pusha
    push es
    mov es, [0x10]
    mov [dlg_h], cx
    ; верх
    mov di, DLG_Y * 160 + DLG_X * 2
    mov ah, A_DLG
    mov al, 0xC9
    stosw
    mov al, 0xCD
    mov cx, DLG_W - 2
    rep stosw
    mov al, 0xBB
    stosw
    ; заголовок по центру верхней линии
    push si
    mov di, si
    call str_len                    ; CX
    pop si
    mov ax, DLG_W
    sub ax, cx
    shr ax, 1
    add ax, DLG_X
    shl ax, 1
    add ax, DLG_Y * 160
    mov di, ax
    mov ah, A_DLGT
    call put_str
    ; тело
    mov dx, [dlg_h]
    mov di, (DLG_Y + 1) * 160 + DLG_X * 2
.df_row:
    mov ah, A_DLG
    mov al, 0xBA
    stosw
    mov al, ' '
    mov cx, DLG_W - 2
    rep stosw
    mov al, 0xBA
    stosw
    add di, 160 - DLG_W * 2
    dec dx
    jnz .df_row
    ; низ
    mov ah, A_DLG
    mov al, 0xC8
    stosw
    mov al, 0xCD
    mov cx, DLG_W - 2
    rep stosw
    mov al, 0xBC
    stosw
    pop es
    popa
    ret

; DS:SI текст в строку DL диалога (0-based), столбец 2, атрибут AH
dlg_puts:
    push es
    push di
    push ax
    mov es, [0x10]
    mov al, dl
    mov ah, 160
    mul ah
    add ax, (DLG_Y + 1) * 160 + (DLG_X + 2) * 2
    mov di, ax
    pop ax
    call put_str
    pop di
    pop es
    ret

; ввод строки: DS:SI заголовок, DI буфер (ASCIIZ, может быть заполнен — редактируется).
; -> CF=1 отмена (Esc)
dlg_input:
    mov [inp_ptr], di
    mov [inp_title], si
    mov cx, 3
    call dlg_frame
    mov si, [inp_title]
    mov ah, A_DLG
    mov dl, 0
    call dlg_puts
    mov si, msg_entercancel
    mov dl, 2
    call dlg_puts
    ; длина
    mov di, [inp_ptr]
    call str_len
    mov [inp_len], cx
    mov cx, 0x0607
    FAPI FAPI_CURSOR
.di_loop:
    ; поле
    push es
    mov es, [0x10]
    mov di, (DLG_Y + 2) * 160 + (DLG_X + 2) * 2
    mov ax, A_INP * 256 + ' '
    mov cx, DLG_W - 4
    rep stosw
    mov di, (DLG_Y + 2) * 160 + (DLG_X + 2) * 2
    mov si, [inp_ptr]
    mov ah, A_INP
    call put_str
    pop es
    mov dh, DLG_Y + 2
    mov dx, [inp_len]
    add dl, DLG_X + 2
    mov dh, DLG_Y + 2
    FAPI FAPI_SETCUR
    FAPI FAPI_GETKEY
    cmp al, 27
    je .di_cancel
    cmp al, 13
    je .di_ok
    cmp al, 8
    je .di_bs
    cmp al, 32
    jb .di_loop
    cmp al, 254
    ja .di_loop
    mov bx, [inp_len]
    cmp bx, INP_MAX - 1
    jae .di_loop
    cmp bx, DLG_W - 5
    jae .di_loop
    mov di, [inp_ptr]
    mov [di + bx], al
    inc bx
    mov byte [di + bx], 0
    mov [inp_len], bx
    jmp .di_loop
.di_bs:
    mov bx, [inp_len]
    test bx, bx
    jz .di_loop
    dec bx
    mov di, [inp_ptr]
    mov byte [di + bx], 0
    mov [inp_len], bx
    jmp .di_loop
.di_ok:
    clc
    ret
.di_cancel:
    stc
    ret

; вопрос DS:SI, варианты из msg_yn. -> AL 'Y' / 'N' / 'A' / 27
dlg_yesno:
    push si
    mov si, dlg_qtitle
    mov cx, 3
    call dlg_frame
    pop si
    mov ah, A_DLG
    mov dl, 0
    call dlg_puts
    mov si, msg_yn
    mov dl, 2
    call dlg_puts
    mov cx, 0x2000
    FAPI FAPI_CURSOR
.dy_k:
    FAPI FAPI_GETKEY
    cmp al, 27
    je .dy_r
    and al, 0xDF
    cmp al, 'Y'
    je .dy_r
    cmp al, 'N'
    je .dy_r
    cmp al, 'A'
    je .dy_r
    jmp .dy_k
.dy_r:
    push ax
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    pop ax
    ret

; текстовый диалог: DI заголовок, SI строки (ASCIIZ подряд), CX строк. Ждёт клавишу
dlg_text:
    push si
    push cx
    mov si, di
    add cx, 2
    call dlg_frame
    pop cx
    pop si
    xor dl, dl
.dt_l:
    mov ah, A_DLG
    call dlg_puts                   ; SI -> следующая строка
    inc dl
    loop .dt_l
    inc dl
    mov si, msg_anykey
    mov ah, A_DLGT
    call dlg_puts
    push cx
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    FAPI FAPI_GETKEY
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    pop cx
    ret

;================================================================ редактирование
; курсор на строку вверх с сохранением колонки
ed_move_up:
    push ax
    push bx
    push dx
    mov ax, [ed_cur]
    call ed_line_start              ; AX = начало текущей строки
    test ax, ax
    jz .mu_ret
    mov bx, [ed_cur]
    sub bx, ax                      ; BX = колонка
    mov dx, ax
    dec dx                          ; DX = индекс LF предыдущей строки
    dec ax
    call ed_line_start              ; AX = начало предыдущей строки
    add ax, bx
    cmp ax, dx
    jbe .mu_set
    mov ax, dx
.mu_set:
    mov [ed_cur], ax
.mu_ret:
    pop dx
    pop bx
    pop ax
    ret

ed_move_down:
    push ax
    push bx
    push dx
    mov ax, [ed_cur]
    call ed_line_start
    mov bx, [ed_cur]
    sub bx, ax                      ; BX = колонка
    mov ax, [ed_cur]
    call ed_next_line               ; AX = начало следующей строки
    jc .md_ret
    mov dx, ax
    call ed_line_end                ; AX = конец следующей строки
    add dx, bx
    cmp dx, ax
    jbe .md_set
    mov dx, ax
.md_set:
    mov [ed_cur], dx
.md_ret:
    pop dx
    pop bx
    pop ax
    ret

; вставить AL в позицию курсора
ed_insert:
    push ax
    push cx
    push si
    push di
    mov cx, [ed_len]
    cmp cx, ED_MAX
    jae .ei_full
    sub cx, [ed_cur]                ; сколько байт сдвинуть
    jcxz .ei_store
    mov di, ed_buf
    add di, [ed_len]
    mov si, di
    dec si
    std
    rep movsb
    cld
.ei_store:
    mov di, ed_buf
    add di, [ed_cur]
    stosb
    inc word [ed_cur]
    inc word [ed_len]
    mov byte [ed_dirty], 1
    jmp .ei_ret
.ei_full:
    mov si, msg_full
    call ed_status
.ei_ret:
    pop di
    pop si
    pop cx
    pop ax
    ret

; удалить символ под курсором (если ed_cur < ed_len)
ed_delete:
    push ax
    push cx
    push si
    push di
    mov ax, [ed_cur]
    cmp ax, [ed_len]
    jae .dd_r
    mov di, ed_buf
    add di, ax
    mov si, di
    inc si
    mov cx, [ed_len]
    sub cx, ax
    dec cx
    rep movsb
    dec word [ed_len]
    mov byte [ed_dirty], 1
.dd_r:
    pop di
    pop si
    pop cx
    pop ax
    ret

; AX = индекс -> AX = начало строки, содержащей индекс
ed_line_start:
    push si
.ls_loop:
    test ax, ax
    jz .ls_ret
    mov si, ax
    cmp byte [ed_buf + si - 1], 10
    je .ls_ret
    dec ax
    jmp .ls_loop
.ls_ret:
    pop si
    ret

; AX = индекс -> AX = индекс LF этой строки (или ed_len)
ed_line_end:
    push si
    mov si, ax
.le_loop:
    cmp si, [ed_len]
    jae .le_ret
    cmp byte [ed_buf + si], 10
    je .le_ret
    inc si
    jmp .le_loop
.le_ret:
    mov ax, si
    pop si
    ret

; AX = индекс -> AX = начало следующей строки; CF=1, если её нет
ed_next_line:
    call ed_line_end
    cmp ax, [ed_len]
    jae .nl_none
    inc ax
    clc
    ret
.nl_none:
    stc
    ret

; -> AX = строка курсора относительно ed_top, DX = колонка (абсолютная)
ed_cursor_pos:
    push bx
    push cx
    push si
    mov si, [ed_top]
    mov bx, si
    xor ax, ax
    mov cx, [ed_cur]
.cp_loop:
    cmp si, cx
    jae .cp_done
    cmp byte [ed_buf + si], 10
    jne .cp_next
    inc ax
    mov bx, si
    inc bx
.cp_next:
    inc si
    jmp .cp_loop
.cp_done:
    mov dx, cx
    sub dx, bx
    pop si
    pop cx
    pop bx
    ret

; -> AX номер строки курсора (с 1)
ed_line_no:
    push cx
    push si
    xor si, si
    mov cx, [ed_cur]
    mov ax, 1
.ln_l:
    cmp si, cx
    jae .ln_d
    cmp byte [ed_buf + si], 10
    jne .ln_n
    inc ax
.ln_n:
    inc si
    jmp .ln_l
.ln_d:
    pop si
    pop cx
    ret

; подогнать ed_top/ed_left так, чтобы курсор был виден
ed_adjust:
    push ax
    push dx
.ad_back:
    mov ax, [ed_cur]
    cmp ax, [ed_top]
    jae .ad_fwd
    mov ax, [ed_top]
    dec ax
    call ed_line_start
    mov [ed_top], ax
    jmp .ad_back
.ad_fwd:
    call ed_cursor_pos
    cmp ax, TXT_ROWS
    jb .ad_h
    mov ax, [ed_top]
    call ed_next_line
    mov [ed_top], ax
    jmp .ad_fwd
.ad_h:
    ; горизонталь: DX = колонка
    cmp dx, [ed_left]
    jae .ad_h2
    mov [ed_left], dx
    jmp .ad_done
.ad_h2:
    mov ax, dx
    sub ax, [ed_left]
    cmp ax, 80
    jb .ad_done
    sub dx, 79
    mov [ed_left], dx
.ad_done:
    pop dx
    pop ax
    ret

ed_place_cursor:
    push ax
    push dx
    call ed_cursor_pos
    mov dh, al
    add dh, TXT_Y
    sub dx, [ed_left]
    FAPI FAPI_SETCUR
    pop dx
    pop ax
    ret

; отрисовать строки текста из буфера начиная с ed_top, со сдвигом ed_left
ed_render:
    pusha
    push es
    mov si, ed_buf
    add si, [ed_top]
    mov bp, ed_buf
    add bp, [ed_len]
    mov es, [0x10]                  ; сегмент видеопамяти (B800h или окно GUI)
    mov di, TXT_Y * 160
    mov dh, TXT_ROWS
.rd_row:
    ; пропустить ed_left символов строки
    mov cx, [ed_left]
.rd_sk:
    jcxz .rd_vis
    cmp si, bp
    jae .rd_vis
    cmp byte [si], 10
    je .rd_vis
    inc si
    dec cx
    jmp .rd_sk
.rd_vis:
    mov cx, 80
.rd_col:
    cmp si, bp
    jae .rd_pad
    lodsb
    cmp al, 10
    je .rd_pad
    mov ah, A_TEXT
    stosw
    loop .rd_col
.rd_skip:                           ; строка длиннее — пропустить хвост
    cmp si, bp
    jae .rd_next
    lodsb
    cmp al, 10
    jne .rd_skip
    jmp .rd_next
.rd_pad:
    jcxz .rd_next
    mov ax, A_TEXT * 256 + ' '
    rep stosw
.rd_next:
    dec dh
    jnz .rd_row
    pop es
    popa
    ret

;================================================================ строка состояния
; сообщение SI показать в строке состояния (до следующей клавиши)
ed_status:
    mov [st_msg], si
    ret

; сообщение SI + numbuf
ed_status_num:
    push si
    push di
    push es
    push ds
    pop es
    mov di, st_buf
    call str_copy
    mov si, numbuf
    call str_copy
    pop es
    pop di
    pop si
    mov word [st_msg], st_buf
    ret

draw_statbar:
    pusha
    push es
    mov es, [0x10]
    mov di, STAT_Y * 160
    mov ax, A_STAT * 256 + ' '
    mov cx, 80
    rep stosw
    mov di, STAT_Y * 160 + 2
    mov ah, A_STAT
    mov si, fname
    cmp byte [fname], 0
    jne .sb_n
    mov si, msg_untitled
.sb_n:
    call put_str
    cmp byte [ed_dirty], 0
    je .sb_c
    mov si, msg_mod
    call put_str
.sb_c:
    ; Ln / Col / размер — справа
    mov di, STAT_Y * 160 + 40 * 2
    mov si, msg_ln
    call put_str
    call ed_line_no
    call put_dec
    mov si, msg_col
    call put_str
    push di
    call ed_cursor_pos
    mov ax, dx
    inc ax
    pop di
    call put_dec
    mov si, msg_bytes
    call put_str
    mov ax, [ed_len]
    call put_dec
    mov si, msg_b
    call put_str
    ; сообщение (если есть) — поверх левой части после имени
    mov si, [st_msg]
    test si, si
    jz .sb_done
    mov di, STAT_Y * 160 + 2
    mov ax, A_MSG * 256 + ' '
    mov cx, 38
    rep stosw
    mov di, STAT_Y * 160 + 2
    mov ah, A_MSG
    call put_str
.sb_done:
    pop es
    popa
    ret

;================================================================ утилиты
; ES:DI <- строка DS:SI с атрибутом AH
put_str:
    lodsb
    test al, al
    jz .ps_ret
    stosw
    jmp put_str
.ps_ret:
    ret

; AX десятичное -> ES:DI с атрибутом AH (AH сохраняется)
put_dec:
    push ax
    push si
    push di
    mov di, numbuf
    call fmt_dec
    pop di
    pop si
    pop ax
    push si
    mov si, numbuf
    mov ah, A_STAT
    call put_str
    pop si
    ret

; AX -> ASCIIZ десятичное в DS:DI
fmt_dec:
    push ax
    push bx
    push cx
    push dx
    push di
    mov bx, 10
    xor cx, cx
.fd_d:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .fd_d
.fd_o:
    pop ax
    add al, '0'
    mov [di], al
    inc di
    loop .fd_o
    mov byte [di], 0
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; DS:SI десятичная строка -> AX
parse_dec:
    xor ax, ax
    xor cx, cx
.pd_l:
    mov cl, [si]
    sub cl, '0'
    cmp cl, 9
    ja .pd_d
    mov bx, 10
    mul bx
    add ax, cx
    inc si
    jmp .pd_l
.pd_d:
    ret

; длина строки DS:DI -> CX
str_len:
    push di
    xor cx, cx
.sl_l:
    cmp byte [di], 0
    je .sl_d
    inc di
    inc cx
    jmp .sl_l
.sl_d:
    pop di
    ret

; DS:SI -> DS:DI (ASCIIZ), DI остаётся на нуле
str_copy:
    push es
    push ds
    pop es
.sc_l:
    lodsb
    stosb
    test al, al
    jnz .sc_l
    dec di
    pop es
    ret

;---------------- данные ----------------
ed_len      dw 0
ed_cur      dw 0
ed_top      dw 0
ed_left     dw 0
ed_dirty    db 0
ld_path     dw 0
st_msg      dw 0
menu_open   db 0xFF
menu_sel    db 0
m_down      db 0
m_quit      db 0
dd_x        dw 0
dd_n        dw 0
dlg_h       dw 0
inp_ptr     dw 0
inp_title   dw 0
inp_len     dw 0
clip_len    dw 0
repl_cnt    dw 0
repl_all    db 0
sv_first    db 0

msg_title   db " mono 2.0 ", 0
msg_hint    db "F10 menu  F1 keys  Esc exit", 0
msg_untitled db "[untitled]", 0
msg_mod     db " *", 0
msg_ln      db "Ln ", 0
msg_col     db "  Col ", 0
msg_bytes   db "  ", 0
msg_b       db " bytes", 0
msg_toobig  db "File too large (max 56000 bytes)", 0
msg_ioerr   db "Disk I/O error", 0
msg_loaded  db "Loaded.", 0
msg_newfile db "New file.", 0
msg_newbuf  db "New buffer.", 0
msg_saved   db "Saved.", 0
msg_saveerr db "Save failed! (disk full or bad path)", 0
msg_full    db "Buffer full (56000 bytes)", 0
msg_copied  db "Line copied.", 0
msg_cut     db "Line cut.", 0
msg_notfound db "Not found.", 0
msg_replaced db "Replaced: ", 0
msg_entercancel db "Enter = OK   Esc = cancel", 0
msg_yn      db "Y = yes   N = no   A = all   Esc = cancel", 0
msg_anykey  db " press any key ", 0
dlg_open    db "File name to open:", 0
dlg_saveas  db "Save as (file name):", 0
dlg_goto    db "Go to line number:", 0
dlg_find    db "Find text:", 0
dlg_repl    db "Replace with:", 0
dlg_replq   db "Replace this occurrence?", 0
dlg_unsaved db "Save changes before continuing?", 0
dlg_qtitle  db " Question ", 0
dlg_keys    db " Keys ", 0
dlg_about   db " About ", 0

HELP_N equ 10
help_lines:
    db "Arrows Home End PgUp PgDn   move (Ctrl+Home/End = text)", 0
    db "Ctrl+S save   F2 save as   Ctrl+O open   Ctrl+N new", 0
    db "Ctrl+X cut line  Ctrl+C copy line  Ctrl+V paste line", 0
    db "Ctrl+Y delete line   Ctrl+G go to line", 0
    db "Ctrl+F find   F3 find next   Ctrl+R replace", 0
    db "Tab = 4 spaces   Del / Backspace delete", 0
    db "F10 menu (arrows, Enter)   mouse: menu, set cursor", 0
    db "Esc exit (asks to save)   Ctrl+Q quit without saving", 0
    db "Long lines scroll horizontally.", 0
    db "File is stored with CR LF, max 56000 bytes.", 0
ABOUT_N equ 4
about_lines:
    db "mono 2.0 - text editor for FERRIX-OS", 0
    db "Menu bar, dialogs, find/replace, line clipboard.", 0
    db "Written in 16-bit assembly (8086), runs in text", 0
    db "mode and inside the gui window manager.", 0

fname       times 64 db 0
inp_buf     times INP_MAX db 0
find_str    times INP_MAX db 0
repl_str    times INP_MAX db 0
numbuf      times 8 db 0
st_buf      times 48 db 0
clip        times CLIP_MAX db 0
sv_buf:     times SV_CHUNK db 0

ed_buf:                             ; текст — до конца сегмента
