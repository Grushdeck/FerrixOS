;======================================
; File name: apps/ironpp.inc
; Project: FERRIX-OS
; Description: iron — препроцессор frasm: чтение строк из далёкого сегмента, %include,
;              %macro/%endmacro (с %1..%9 и %%метка), %define, %ifdef/%ifndef/%else/%endif,
;              [директивы в скобках]. Подключается из iron.asm (вынесен, чтобы iron мог
;              собрать сам себя: один файл frasm — до 60 КБ).
;======================================

;---------------------------------------------------------------- препроцессор / чтение строк
; Следующая логическая строка -> linebuf (ASCIIZ). Разворачивает макросы, обрабатывает
; %include / %macro / %define / %ifdef / %ifndef / %else / %endif, снимает [скобки].
; CF=1 — текст кончился. CF=1 + [pp_err]=1 — ошибка препроцессора ([errmsg]).
fetch_line:
    mov byte [pp_err], 0
.again:
    cmp byte [mx_active], 0
    je .file
    ; строка тела макроса с подстановкой
    mov si, [mx_pos]
    cmp si, [mx_end]
    jae .mx_done
    mov cx, [mx_end]
    call copy_line_subst
    mov [mx_pos], si
    mov si, linebuf
    call skip_sp
    cmp byte [si], '['
    jne .ok
    call strip_brackets
    jmp .ok
.mx_done:
    mov byte [mx_active], 0
.file:
    mov si, [spos]
    cmp si, [send]
    jb .have
    ; конец текущего файла
    cmp byte [inc_depth], 0
    je .eof
    dec byte [inc_depth]
    mov ax, [sv_pos]
    mov [spos], ax
    mov ax, [sv_end]
    mov [send], ax
    mov ax, [sv_line]
    mov [lineno], ax
    mov ax, [sv_fname]
    mov [fname], ax
    mov ax, [sv_seg]
    mov [sseg], ax
    jmp .file
.have:
    mov cx, [send]
    call copy_line_raw              ; ES:SI -> linebuf, SI за концом строки
    mov [spos], si
    inc word [lineno]
    mov si, linebuf
    call skip_sp
    cmp byte [si], '%'
    je .pp
    cmp byte [pp_skip], 0
    jne .file                       ; внутри ложного %if
    cmp byte [si], '['
    jne .nobr
    call strip_brackets
.nobr:
    call check_macro                ; развернуть вызов макроса (если это он)
    jc .perr
.ok:
    clc
    ret
.eof:
    stc
    ret
.perr:
    mov byte [pp_err], 1
    stc
    ret
.pp:
    inc si
    call get_ident                  ; директива -> tok
    call skip_sp
    cmp byte [pp_skip], 0
    jne .pp_skipping
    call pp_match_endif
    je .file                        ; %endif вне пропуска — ничего
    call pp_match_else
    jne .pp1
    mov byte [pp_skip], 1           ; были в истинной ветке -> пропустить else
    jmp .file
.pp1:
    call pp_match_ifdef
    jne .pp2
    call pp_defined                 ; имя в SI -> ZF=1 если определено
    je .file
    mov byte [pp_skip], 1
    jmp .file
.pp2:
    call pp_match_ifndef
    jne .pp3
    call pp_defined
    jne .file
    mov byte [pp_skip], 1
    jmp .file
.pp3:
    call pp_match_define
    jne .pp4
    call pp_define                  ; %define NAME [значение]
    jc .perr
    jmp .file
.pp4:
    call pp_match_include
    jne .pp5
    call pp_include
    jc .perr
    jmp .file
.pp5:
    call pp_match_macro
    jne .pp6
    call pp_macro
    jc .perr
    jmp .file
.pp6:
    call pp_match_endmacro
    je .file
    mov word [errmsg], e_pp
    jmp .perr
.pp_skipping:
    call pp_match_ifdef
    je .pp_nest
    call pp_match_ifndef
    je .pp_nest
    call pp_match_endif
    jne .pp_s2
    dec byte [pp_skip]
    jmp .file
.pp_s2:
    call pp_match_else
    jne .file
    cmp byte [pp_skip], 1
    jne .file
    mov byte [pp_skip], 0
    jmp .file
.pp_nest:
    inc byte [pp_skip]
    jmp .file

; сравнение tok с именем директивы: ZF=1 если совпало
pp_match_endif:    mov bx, s_endif
                   jmp pp_cmp
pp_match_else:     mov bx, s_else
                   jmp pp_cmp
pp_match_ifdef:    mov bx, s_ifdef
                   jmp pp_cmp
pp_match_ifndef:   mov bx, s_ifndef
                   jmp pp_cmp
pp_match_define:   mov bx, s_define
                   jmp pp_cmp
pp_match_include:  mov bx, s_include
                   jmp pp_cmp
pp_match_macro:    mov bx, s_macro
                   jmp pp_cmp
pp_match_endmacro: mov bx, s_endmacro
pp_cmp:
    push si
    push di
    mov si, bx
    mov di, tok
.c: lodsb
    cmp al, [di]
    jne .d
    inc di
    test al, al
    jnz .c
.d: pop di
    pop si
    ret

; %define NAME [выражение]
pp_define:
    call peek_ident
    jc .bad
    call get_ident
    ; добавить флаг
    mov bx, [ndef]
    cmp bx, DEF_MAX
    jae .many
    inc word [ndef]
    mov ax, 32
    mul bx
    mov di, defs
    add di, ax
    push si
    mov si, tok
    mov cx, 32
.c: lodsb
    mov [di], al
    inc di
    test al, al
    loopnz .c
    pop si
    call skip_sp
    call at_eol
    je .ok
    call tok_save
    call parse_expr
    jc .r
    mov [eqval], ax
    call tok_restore
    call define_equ
    jc .r
.ok:
    clc
.r: ret
.bad:
    mov word [errmsg], e_syntax
    stc
    ret
.many:
    mov word [errmsg], e_toomany
    stc
    ret

; tok <-> tok2
tok_save:
    push si
    push di
    push cx
    mov si, tok
    mov di, tok2
    mov cx, 34
    rep movsw
    pop cx
    pop di
    pop si
    ret
tok_restore:
    push si
    push di
    push cx
    mov si, tok2
    mov di, tok
    mov cx, 34
    rep movsw
    pop cx
    pop di
    pop si
    ret

; определён ли идентификатор в SI (%define-флаг или символ)? ZF=1 да
pp_defined:
    call peek_ident
    jc .no
    call get_ident
    mov cx, [ndef]
    mov bx, defs
.l: jcxz .sym
    push si
    push di
    mov si, bx
    mov di, tok
.c: lodsb
    cmp al, [di]
    jne .n
    inc di
    test al, al
    jnz .c
    pop di
    pop si
    xor ax, ax                      ; ZF=1
    ret
.n: pop di
    pop si
    add bx, 32
    dec cx
    jmp .l
.sym:
    call make_fullname
    call find_sym
    jc .no
    xor ax, ax
    ret
.no:
    or al, 1                        ; ZF=0
    ret

; %include "имя"
pp_include:
    cmp byte [inc_depth], 0
    jne .nest
    cmp byte [si], '"'
    je .q
    cmp byte [si], 0x27
    jne .bad
.q: mov ah, [si]
    inc si
    mov di, tok2
    mov cx, 31
.c: lodsb
    cmp al, ah
    je .e
    test al, al
    jz .bad
    mov [di], al
    inc di
    loop .c
.e: mov byte [di], 0
    ; уже загружен?
    mov cx, [ninc]
    mov bx, incs
.f: jcxz .load
    push si
    push di
    mov si, bx
    mov di, tok2
.fc: lodsb
    cmp al, [di]
    jne .fn
    inc di
    test al, al
    jnz .fc
    pop di
    pop si
    jmp .enter
.fn: pop di
    pop si
    add bx, INC_SIZE
    dec cx
    jmp .f
.load:
    cmp word [ninc], INC_MAX
    jae .many
    ; запись
    mov ax, INC_SIZE
    mul word [ninc]
    mov bx, incs
    add bx, ax
    push bx
    mov si, tok2
    mov di, bx
.cp: lodsb
    mov [di], al
    inc di
    test al, al
    jnz .cp
    pop bx
    ; прочитать: сначала как есть, потом из каталога исходника
    push bx
    mov si, tok2
    call read_inc                   ; -> AX длина, CF ошибка
    jnc .got
    call src_dir_name               ; incpath = dir(srcpath) + tok2
    mov si, incpath
    call read_inc
    jnc .got
    pop bx
    mov word [errmsg], e_noinc
    stc
    ret
.got:
    pop bx
    mov [bx + 34], ax
    mov cx, [append]
    mov [bx + 32], cx
    add cx, ax
    push bx
    push es
    mov es, [seg_inc]
    mov bx, cx
    mov byte [es:bx], 0
    pop es
    pop bx
    inc cx
    mov [append], cx
    inc word [ninc]
.enter:
    ; войти в файл: сохранить состояние
    mov ax, [spos]
    mov [sv_pos], ax
    mov ax, [send]
    mov [sv_end], ax
    mov ax, [lineno]
    mov [sv_line], ax
    mov ax, [fname]
    mov [sv_fname], ax
    mov ax, [sseg]
    mov [sv_seg], ax
    inc byte [inc_depth]
    mov ax, [bx + 32]
    mov [spos], ax
    add ax, [bx + 34]
    mov [send], ax
    mov ax, [seg_inc]
    mov [sseg], ax
    mov word [lineno], 0
    mov [fname], bx
    clc
    ret
.bad:
    mov word [errmsg], e_syntax
    stc
    ret
.nest:
    mov word [errmsg], e_nest
    stc
    ret
.many:
    mov word [errmsg], e_toomany
    stc
    ret

; прочитать файл DS:SI в seg_inc:[append] -> AX длина; CF=1 ошибка
read_inc:
    push es
    mov es, [seg_inc]
    mov di, [append]
    mov cx, 0xFFF0
    sub cx, di
    jbe .full
    FAPI FAPI_READFILE
    pop es
    ret
.full:
    pop es
    stc
    ret

; incpath = каталог srcpath + tok2
src_dir_name:
    mov si, srcpath
    mov di, incpath
    xor bx, bx                      ; DI после последнего '/'
.l: lodsb
    mov [di], al
    inc di
    test al, al
    jz .d
    cmp al, '/'
    jne .l
    mov bx, di
    jmp .l
.d: test bx, bx
    jz .nodir
    mov di, bx
    jmp .cp
.nodir:
    mov di, incpath
.cp:
    mov si, tok2
.c: lodsb
    mov [di], al
    inc di
    test al, al
    jnz .c
    ret

; %macro NAME N ... %endmacro   (SI после "%macro")
pp_macro:
    call peek_ident
    jc .bad
    call get_ident
    call skip_sp
    push si
    call find_macro                 ; уже есть (2-й проход) -> просто пропустить тело
    pop si
    jnc .skip
    cmp word [nmac], MAC_MAX
    jae .many
    call parse_expr                 ; число параметров
    jc .r
    push ax
    mov ax, MAC_SIZE
    mul word [nmac]
    mov bx, macs
    add bx, ax
    pop ax
    mov [bx + 32], al
    push bx
    mov si, tok
    mov di, bx
.c: lodsb
    mov [di], al
    inc di
    test al, al
    jnz .c
    pop bx
    mov ax, [spos]
    mov [bx + 33], ax               ; начало тела
    mov ax, [sseg]
    mov [bx + 37], ax               ; сегмент текста
    push bx
    call skip_body                  ; -> AX начало строки %endmacro; spos за ней
    pop bx
    jc .r
    mov [bx + 35], ax
    inc word [nmac]
    clc
.r: ret
.skip:
    call skip_body
    ret
.bad:
    mov word [errmsg], e_syntax
    stc
    ret
.many:
    mov word [errmsg], e_toomany
    stc
    ret

; пропустить строки до %endmacro -> AX = смещение начала этой строки; CF=1 не найден
skip_body:
.l: mov si, [spos]
    cmp si, [send]
    jae .no
    push si
    mov cx, [send]
    call copy_line_raw
    mov [spos], si
    inc word [lineno]
    mov si, linebuf
    call skip_sp
    cmp byte [si], '%'
    jne .n
    inc si
    call get_ident
    call pp_match_endmacro
    jne .n
    pop ax
    clc
    ret
.n: pop ax
    jmp .l
.no:
    mov word [errmsg], e_endm
    stc
    ret

; найти макрос tok -> BX запись; CF=1 нет
find_macro:
    push si
    push di
    push cx
    mov cx, [nmac]
    mov bx, macs
.l: jcxz .no
    mov si, bx
    mov di, tok
.c: lodsb
    cmp al, [di]
    jne .n
    inc di
    test al, al
    jnz .c
    pop cx
    pop di
    pop si
    clc
    ret
.n: add bx, MAC_SIZE
    dec cx
    jmp .l
.no:
    pop cx
    pop di
    pop si
    stc
    ret

; строка в linebuf — вызов макроса? Если да: собрать аргументы, включить развёртку,
; оставить в linebuf только метку (если была). CF=1 ошибка
check_macro:
    mov si, linebuf
    call skip_sp
    call peek_ident
    jc .no
    call get_ident
    call skip_sp
    mov word [lbl_end], 0
    cmp byte [si], ':'
    jne .chk
    inc si
    mov [lbl_end], si
    call skip_sp
    call peek_ident
    jc .no
    call get_ident
    call skip_sp
.chk:
    call find_macro
    jc .no
    push bx
    ; аргументы
    mov di, argbuf
    xor cx, cx                      ; номер аргумента
.arg:
    cmp cl, ARG_MAX
    jae .args_done
    mov bx, cx
    shl bx, 1
    mov [arg_off + bx], di
    inc cx
    call skip_sp
    call at_eol
    je .arg_end
.ac: mov al, [si]
    test al, al
    jz .arg_end
    cmp al, 13
    je .arg_end
    cmp al, 10
    je .arg_end
    cmp al, ';'
    je .arg_end
    cmp al, ','
    je .arg_next
    cmp al, '"'
    je .quote
    cmp al, 0x27
    je .quote
    mov [di], al
    inc di
    inc si
    jmp .ac
.quote:
    mov ah, al
    mov [di], al
    inc di
    inc si
.qc: mov al, [si]
    test al, al
    jz .arg_end
    mov [di], al
    inc di
    inc si
    cmp al, ah
    jne .qc
    jmp .ac
.arg_next:
    inc si
    call .trim
    jmp .arg
.arg_end:
    call .trim
    ; остальные аргументы пустые
.fill:
    cmp cl, ARG_MAX
    jae .args_done
    mov bx, cx
    shl bx, 1
    mov [arg_off + bx], di
    inc cx
    jmp .fill
.args_done:
    mov byte [di], 0
    ; включить развёртку
    pop bx
    mov ax, [bx + 33]
    mov [mx_pos], ax
    mov ax, [bx + 35]
    mov [mx_end], ax
    mov ax, [bx + 37]
    mov [mx_seg], ax
    mov byte [mx_active], 1
    inc word [mx_id]
    ; в linebuf оставить только метку
    mov di, [lbl_end]
    test di, di
    jnz .lbl
    mov di, linebuf
.lbl:
    mov byte [di], 0
    clc
    ret
.no:
    clc
    ret
.trim:                              ; убрать пробелы в конце аргумента, завершить 0
    cmp di, argbuf
    je .t_d
    cmp byte [di - 1], ' '
    jne .t_d
    dec di
    jmp .trim
.t_d:
    mov byte [di], 0
    inc di
    ret

; убрать [ ] вокруг директивы ("[bits 16]" -> " bits 16 ")
strip_brackets:
    mov byte [si], ' '
.l: inc si
    mov al, [si]
    test al, al
    jz .d
    cmp al, ']'
    jne .l
    mov byte [si], ' '
.d: ret

; скопировать строку ES:SI (не дальше CX) -> linebuf; SI за CR/LF
copy_line_raw:
    push es
    mov es, [sseg]
    mov di, linebuf
    mov dx, LINE_MAX - 1
.l: cmp si, cx
    jae .d
    mov al, [es:si]
    inc si
    test al, al
    jz .d
    cmp al, 10
    je .d
    cmp al, 13
    je .cr
    test dx, dx
    jz .l                           ; слишком длинная — хвост отбрасываем
    mov [di], al
    inc di
    dec dx
    jmp .l
.cr:
    cmp si, cx
    jae .d
    cmp byte [es:si], 10
    jne .d
    inc si
.d: mov byte [di], 0
    pop es
    ret

; строка тела макроса ES:SI (до CX) -> linebuf с подстановкой %1..%9 и %%имя
copy_line_subst:
    push es
    mov es, [mx_seg]
    mov di, linebuf
    mov dx, LINE_MAX - 16
.l: cmp si, cx
    jae .d
    mov al, [es:si]
    inc si
    test al, al
    jz .d
    cmp al, 10
    je .d
    cmp al, 13
    je .cr
    cmp al, '%'
    je .pct
.put:
    test dx, dx
    jz .l
    mov [di], al
    inc di
    dec dx
    jmp .l
.pct:
    cmp si, cx
    jae .put
    mov al, [es:si]
    cmp al, '%'
    je .local
    cmp al, '1'
    jb .lit
    cmp al, '0' + ARG_MAX
    ja .lit
    inc si
    sub al, '1'
    xor ah, ah
    mov bx, ax
    shl bx, 1
    push si
    mov si, [arg_off + bx]
.ac: lodsb
    test al, al
    jz .ad
    test dx, dx
    jz .ac
    mov [di], al
    inc di
    dec dx
    jmp .ac
.ad: pop si
    jmp .l
.local:
    inc si
    ; ".@N@" + имя
    mov byte [di], '.'
    inc di
    mov byte [di], '@'
    inc di
    mov ax, [mx_id]
    call put_dec_di
    mov byte [di], '@'
    inc di
    sub dx, 8
    jns .l
    xor dx, dx
    jmp .l
.lit:
    mov al, '%'
    jmp .put
.cr:
    cmp si, cx
    jae .d
    cmp byte [es:si], 10
    jne .d
    inc si
.d: mov byte [di], 0
    pop es
    ret

; AX десятично -> DS:DI
put_dec_di:
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.l: xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .l
.o: pop ax
    add al, '0'
    mov [di], al
    inc di
    loop .o
    pop dx
    pop cx
    pop bx
    ret

