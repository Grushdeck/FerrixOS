;======================================
; File name: apps/fm.asm
; Project: FERRIX-OS
; Description: fm — двухпанельный файловый менеджер (программа .FAP, API v3)
;======================================
; Клавиши: Tab панель, стрелки/PgUp/PgDn/Home/End, Enter войти/запустить/просмотр,
; Backspace вверх, Ins/Space пометить, +/- все, F1 помощь, F2 переименовать,
; F3 просмотр, F4 править (mono), Shift+F4 новый файл, F5 копировать,
; F6 переместить, F7 каталог, F8/Del удалить, Ctrl+R обновить, F10/Esc выход.
; Мышь: клик — выбрать, второй клик по выбранному — Enter, правый — пометить,
; клик по нижней строке — F-клавиша.
; Состояние (пути панелей, курсоры) хранится в /SYSTEM/FM.CFG, поэтому после
; запуска программы/редактора (EXEC-цепочка) fm возвращается туда же.

%include "fapi.inc"

    FAPI_HEADER
    jmp start

; ---- раскладка памяти сегмента программы ----
LIST0    equ 0x3000                 ; записи панели 0 (32 байта × 256)
LIST1    equ 0x5000
MARK0    equ 0x2E00                 ; пометки (1 байт на запись)
MARK1    equ 0x2F00
VIEWBUF  equ 0x7000                 ; буфер просмотра
VIEWMAX  equ 0x8000
MAXE     equ 256
ROWS     equ 19                     ; строк в списке
; ---- структура панели ----
P_PATH   equ 0                      ; 64 байта, без завершающего '/', "" = корень
P_CNT    equ 64
P_SEL    equ 66
P_TOP    equ 68
P_LIST   equ 70
P_MARK   equ 72
P_SIZE   equ 80
; ---- цвета ----
A_NORM   equ 0x1B
A_DIR    equ 0x1F
A_SEL    equ 0x30
A_MRK    equ 0x1E
A_MSEL   equ 0x3E
A_FRM    equ 0x1B
A_AFRM   equ 0x1E                   ; рамка активной панели
A_BAR    equ 0x30
A_KEY    equ 0x07
A_MSG    equ 0x0E
A_INP    equ 0x70

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    FAPI FAPI_CLS
    call state_load
    call rescan_all
    mov cl, 1
    FAPI FAPI_MOUSESHOW
main_loop:
    call draw_all
.wait:
    FAPI FAPI_KEYHIT
    jnz .key
    call mouse_poll
    jc main_loop                    ; было действие мыши — перерисовать
    hlt
    jmp .wait
.key:
    FAPI FAPI_GETKEY
    call handle_key
    jmp main_loop

;---------------------------------------------------------------- клавиши
handle_key:
    cmp al, 9
    je k_tab
    cmp al, 27
    je k_quit
    cmp al, 13
    je k_enter
    cmp al, 8
    je k_parent
    cmp al, ' '
    je k_mark
    cmp al, '+'
    je k_mark_all
    cmp al, '-'
    je k_unmark_all
    cmp al, 0x12                    ; Ctrl+R
    je k_refresh
    test al, al
    jz .ext
    cmp al, 0xE0
    jne .none
.ext:
    cmp ah, 0x48
    je k_up
    cmp ah, 0x50
    je k_down
    cmp ah, 0x49
    je k_pgup
    cmp ah, 0x51
    je k_pgdn
    cmp ah, 0x47
    je k_home
    cmp ah, 0x4F
    je k_end
    cmp ah, 0x4B
    je k_left
    cmp ah, 0x4D
    je k_right
    cmp ah, 0x52
    je k_mark                       ; Ins
    cmp ah, 0x53
    je k_delete                     ; Del
    cmp ah, 0x3B
    je k_help
    cmp ah, 0x3C
    je k_rename
    cmp ah, 0x3D
    je k_view
    cmp ah, 0x3E
    je k_edit
    cmp ah, 0x57                    ; Shift+F4
    je k_newfile
    cmp ah, 0x43                    ; F9
    je k_newfile
    cmp ah, 0x3F
    je k_copy
    cmp ah, 0x40
    je k_move
    cmp ah, 0x41
    je k_mkdir
    cmp ah, 0x42
    je k_delete
    cmp ah, 0x44
    je k_quit
.none:
    ret

k_tab:
    xor byte [active], 1
    ret
k_left:
    mov byte [active], 0
    ret
k_right:
    mov byte [active], 1
    ret
k_up:
    call cur_panel
    cmp word [bx + P_SEL], 0
    je .r
    dec word [bx + P_SEL]
.r: jmp fix_top
k_down:
    call cur_panel
    mov ax, [bx + P_SEL]
    inc ax
    cmp ax, [bx + P_CNT]
    jae .r
    mov [bx + P_SEL], ax
.r: jmp fix_top
k_pgup:
    call cur_panel
    mov ax, [bx + P_SEL]
    sub ax, ROWS
    jns .ok
    xor ax, ax
.ok:
    mov [bx + P_SEL], ax
    jmp fix_top
k_pgdn:
    call cur_panel
    mov ax, [bx + P_SEL]
    add ax, ROWS
    cmp ax, [bx + P_CNT]
    jb .ok
    mov ax, [bx + P_CNT]
    dec ax
.ok:
    mov [bx + P_SEL], ax
    jmp fix_top
k_home:
    call cur_panel
    mov word [bx + P_SEL], 0
    jmp fix_top
k_end:
    call cur_panel
    mov ax, [bx + P_CNT]
    dec ax
    mov [bx + P_SEL], ax
    jmp fix_top
; прокрутка так, чтобы P_SEL был виден
fix_top:
    call cur_panel
    mov ax, [bx + P_SEL]
    cmp ax, [bx + P_TOP]
    jae .n1
    mov [bx + P_TOP], ax
.n1:
    mov ax, [bx + P_TOP]
    add ax, ROWS
    cmp [bx + P_SEL], ax
    jb .n2
    mov ax, [bx + P_SEL]
    sub ax, ROWS - 1
    mov [bx + P_TOP], ax
.n2:
    ret

k_mark:
    call cur_entry                  ; SI -> запись, DI -> пометка; CF если пусто
    jc .r
    cmp byte [si], '.'
    je .r
    xor byte [di], 1
.r: jmp k_down
k_mark_all:
    mov al, 1
    jmp mark_set
k_unmark_all:
    xor al, al
mark_set:
    call cur_panel
    mov di, [bx + P_MARK]
    mov cx, [bx + P_CNT]
    mov si, [bx + P_LIST]
.l:
    jcxz .r
    cmp byte [si], '.'
    je .skip
    mov [di], al
.skip:
    add si, 32
    inc di
    dec cx
    jmp .l
.r: ret

k_refresh:
    call rescan_all
    ret

k_quit:
    call state_save
    call cur_panel
    lea si, [bx + P_PATH]
    cmp byte [si], 0
    jne .cd
    mov si, s_root
.cd:
    FAPI FAPI_CHDIR                 ; выход — в каталог активной панели
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

k_parent:
    call cur_panel
    cmp byte [bx + P_PATH], 0
    je .r
    call path_up
    call rescan_cur
.r: ret

k_enter:
    call cur_entry
    jc .r
    test byte [si + 11], 0x10
    jz .file
    ; каталог
    cmp byte [si], '.'
    jne .sub
    cmp byte [si + 1], '.'
    je k_parent
    ret                             ; "."
.sub:
    call cur_panel
    call path_down                  ; путь панели += "/" + имя SI
    call rescan_cur
    ret
.file:
    ; .FAP — запустить, .SH — выполнить, иначе просмотр
    cmp word [si + 8], 'FA'
    jne .sh
    cmp byte [si + 10], 'P'
    jne .sh
    mov di, s_run
    jmp .exec
.sh:
    mov byte [exec_pause], 1
    cmp word [si + 8], 'SH'
    jne .bmp
    cmp byte [si + 10], ' '
    jne .bmp
    mov di, s_sh
    jmp .exec
.bmp:
    mov byte [exec_pause], 0        ; view/play сами ждут и ничего не оставляют на экране
    cmp word [si + 8], 'BM'
    jne .wav
    cmp byte [si + 10], 'P'
    jne .wav
    mov di, s_viewcmd
    jmp .exec
.wav:
    cmp word [si + 8], 'WA'
    jne .ch8
    cmp byte [si + 10], 'V'
    jne .ch8
    mov di, s_playcmd
    jmp .exec
.ch8:
    cmp word [si + 8], 'CH'
    jne k_view
    cmp byte [si + 10], '8'
    jne k_view
    mov di, s_microcmd
.exec:
    call build_cmd_sel              ; cmdbuf = DI + путь выбранного
    call state_save
    FAPI FAPI_CLS
    mov si, cmdbuf
    mov dl, [exec_pause]
    FAPI FAPI_EXEC
    FAPI_QUIT                       ; выход; ядро выполнит команду и перезапустит fm
.r: ret

k_edit:
    call cur_entry
    jc .r
    test byte [si + 11], 0x10
    jnz .r
    mov di, s_mono
    call build_cmd_sel
    call state_save
    mov si, cmdbuf
    xor dl, dl
    FAPI FAPI_EXEC
    FAPI_QUIT
.r: ret

k_newfile:
    mov si, p_newfile
    call input_line                 ; -> inbuf, CF=Esc
    jc .r
    mov di, s_touch
    call build_cmd_in               ; cmdbuf = "touch " + путь панели + "/" + inbuf
    call run_shell
    call rescan_all
    ; сразу открыть в редакторе
    mov di, s_mono
    call build_cmd_in
    call state_save
    mov si, cmdbuf
    xor dl, dl
    FAPI FAPI_EXEC
    FAPI_QUIT
.r: ret

k_mkdir:
    mov si, p_mkdir
    call input_line
    jc .r
    mov di, s_mkdir
    call build_cmd_in
    call run_shell
    call rescan_all
.r: ret

k_rename:
    call cur_entry
    jc .r
    cmp byte [si], '.'
    je .r
    mov si, p_rename
    call input_line
    jc .r
    mov di, s_rename
    call build_cmd_sel
    mov di, cmdbuf
    call str_end
    mov al, ' '
    stosb
    mov si, inbuf
    call str_copy
    call run_shell
    call rescan_all
.r: ret

k_delete:
    call marked_count
    test ax, ax
    jnz .grp
    call cur_entry
    jc .r
    cmp byte [si], '.'
    je .r
.grp:
    mov si, p_delete
    call confirm
    jc .r
    mov si, s_rm
    call group_op
    call rescan_all
.r: ret

k_copy:
    mov si, s_cp
    jmp cp_mv
k_move:
    mov si, s_mv
cp_mv:
    push si
    call marked_count
    test ax, ax
    jnz .go
    call cur_entry
    jc .no
    cmp byte [si], '.'
    je .no
.go:
    pop si
    call group_op
    call rescan_all
    ret
.no:
    pop si
    ret

; Групповая операция SI -> "cp "/"mv "/"rm ": для каждой помеченной (или текущей)
; записи выполняется команда; cp/mv — с путём другой панели
group_op:
    mov [opcmd], si
    call marked_count
    test ax, ax
    jnz .marked
    call cur_entry
    jc .r
    call one_op
    ret
.marked:
    call cur_panel
    mov si, [bx + P_LIST]
    mov di, [bx + P_MARK]
    mov cx, [bx + P_CNT]
.l:
    jcxz .r
    cmp byte [di], 0
    je .next
    push cx
    push si
    push di
    call one_op
    pop di
    pop si
    pop cx
    mov byte [di], 0
.next:
    add si, 32
    inc di
    dec cx
    jmp .l
.r: ret

; одна операция над записью SI (opcmd)
one_op:
    push si
    mov di, [opcmd]
    call build_cmd_entry            ; cmdbuf = opcmd + путь активной панели/имя
    pop si
    mov di, [opcmd]
    cmp byte [di], 'r'
    je .go
    mov di, cmdbuf
    call str_end
    mov al, ' '
    stosb
    call other_panel
    lea si, [bx + P_PATH]
    cmp byte [si], 0
    jne .cp
    mov si, s_root
.cp:
    call str_copy
.go:
    call run_shell
    ret

k_help:
    FAPI FAPI_CLS
    mov si, help_txt
    FAPI FAPI_PUTS
    FAPI FAPI_GETKEY
    ret

k_view:
    call cur_entry
    jc .r
    test byte [si + 11], 0x10
    jnz .r
    call viewer
.r: ret

;---------------------------------------------------------------- мышь
; CF=1 если было действие (нужна перерисовка)
mouse_poll:
    FAPI FAPI_MOUSE
    test ah, ah
    jz .none
    mov bl, al
    xor bl, [mbtn_prev]
    and bl, al                      ; нажатые только что
    mov [mbtn_prev], al
    mov [mbtn_new], bl
    test bl, 3
    jz .none
    ; клик
    cmp dx, 24
    je .keybar
    cmp dx, 1
    jb .none
    cmp dx, ROWS
    ja .none
    ; панель по столбцу
    xor al, al
    cmp cx, 40
    jb .p
    inc al
    sub cx, 40
.p:
    cmp cx, 1
    jb .none
    cmp cx, 38
    ja .none
    cmp al, [active]
    je .same
    mov [active], al
.same:
    call cur_panel
    mov ax, dx
    dec ax
    add ax, [bx + P_TOP]
    cmp ax, [bx + P_CNT]
    jae .act
    test byte [mbtn_new], 2
    jz .left
    mov [bx + P_SEL], ax
    call cur_entry
    jc .act
    cmp byte [si], '.'
    je .act
    xor byte [di], 1
    jmp .act
.left:
    cmp ax, [bx + P_SEL]
    jne .select
    ; повторный клик по выбранному = Enter (в пределах ~0.5 с)
    push ax
    FAPI FAPI_TICKS
    mov cx, ax
    sub ax, [mclick_tick]
    mov [mclick_tick], cx
    pop cx
    cmp ax, 9
    ja .act
    call k_enter
    jmp .act
.select:
    mov [bx + P_SEL], ax
    FAPI FAPI_TICKS
    mov [mclick_tick], ax
.act:
    stc
    ret
.keybar:
    mov ax, cx
    mov cl, 3
    shr ax, cl                      ; 8 столбцов на клавишу
    cmp ax, 9
    ja .none
    mov bx, ax
    mov ah, [keybar_scan + bx]
    xor al, al
    call handle_key
    stc
    ret
.none:
    clc
    ret

;---------------------------------------------------------------- панели
; BX -> активная панель
cur_panel:
    mov bx, panel0
    cmp byte [active], 0
    je .r
    mov bx, panel1
.r: ret
other_panel:
    mov bx, panel1
    cmp byte [active], 0
    je .r
    mov bx, panel0
.r: ret
; SI -> текущая запись активной панели, DI -> её пометка. CF=1 если панель пуста
cur_entry:
    call cur_panel
    mov ax, [bx + P_CNT]
    test ax, ax
    jz .empty
    mov ax, [bx + P_SEL]
    mov di, [bx + P_MARK]
    add di, ax
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    mov si, [bx + P_LIST]
    add si, ax
    clc
    ret
.empty:
    stc
    ret
; AX = число помеченных в активной панели
marked_count:
    call cur_panel
    mov di, [bx + P_MARK]
    mov cx, [bx + P_CNT]
    xor ax, ax
.l:
    jcxz .r
    cmp byte [di], 0
    je .n
    inc ax
.n:
    inc di
    dec cx
    jmp .l
.r: ret

rescan_all:
    mov bx, panel0
    call scan_panel
    mov bx, panel1
    call scan_panel
    ret
rescan_cur:
    call cur_panel
    call scan_panel
    ret

; прочитать каталог панели BX, отсортировать, сбросить пометки
scan_panel:
    push bx
    lea si, [bx + P_PATH]
    cmp byte [si], 0
    jne .rd
    mov si, s_root
.rd:
    mov di, [bx + P_LIST]
    mov cx, MAXE
    FAPI FAPI_READDIR
    jnc .ok
    ; каталог пропал — в корень
    mov byte [bx + P_PATH], 0
    mov si, s_root
    mov di, [bx + P_LIST]
    mov cx, MAXE
    FAPI FAPI_READDIR
    jnc .ok
    xor ax, ax
.ok:
    mov [bx + P_CNT], ax
    ; пометки сбросить
    mov di, [bx + P_MARK]
    mov cx, MAXE
    push ax
    xor al, al
    rep stosb
    pop ax
    call sort_list
    ; курсор в пределах
    mov ax, [bx + P_CNT]
    test ax, ax
    jnz .c1
    mov word [bx + P_SEL], 0
    mov word [bx + P_TOP], 0
    jmp .done
.c1:
    cmp [bx + P_SEL], ax
    jb .c2
    dec ax
    mov [bx + P_SEL], ax
.c2:
    mov ax, [bx + P_TOP]
    cmp ax, [bx + P_SEL]
    jbe .done
    mov word [bx + P_TOP], 0
.done:
    pop bx
    ret

; сортировка списка панели BX: сначала "..", затем каталоги, затем файлы, по имени (вставками)
sort_list:
    push bx
    mov cx, [bx + P_CNT]
    cmp cx, 2
    jb .r
    mov bp, [bx + P_LIST]
    mov dx, 1                       ; i
.outer:
    cmp dx, cx
    jae .r
    ; скопировать запись i во временный
    mov ax, dx
    call ent_off
    mov si, ax
    mov di, tmpent
    push cx
    mov cx, 32
    rep movsb
    pop cx
    mov bx, dx                      ; j = i
.inner:
    test bx, bx
    jz .place
    mov ax, bx
    dec ax
    call ent_off
    mov si, ax                      ; запись j-1
    mov di, tmpent
    call ent_less                   ; CF=1 если tmp < [j-1]
    jnc .place
    ; сдвинуть j-1 -> j
    mov ax, bx
    call ent_off
    mov di, ax
    push cx
    mov cx, 32
    rep movsb
    pop cx
    dec bx
    jmp .inner
.place:
    mov ax, bx
    call ent_off
    mov di, ax
    mov si, tmpent
    push cx
    mov cx, 32
    rep movsb
    pop cx
    inc dx
    jmp .outer
.r:
    pop bx
    ret
; AX = bp + AX*32
ent_off:
    push cx
    mov cl, 5
    shl ax, cl
    add ax, bp
    pop cx
    ret
; CF=1 если запись DI < записи SI (ранг: "." и ".." < каталог < файл, затем имя)
ent_less:
    push si
    push di
    call ent_rank                   ; AL = ранг DI
    mov ah, al
    xchg si, di
    call ent_rank                   ; AL = ранг SI (исходной)
    xchg si, di
    cmp ah, al
    jb .less
    ja .nless
    push cx
    mov cx, 11
    repe cmpsb                      ; [SI]=[j-1] ? [DI]=tmp
    pop cx
    ja .less
.nless:
    pop di
    pop si
    clc
    ret
.less:
    pop di
    pop si
    stc
    ret
ent_rank:
    cmp byte [di], '.'
    jne .nd
    xor al, al
    ret
.nd:
    test byte [di + 11], 0x10
    jz .f
    mov al, 1
    ret
.f: mov al, 2
    ret

;---------------------------------------------------------------- пути
; путь панели BX: подняться на уровень
path_up:
    lea di, [bx + P_PATH]
    mov si, di
    call str_end                    ; DI -> ноль
.l:
    cmp di, si
    je .done
    dec di
    cmp byte [di], '/'
    jne .l
.done:
    mov byte [di], 0
    mov word [bx + P_SEL], 0
    mov word [bx + P_TOP], 0
    ret
; путь панели BX += "/" + имя записи SI
path_down:
    push si
    lea di, [bx + P_PATH]
    call str_end
    mov ax, di
    sub ax, bx
    cmp ax, 50
    ja .r                           ; слишком глубоко
    mov al, '/'
    stosb
    pop si
    push si
    call name_to_str                ; SI запись -> DI ASCIIZ
    mov word [bx + P_SEL], 0
    mov word [bx + P_TOP], 0
.r:
    pop si
    ret
; запись FAT SI -> ASCIIZ в DI (DI остаётся на нуле)
name_to_str:
    push si
    push cx
    mov cx, 8
.n:
    lodsb
    cmp al, ' '
    je .ns
    stosb
.ns:
    loop .n
    cmp byte [si], ' '
    je .t
    mov al, '.'
    stosb
    mov cx, 3
.e:
    lodsb
    cmp al, ' '
    je .es
    stosb
.es:
    loop .e
.t:
    mov byte [di], 0
    pop cx
    pop si
    ret
; DI -> конец строки (на нуле)
str_end:
    cmp byte [di], 0
    je .r
    inc di
    jmp str_end
.r: ret
; скопировать ASCIIZ SI -> DI (DI остаётся на нуле)
str_copy:
    lodsb
    stosb
    test al, al
    jnz str_copy
    dec di
    ret
; cmdbuf = DI(команда) + путь активной панели + "/" + имя текущей записи
build_cmd_sel:
    push di
    call cur_entry
    pop di
build_cmd_entry:                    ; SI = запись
    push si
    mov si, di
    mov di, cmdbuf
    call str_copy
    call put_panel_path
    pop si
    call name_to_str
    ret
; cmdbuf = DI(команда) + путь активной панели + "/" + inbuf
build_cmd_in:
    mov si, di
    mov di, cmdbuf
    call str_copy
    call put_panel_path
    mov si, inbuf
    call str_copy
    ret
; в DI: путь активной панели + "/"
put_panel_path:
    call cur_panel
    lea si, [bx + P_PATH]
    call str_copy
    mov al, '/'
    stosb
    mov byte [di], 0
    ret

;---------------------------------------------------------------- оболочка
; выполнить cmdbuf через ядро; вывод — в строку сообщений
run_shell:
    mov dh, 22
    mov dl, 0
    mov ch, 2
    mov cl, 80
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    mov dh, 22
    mov dl, 0
    FAPI FAPI_SETCUR
    mov si, cmdbuf
    FAPI FAPI_SHELL
    ret

;---------------------------------------------------------------- ввод
; строка ввода в 23-й строке: SI подсказка -> inbuf; CF=1 если Esc/пусто
input_line:
    push si
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    mov dh, 23
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_INP
    FAPI FAPI_FILLRECT
    pop si
    mov dh, 23
    mov dl, 1
    mov bl, A_INP
    FAPI FAPI_PUTSAT
    ; длина подсказки -> DL
    mov dl, 1
.pl:
    lodsb
    test al, al
    jz .pd
    inc dl
    jmp .pl
.pd:
    mov [in_col], dl
    mov di, inbuf
    xor cx, cx                      ; длина
.loop:
    mov dh, 23
    mov dl, [in_col]
    add dl, cl
    FAPI FAPI_SETCUR
    FAPI FAPI_GETKEY
    cmp al, 27
    je .esc
    cmp al, 13
    je .enter
    cmp al, 8
    je .bs
    cmp al, ' '
    jbe .loop
    cmp cl, 40
    jae .loop
    mov [di], al
    inc di
    inc cl
    push ax
    mov dh, 23
    mov dl, [in_col]
    add dl, cl
    dec dl
    mov bl, A_INP
    FAPI FAPI_PUTAT
    pop ax
    jmp .loop
.bs:
    test cl, cl
    jz .loop
    dec cl
    dec di
    mov dh, 23
    mov dl, [in_col]
    add dl, cl
    mov al, ' '
    mov bl, A_INP
    FAPI FAPI_PUTAT
    jmp .loop
.enter:
    mov byte [di], 0
    test cl, cl
    jz .esc
    call input_done
    clc
    ret
.esc:
    call input_done
    stc
    ret
input_done:
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov dh, 23
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, 0x07
    FAPI FAPI_FILLRECT
    ret
; подтверждение: SI вопрос -> CF=1 если не 'y'/Enter
confirm:
    push si
    mov dh, 23
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_INP
    FAPI FAPI_FILLRECT
    pop si
    mov dh, 23
    mov dl, 1
    mov bl, A_INP
    FAPI FAPI_PUTSAT
    FAPI FAPI_GETKEY
    push ax
    call input_done
    pop ax
    cmp al, 'y'
    je .yes
    cmp al, 'Y'
    je .yes
    cmp al, 13
    je .yes
    stc
    ret
.yes:
    clc
    ret

;---------------------------------------------------------------- отрисовка
draw_all:
    mov bx, panel0
    xor dl, dl
    call draw_panel
    mov bx, panel1
    mov dl, 40
    call draw_panel
    call draw_keybar
    ret

; панель BX, левый столбец DL
draw_panel:
    mov [pcol], dl
    mov [pptr], bx
    ; активна?
    mov al, A_FRM
    mov cx, bx
    cmp byte [active], 0
    jne .a1
    cmp bx, panel0
    je .act
    jmp .a2
.a1:
    cmp bx, panel1
    jne .a2
.act:
    mov al, A_AFRM
.a2:
    mov [pattr], al
    ; рамка
    mov dh, 0
    mov dl, [pcol]
    mov ch, 21
    mov cl, 40
    mov bl, al
    call g_frame_simple
    ; заголовок: путь
    mov dh, 0
    mov dl, [pcol]
    add dl, 2
    mov si, s_sp
    mov bl, [pattr]
    FAPI FAPI_PUTSAT
    mov bx, [pptr]
    lea si, [bx + P_PATH]
    cmp byte [si], 0
    jne .pp
    mov si, s_root
.pp:
    mov dl, [pcol]
    add dl, 3
    mov dh, 0
    mov bl, [pattr]
    FAPI FAPI_PUTSAT
    ; " " после пути
    mov bx, [pptr]
    lea si, [bx + P_PATH]
    call strlen_si
    cmp ax, 0
    jne .pl
    mov ax, 1
.pl:
    add al, [pcol]
    add al, 3
    mov dl, al
    mov al, ' '
    mov bl, [pattr]
    FAPI FAPI_PUTAT
    ; строки
    mov bx, [pptr]
    mov cx, [bx + P_TOP]
    mov dh, 1
.rows:
    push cx
    push dx
    mov bx, [pptr]
    cmp cx, [bx + P_CNT]
    jae .blank
    ; запись
    mov ax, cx
    push cx
    mov cl, 5
    shl ax, cl
    pop cx
    mov si, [bx + P_LIST]
    add si, ax
    mov di, [bx + P_MARK]
    add di, cx
    ; атрибут
    mov al, A_NORM
    test byte [si + 11], 0x10
    jz .n1
    mov al, A_DIR
.n1:
    cmp byte [di], 0
    je .n2
    mov al, A_MRK
.n2:
    cmp cx, [bx + P_SEL]
    jne .n4
    ; курсор только в активной панели
    mov ah, [pattr]
    cmp ah, A_AFRM
    jne .n4
    mov al, A_SEL
    cmp byte [di], 0
    je .n4
    mov al, A_MSEL
.n4:
    mov [eattr], al
    ; фон строки
    mov dl, [pcol]
    inc dl
    mov ch, 1
    mov cl, 38
    mov al, ' '
    mov bl, [eattr]
    FAPI FAPI_FILLRECT
    ; имя
    mov di, namebuf
    call name_to_str
    push si
    mov si, namebuf
    mov dl, [pcol]
    add dl, 2
    mov bl, [eattr]
    FAPI FAPI_PUTSAT
    pop si
    ; размер / <DIR>
    test byte [si + 11], 0x10
    jz .size
    push si
    mov si, s_dir
    mov dl, [pcol]
    add dl, 32
    mov bl, [eattr]
    FAPI FAPI_PUTSAT
    pop si
    jmp .next
.size:
    mov ax, [si + 28]
    mov dx, [si + 30]
    mov di, numbuf
    call u32_to_str                 ; -> numbuf ASCIIZ, AX длина
    pop dx
    push dx
    mov dl, [pcol]
    add dl, 38
    sub dl, al
    mov si, numbuf
    mov bl, [eattr]
    FAPI FAPI_PUTSAT
    jmp .next
.blank:
    mov dl, [pcol]
    inc dl
    mov ch, 1
    mov cl, 38
    mov al, ' '
    mov bl, A_NORM
    FAPI FAPI_FILLRECT
.next:
    pop dx
    pop cx
    inc cx
    inc dh
    cmp dh, ROWS
    jbe .rows
    ; информационная строка 21: имя и размер текущей записи
    mov dh, 21
    mov dl, [pcol]
    mov ch, 1
    mov cl, 40
    mov al, ' '
    mov bl, A_NORM
    FAPI FAPI_FILLRECT
    mov bx, [pptr]
    mov ax, [bx + P_CNT]
    test ax, ax
    jz .r
    mov ax, [bx + P_SEL]
    push cx
    mov cl, 5
    shl ax, cl
    pop cx
    mov si, [bx + P_LIST]
    add si, ax
    mov di, namebuf
    call name_to_str
    push si
    mov si, namebuf
    mov dh, 21
    mov dl, [pcol]
    add dl, 1
    mov bl, A_NORM
    FAPI FAPI_PUTSAT
    pop si
    test byte [si + 11], 0x10
    jnz .r
    mov ax, [si + 28]
    mov dx, [si + 30]
    mov di, numbuf
    call u32_to_str
    mov si, numbuf
    mov dh, 21
    mov dl, [pcol]
    add dl, 15
    mov bl, A_NORM
    FAPI FAPI_PUTSAT
    mov si, s_bytes
    mov dl, [pcol]
    add dl, 15
    add al, dl
    mov dl, al
    mov bl, A_NORM
    FAPI FAPI_PUTSAT
.r: ret

; двойная рамка DH,DL угол; CH высота, CL ширина; BL атрибут (своя — без game.inc)
g_frame_simple:
    push cx
    push dx
    mov al, ' '
    FAPI FAPI_FILLRECT              ; фон
    pop dx
    pop cx
    push cx
    push dx
    mov al, 0xC9
    FAPI FAPI_PUTAT
    push dx
    inc dl
    push cx
    mov ch, 1
    sub cl, 2
    mov al, 0xCD
    FAPI FAPI_FILLRECT
    pop cx
    pop dx
    push dx
    add dl, cl
    dec dl
    mov al, 0xBB
    FAPI FAPI_PUTAT
    pop dx
    push dx
    push cx
    inc dh
    sub ch, 2
    mov cl, 1
    mov al, 0xBA
    FAPI FAPI_FILLRECT
    pop cx
    pop dx
    push dx
    push cx
    inc dh
    add dl, cl
    dec dl
    sub ch, 2
    mov cl, 1
    mov al, 0xBA
    FAPI FAPI_FILLRECT
    pop cx
    pop dx
    add dh, ch
    dec dh
    mov al, 0xC8
    FAPI FAPI_PUTAT
    push dx
    inc dl
    push cx
    mov ch, 1
    sub cl, 2
    mov al, 0xCD
    FAPI FAPI_FILLRECT
    pop cx
    pop dx
    add dl, cl
    dec dl
    mov al, 0xBC
    FAPI FAPI_PUTAT
    pop dx
    pop cx
    ret

draw_keybar:
    mov dh, 24
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_KEY
    FAPI FAPI_FILLRECT
    mov si, keybar_txt
    xor dl, dl
.l:
    cmp byte [si], 0
    je .r
    push si
    mov dh, 24
    mov bl, A_BAR
    FAPI FAPI_PUTSAT                ; номер (2 символа)
    pop si
    add si, 3
    push si
    mov dh, 24
    add dl, 2
    mov bl, A_KEY
    FAPI FAPI_PUTSAT                ; название
    pop si
    add si, 7
    add dl, 6
    jmp .l
.r: ret

; AX = длина строки SI
strlen_si:
    push si
    xor ax, ax
.l:
    cmp byte [si], 0
    je .r
    inc si
    inc ax
    jmp .l
.r:
    pop si
    ret

; DX:AX -> десятичная ASCIIZ в DI; AX = длина
u32_to_str:
    push bx
    push cx
    push dx
    push di
    xor cx, cx
.div:
    push ax
    mov ax, dx
    xor dx, dx
    div word [ten]                  ; AX = старшее частное, DX = остаток
    mov bx, ax
    pop ax
    div word [ten]                  ; AX = младшее частное, DX = остаток
    push dx
    inc cx
    mov dx, bx
    or bx, ax
    jnz .div
    mov bx, cx
.out:
    pop ax
    add al, '0'
    stosb
    loop .out
    mov byte [di], 0
    mov ax, bx
    pop di
    pop dx
    pop cx
    pop bx
    ret

;---------------------------------------------------------------- просмотр
viewer:
    ; путь -> cmdbuf (без команды)
    push si
    mov di, cmdbuf
    mov byte [di], 0
    call put_panel_path
    pop si
    call name_to_str
    mov si, cmdbuf
    push ds
    pop es
    mov di, VIEWBUF
    xor bx, bx
    mov cx, VIEWMAX
    FAPI FAPI_READAT
    jc .r
    mov [vlen], ax
    mov word [vline], 0
    mov cx, 0x2000
    FAPI FAPI_CURSOR
.redraw:
    FAPI FAPI_CLS
    mov dh, 0
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_BAR
    FAPI FAPI_FILLRECT
    mov si, s_view
    mov dh, 0
    mov dl, 1
    mov bl, A_BAR
    FAPI FAPI_PUTSAT
    mov si, cmdbuf
    mov dl, 7
    mov bl, A_BAR
    FAPI FAPI_PUTSAT
    mov si, s_viewkeys
    mov dl, 46
    mov bl, A_BAR
    FAPI FAPI_PUTSAT
    cmp word [vlen], VIEWMAX
    jb .nobig
    mov si, s_viewbig
    mov dl, 36
    mov bl, 0x34
    FAPI FAPI_PUTSAT
.nobig:
    ; найти начало строки vline
    mov si, VIEWBUF
    mov cx, [vline]
.skip:
    jcxz .show
    call next_line                  ; SI -> следующая строка; CF если конец
    jc .show
    dec cx
    jmp .skip
.show:
    mov dh, 1
.rows:
    cmp dh, 24
    ja .wait
    mov dl, 0
    ; вывести до 80 символов строки
    mov bx, si
    sub bx, VIEWBUF
.ch:
    cmp bx, [vlen]
    jae .eol
    mov al, [si]
    cmp al, 13
    je .eol
    cmp al, 10
    je .eol
    cmp al, 9
    jne .pc
    mov al, ' '
.pc:
    cmp dl, 80
    jae .skipch
    push bx
    mov bl, 0x07
    FAPI FAPI_PUTAT
    pop bx
    inc dl
.skipch:
    inc si
    inc bx
    jmp .ch
.eol:
    call next_line
    inc dh
    jnc .rows
.wait:
    FAPI FAPI_GETKEY
    cmp al, 27
    je .quit
    cmp ah, 0x3D                    ; F3
    je .quit
    cmp ah, 0x44
    je .quit
    cmp ah, 0x48
    je .up
    cmp ah, 0x50
    je .dn
    cmp ah, 0x49
    je .pup
    cmp ah, 0x51
    je .pdn
    cmp ah, 0x47
    je .home
    jmp .wait
.up:
    cmp word [vline], 0
    je .wait
    dec word [vline]
    jmp .redraw
.dn:
    inc word [vline]
    jmp .redraw
.pup:
    sub word [vline], 23
    jns .redraw
    mov word [vline], 0
    jmp .redraw
.pdn:
    add word [vline], 23
    jmp .redraw
.home:
    mov word [vline], 0
    jmp .redraw
.quit:
    FAPI FAPI_CLS
.r: ret
; SI -> начало следующей строки (пропустить до CR/LF и сам разделитель); CF=1 если конец данных
next_line:
    push bx
    mov bx, si
    sub bx, VIEWBUF
.l:
    cmp bx, [vlen]
    jae .end
    mov al, [si]
    inc si
    inc bx
    cmp al, 10
    je .ok
    cmp al, 13
    jne .l
    cmp bx, [vlen]
    jae .ok
    cmp byte [si], 10
    jne .ok
    inc si
.ok:
    pop bx
    clc
    ret
.end:
    pop bx
    stc
    ret

;---------------------------------------------------------------- состояние
state_load:
    mov si, s_cfg
    push ds
    pop es
    mov di, panel0
    mov cx, P_SIZE * 2 + 1
    FAPI FAPI_READFILE
    jc .def
    cmp ax, P_SIZE * 2 + 1
    jne .def
    ; активная панель — текущий каталог оболочки (откуда запущен fm)
    call cur_panel
    push bx
    lea di, [bx + P_PATH]
    push ds
    pop es
    FAPI FAPI_GETCWD
    pop bx
    cmp word [bx + P_PATH], '/'     ; "/" + 0 -> ""
    jne .ld_ok
    mov byte [bx + P_PATH], 0
.ld_ok:
    mov word [bx + P_SEL], 0
    mov word [bx + P_TOP], 0
    call init_ptrs
    ret
.def:
    push ds
    pop es
    mov di, panel0
    mov cx, P_SIZE * 2 + 1
    xor al, al
    rep stosb
    ; панель 0 — текущий каталог оболочки, панель 1 — корень
    mov di, panel0 + P_PATH
    FAPI FAPI_GETCWD
    mov si, panel0 + P_PATH
    cmp word [si], '/'              ; "/" + 0 -> ""
    jne .ok
    mov byte [si], 0
.ok:
    call init_ptrs
    ret
init_ptrs:
    mov word [panel0 + P_LIST], LIST0
    mov word [panel0 + P_MARK], MARK0
    mov word [panel1 + P_LIST], LIST1
    mov word [panel1 + P_MARK], MARK1
    cmp byte [active], 1
    jbe .r
    mov byte [active], 0
.r: ret
state_save:
    ; текущий каталог оболочки = каталог активной панели (при перезапуске панель откроется там же)
    call cur_panel
    lea si, [bx + P_PATH]
    cmp byte [si], 0
    jne .ss_cd
    mov si, s_root
.ss_cd:
    FAPI FAPI_CHDIR
    mov si, s_cfg
    push ds
    pop es
    mov di, panel0
    mov cx, P_SIZE * 2 + 1
    FAPI FAPI_WRITEFILE
    ret

;---------------------------------------------------------------- данные
s_root      db "/", 0
s_sp        db " ", 0
s_dir       db " <DIR>", 0
s_bytes     db " bytes", 0
s_cfg       db "/SYSTEM/FM.CFG", 0
s_run       db "run ", 0
s_viewcmd   db "view ", 0
s_playcmd   db "ferramp ", 0
s_microcmd  db "micro ", 0
exec_pause  db 1
s_sh        db "sh ", 0
s_mono      db "mono ", 0
s_touch     db "touch ", 0
s_mkdir     db "mkdir ", 0
s_rename    db "rename ", 0
s_rm        db "rm ", 0
s_cp        db "cp ", 0
s_mv        db "mv ", 0
s_view      db "View:", 0
s_viewkeys  db "Up/Dn PgUp/PgDn Home  Esc/F3 back", 0
s_viewbig   db "[first 32K]", 0
p_newfile   db "New file name: ", 0
p_mkdir     db "New directory name: ", 0
p_rename    db "Rename to: ", 0
p_delete    db "Delete selected/marked? (y/N) ", 0
keybar_txt  db " 1", 0, "Help  ", 0
            db " 2", 0, "Ren   ", 0
            db " 3", 0, "View  ", 0
            db " 4", 0, "Edit  ", 0
            db " 5", 0, "Copy  ", 0
            db " 6", 0, "Move  ", 0
            db " 7", 0, "Mkdir ", 0
            db " 8", 0, "Del   ", 0
            db " 9", 0, "New   ", 0
            db "10", 0, "Quit  ", 0
            db 0
keybar_scan db 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x57, 0x44
help_txt    db "  fm - Ferrix file manager", 13,10,13,10
            db "  Tab / Left / Right   switch panel      Enter  dir / run .FAP / sh .SH / view .BMP / ferramp .WAV / micro .CH8 / text", 13,10
            db "  Up Down PgUp PgDn    move cursor       Backspace   parent directory", 13,10
            db "  Home / End           first / last      Ins / Space mark,  + / -  mark / unmark all", 13,10
            db "  F1  help             F2  rename        F3  view        F4  edit (mono)", 13,10
            db "  F5  copy to other    F6  move to other F7  mkdir       F8/Del  delete", 13,10
            db "  Shift+F4 / F9  new file (touch + mono) Ctrl+R refresh F10/Esc quit (cd to panel dir)", 13,10
            db "  Mouse: click = select, click again = Enter, right click = mark, bottom bar = F-keys", 13,10
            db 13,10, "  Press any key...", 0
ten         dw 10
mbtn_new    db 0
mbtn_prev   db 0
mclick_tick dw 0
pcol        db 0
pattr       db 0
eattr       db 0
pptr        dw 0
in_col      db 0
opcmd       dw 0
vlen        dw 0
vline       dw 0
namebuf     times 14 db 0
numbuf      times 12 db 0
tmpent      times 32 db 0
inbuf       times 44 db 0
cmdbuf      times 160 db 0
; состояние (сохраняется целиком в FM.CFG): panel0, panel1, active_saved
panel0      times P_SIZE db 0
panel1      times P_SIZE db 0
active      db 0
