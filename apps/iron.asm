;======================================
; File name: apps/iron.asm
; Project: FERRIX-OS
; Description: iron — компилятор (ассемблер) frasm -> плоский образ .FAP/.BIN
;======================================
; Запуск: iron SOURCE.ASM OUT.FAP
; frasm — подмножество синтаксиса NASM (8086/186, 16 бит, плоский бинарник):
;   метки (NAME: и локальные .NAME), NAME equ выражение, org, db/dw (числа, 'c', "строки"),
;   times N db/dw X, resb N, resw N, align N, bits 16 (игнорируется), комментарии ';'.
;   Числа: 123, 0x7C, 7Ch, 0b101, 'A'. Выражения: + - * / ( ) $ $$ и метки.
;   Команды: mov add or adc sbb and sub xor cmp test inc dec push pop pusha popa pushf popf
;   xchg lea not neg mul imul div idiv rol ror rcl rcr shl sal shr sar jmp [short] call
;   j<cc> jcxz loop loope loopne ret retf iret int int3 in out rep/repe/repne + movsb/movsw/
;   cmpsb/cmpsw/stosb/stosw/lodsb/lodsw/scasb/scasw, clc stc cmc cld std cli sti hlt nop
;   cbw cwd lahf sahf xlat; память [bx+si+смещ] [bp+di] [si] [di] [bx] [bp] [смещ], сегментные
;   префиксы [es:...] и размеры byte/word. Переходы jmp — near (3 байта), j<cc>/loop — short.
; Сборка: nasm -f bin -I. apps/iron.asm -o IRON.FAP

%include "fapi.inc"

    FAPI_HEADER

; Текст исходника лежит в чужих сегментах (6000h занят буфером ядра):
;  на весь экран: главный файл в 7000h (до 64 КБ), %include-файлы в 8000h (до 64 КБ);
;  в окне gui (7000h/8000h — чужие окна): всё в 9000h — главный файл + включаемые (всего до 64 КБ).
SEG_FULL_MAIN equ 0x7000
SEG_FULL_INC  equ 0x8000
SEG_GUI       equ 0x9000
SRC_MAX  equ 0xFFF0
OUT_MAX  equ 16384                  ; результат до 16 КБ
SYM_MAX  equ 800
SYM_NAME equ 36                     ; имя (ASCIIZ, до 35 символов)
SYM_VAL  equ 36                     ; dw значение
SYM_LINE equ 38                     ; dw строка определения
SYM_SIZE equ 40
LINE_MAX equ 512
MAC_MAX  equ 24                     ; макросов
MAC_SIZE equ 40                     ; имя 32, db параметров, dw начало, dw конец тела
INC_MAX  equ 4                      ; включаемых файлов
INC_SIZE equ 36                     ; имя 32, dw смещение, dw длина
DEF_MAX  equ 8                      ; %define-флагов
ARG_MAX  equ 9

; операнд
OP_NONE  equ 0
OP_R8    equ 1
OP_R16   equ 2
OP_SREG  equ 3
OP_IMM   equ 4
OP_MEM   equ 5

start:
    cld
    mov si, 0x80
    call skip_sp
    cmp byte [si], 0
    je usage
    mov di, srcpath
    call copy_word
    call skip_sp
    cmp byte [si], 0
    je usage
    mov di, outpath
    call copy_word
    ; --- выбрать сегменты текста ---
    mov ax, SEG_GUI
    mov [seg_main], ax
    mov [seg_inc], ax
    cmp word [0x10], 0xB800         ; на весь экран?
    jne .segs
    mov word [seg_main], SEG_FULL_MAIN
    mov word [seg_inc], SEG_FULL_INC
.segs:
    ; --- прочитать исходник в seg_main:0 ---
    mov es, [seg_main]
    mov si, srcpath
    xor di, di
    mov cx, SRC_MAX
    FAPI FAPI_READFILE
    jc err_read
    mov [main_len], ax
    mov bx, ax
    mov byte [es:bx], 0
    xor cx, cx
    cmp word [seg_inc], SEG_GUI     ; в одном сегменте — включаемые после главного
    jne .ap
    mov cx, ax
    inc cx
.ap:
    mov [append], cx
    push ds
    pop es
    mov word [nmac], 0
    mov word [ninc], 0
    mov word [bss_align], 4
    mov word [data_align], 4
    ; --- проходы: 1-й собирает символы, дальше — пока размеры переходов не устоятся ---
    mov byte [pass], 1
    call assemble
    jc fail
    mov cx, 12                      ; предел проходов
.pass:
    inc byte [pass]
    mov byte [changed], 0
    push cx
    call assemble
    pop cx
    jc fail
    cmp byte [changed], 0
    je .stable
    loop .pass
.stable:
    ; --- записать ---
    mov si, outpath
    mov di, outbuf
    mov cx, [outlen]
    FAPI FAPI_WRITEFILE
    jc err_write
    FAPI_PRINT msg_ok1
    mov dx, [outlen]
    FAPI FAPI_PRINTDEC
    FAPI_PRINT msg_ok2
    mov si, outpath
    FAPI FAPI_PUTS
    FAPI_PRINT msg_ok3
    mov dx, [nsyms]
    FAPI FAPI_PRINTDEC
    FAPI_PRINT msg_ok4
    mov dl, [pass]
    xor dh, dh
    FAPI FAPI_PRINTDEC
    FAPI_PRINT msg_ok5
    FAPI_QUIT

fail:
    ; сообщение об ошибке: "file:line: text"
    mov si, [fname]
    FAPI FAPI_PUTS
    FAPI_PRINT msg_colon
    mov dx, [lineno]
    FAPI FAPI_PRINTDEC
    FAPI_PRINT msg_colon2
    mov si, [errmsg]
    FAPI FAPI_PUTS
    FAPI_PRINT crlf
    FAPI_QUIT
err_read:
    FAPI_PRINT msg_noread
    FAPI_QUIT
err_write:
    FAPI_PRINT msg_nowrite
    FAPI_QUIT
usage:
    FAPI_PRINT msg_usage
    FAPI_QUIT

;---------------------------------------------------------------- проход
assemble:
    mov word [pc], 0x100
    mov word [origin], 0x100
    mov word [outlen], 0
    mov word [lineno], 0
    mov byte [lastglob], 0
    mov byte [bss_mode], 0
    mov byte [in_data], 0
    mov byte [mx_active], 0
    mov word [mx_id], 0
    mov byte [inc_depth], 0
    mov byte [pp_skip], 0
    mov word [ndef], 0
    mov word [spos], 0
    mov ax, [main_len]
    mov [send], ax
    mov ax, [seg_main]
    mov [sseg], ax
    mov word [fname], srcpath
    mov word [nmac], 0              ; макросы видны только после определения (как в NASM)
    mov word [jidx], 0
    cmp byte [pass], 1
    jne .jk
    push es
    push ds
    pop es
    mov di, jlong
    mov cx, JL_BYTES / 2
    xor ax, ax
    rep stosw
    pop es
.jk:
    cmp byte [pass], 1
    jne .p2
    mov word [nsyms], 0
.p2:
.line:
    call fetch_line                 ; -> linebuf; CF=1 конец
    jnc .do
    cmp byte [pp_err], 0
    jne .err
    jmp .eof
.do:
    mov si, linebuf
    call do_line
    jc .err
    jmp .line
.eof:
    clc
    ret
.err:
    stc
    ret

%include "ironpp.inc"

; обработать одну строку. SI -> строка. CF=1 ошибка ([errmsg]).
do_line:
    mov byte [prefix], 0
    call skip_sp
    call at_eol
    je .end
    ; метка / equ ?
    call peek_ident                 ; -> CF если не идентификатор; CX длина (SI не меняется)
    jc .instr
    push si
    call get_ident                  ; -> tok (верхний регистр), SI за ним
    call skip_sp
    cmp byte [si], ':'
    jne .not_label
    inc si
    pop ax                          ; убрать сохранённый SI
    call define_label
    jc .fail
    call skip_sp
    call at_eol
    je .end
    jmp do_line.instr0
.not_label:
    ; "NAME equ expr" ?
    push si
    call peek_ident
    jc .nl2
    call get_ident_tmp              ; -> tok2
    cmp word [tok2], 'EQ'
    jne .nl2
    cmp byte [tok2 + 2], 'U'
    jne .nl2
    cmp byte [tok2 + 3], 0
    jne .nl2
    pop ax                          ; SI после "equ"
    pop ax
    call skip_sp
    call tok_save                   ; выражение затирает tok
    call parse_expr                 ; -> AX
    jc .fail
    mov [eqval], ax
    call tok_restore
    call define_equ
    jc .fail
    jmp .end
.nl2:
    pop si                          ; SI после первого слова
    pop ax                          ; (начало слова — не нужно)
    ; слово известно как команда? иначе это метка без двоеточия
    push si
    call find_mnemonic
    pop si
    jnc .is_instr
    call define_label
    jc .fail
    call skip_sp
    call at_eol
    je .end
    jmp .instr0
.is_instr:
    jmp .instr_from_tok
.instr:
    ; не идентификатор в начале строки — ошибка (кроме комментария)
    cmp byte [si], ';'
    je .end
    mov word [errmsg], e_syntax
    jmp .fail
.instr0:
    call do_instr
    jc .fail
    jmp .after_instr
.instr_from_tok:
    call do_instr.tok
    jc .fail
.after_instr:
    call skip_sp
    call at_eol
    jne .junk
.end:
    call to_eol                     ; SI -> начало следующей строки
    clc
    ret
.fail:
    stc
    ret
.junk:
    mov word [errmsg], e_junk
    jmp .fail

; одна команда/директива в SI (мнемоника + операнды). CF=1 ошибка
do_instr:
    call peek_ident
    jc .bad
    call get_ident                  ; мнемоника/директива в tok
.tok:                               ; вход, когда tok уже содержит мнемонику, SI за ней
    mov byte [op32], 0
    call skip_sp
    call find_mnemonic              ; -> BX запись таблицы; CF нет
    jc .unknown
    mov ax, [bx]                    ; обработчик
    mov dx, [bx + 2]                ; параметр
    call ax
    ret
.bad:
    mov word [errmsg], e_syntax
    stc
    ret
.unknown:
    mov word [errmsg], e_unknown
    stc
    ret

; конец строки/комментарий? ZF=1 если да
at_eol:
    cmp byte [si], 0
    je .y
    cmp byte [si], 13
    je .y
    cmp byte [si], 10
    je .y
    cmp byte [si], ';'
.y: ret

; SI -> за конец строки (после CR/LF)
to_eol:
    lodsb
    test al, al
    jz .z
    cmp al, 10
    jne to_eol
    ret
.z: dec si
    ret

skip_sp:
    cmp byte [si], ' '
    je .s
    cmp byte [si], 9
    jne .r
.s: inc si
    jmp skip_sp
.r: ret

; идентификатор начинается в SI? CF=1 нет
peek_ident:
    mov al, [si]
    cmp al, '.'
    je .ok
    cmp al, '_'
    je .ok
    cmp al, '$'
    je .ok
    call is_alpha
    jc .no
.ok:
    clc
    ret
.no:
    stc
    ret

is_alpha:                           ; AL буква? CF=1 нет
    push ax
    or al, 0x20
    cmp al, 'a'
    jb .n
    cmp al, 'z'
    ja .n
    pop ax
    clc
    ret
.n: pop ax
    stc
    ret
is_alnum:                           ; буква/цифра/_/@ ? CF=1 нет
    cmp al, '_'
    je .y
    cmp al, '@'
    je .y
    cmp al, '0'
    jb .n
    cmp al, '9'
    jbe .y
    call is_alpha
    ret
.y: clc
    ret
.n: stc
    ret

; идентификатор SI -> tok (верхний регистр, ASCIIZ, до 31), SI за ним
get_ident:
    push di
    mov di, tok
    jmp get_ident_into
get_ident_tmp:
    push di
    mov di, tok2
get_ident_into:
    push cx
    mov cx, 31
.l:
    lodsb
    cmp al, '.'
    je .ok
    cmp al, '$'
    je .ok
    call is_alnum
    jc .d
.ok:
    mov [di + TOK_RAW], al          ; копия в исходном регистре (для имён символов)
    cmp al, 'a'
    jb .st
    cmp al, 'z'
    ja .st
    sub al, 0x20
.st:
    stosb
    loop .l
    ; слишком длинный — обрезать
.cut:
    lodsb
    call is_alnum
    jnc .cut
.d:
    dec si
    mov byte [di], 0
    mov byte [di + TOK_RAW], 0
    pop cx
    pop di
    ret

; слово (до пробела) SI -> DI (ASCIIZ)
copy_word:
    lodsb
    cmp al, ' '
    je .d
    test al, al
    jz .d
    stosb
    jmp copy_word
.d: dec si
    mov byte [di], 0
    ret

;---------------------------------------------------------------- символы
; имя в tok -> полное имя в fullname (локальное ".x" -> "GLOBAL.x")
make_fullname:
    push ax
    push si
    push di
    mov di, fullname
    mov si, tok + TOK_RAW           ; имена символов чувствительны к регистру (как в NASM)
    cmp byte [si], '.'
    jne .cp
    push si
    mov si, lastglob
.g: lodsb
    test al, al
    jz .ge
    stosb
    jmp .g
.ge:
    pop si
.cp:
    lodsb
    stosb
    test al, al
    jnz .cp
    pop di
    pop si
    pop ax
    ret

; найти символ fullname -> BX запись (таблица syms), [sym_val], [sym_line]; CF=1 нет
find_sym:
    push es
    push cx
    push si
    push di
    push ax
    push ds
    pop es
    mov cx, [nsyms]
    mov bx, syms
.l:
    jcxz .no
    mov si, fullname
    mov di, bx
.c: lodsb
    cmp al, [es:di]
    jne .n
    inc di
    test al, al
    jnz .c
    mov ax, [es:bx + SYM_VAL]
    mov [sym_val], ax
    mov ax, [es:bx + SYM_LINE]
    mov [sym_line], ax
    pop ax
    pop di
    pop si
    pop cx
    pop es
    clc
    ret
.n: add bx, SYM_SIZE
    dec cx
    jmp .l
.no:
    pop ax
    pop di
    pop si
    pop cx
    pop es
    stc
    ret

; определить метку tok = [pc]
define_label:
    ; глобальная метка запоминается как префикс локальных
    cmp byte [tok], '.'
    je .loc
    push si
    push di
    mov si, tok + TOK_RAW
    mov di, lastglob
.c: lodsb
    stosb
    test al, al
    jnz .c
    pop di
    pop si
.loc:
    mov ax, [pc]
    jmp define_sym
; name equ [eqval]
define_equ:
    mov ax, [eqval]
define_sym:
    call make_fullname
    cmp byte [pass], 1
    jne .p2
    push ax
    call find_sym
    pop ax
    jnc .dup
    mov bx, [nsyms]
    cmp bx, SYM_MAX
    jae .toomany
    inc word [nsyms]
    push ax
    mov ax, SYM_SIZE
    mul bx
    add ax, syms
    mov bx, ax
    pop ax
    push es
    push ax
    push si
    push di
    push ds
    pop es
    mov si, fullname
    mov di, bx
    mov cx, SYM_NAME - 1
.c: lodsb
    stosb
    test al, al
    jz .cd
    loop .c
    mov byte [di], 0                ; слишком длинное имя — обрезать
.cd:
    pop di
    pop si
    pop ax
    mov [es:bx + SYM_VAL], ax
    mov cx, [lineno]
    mov [es:bx + SYM_LINE], cx
    pop es
    clc
    ret
.p2:
    push ax
    call find_sym
    pop ax
    jc .int
    mov [bx + SYM_VAL], ax          ; уточнить (на 2-м проходе значения те же)
    clc
    ret
.dup:
    mov word [errmsg], e_dup
    stc
    ret
.toomany:
    mov word [errmsg], e_toomany
    stc
    ret
.int:
    mov word [errmsg], e_internal
    stc
    ret

;---------------------------------------------------------------- выражения
; parse_expr: SI -> выражение; -> AX значение; [fwd]=1 если есть неизвестный/«передний» символ
; CF=1 ошибка
parse_expr:
    mov byte [fwd], 0
    call expr_or
    ret
; приоритеты NASM (от низкого): |  ^  &  << >>  + -  * /
expr_or:
    call expr_xor
    jc .r
.l: push ax
    call skip_sp
    cmp byte [si], '|'
    jne .d
    cmp byte [si + 1], '|'
    je .d
    inc si
    call expr_xor
    jc .e
    pop dx
    or ax, dx
    jmp .l
.d: pop ax
    clc
.r: ret
.e: pop dx
    stc
    ret
expr_xor:
    call expr_and
    jc .r
.l: push ax
    call skip_sp
    cmp byte [si], '^'
    jne .d
    inc si
    call expr_and
    jc .e
    pop dx
    xor ax, dx
    jmp .l
.d: pop ax
    clc
.r: ret
.e: pop dx
    stc
    ret
expr_and:
    call expr_shift
    jc .r
.l: push ax
    call skip_sp
    cmp byte [si], '&'
    jne .d
    cmp byte [si + 1], '&'
    je .d
    inc si
    call expr_shift
    jc .e
    pop dx
    and ax, dx
    jmp .l
.d: pop ax
    clc
.r: ret
.e: pop dx
    stc
    ret
expr_shift:
    call expr_sum
    jc .r
.l: push ax
    call skip_sp
    mov al, [si]
    cmp al, '<'
    je .sh
    cmp al, '>'
    jne .d
.sh:
    cmp [si + 1], al
    jne .d
    push ax
    add si, 2
    call expr_sum
    pop bx                          ; BL = '<' или '>'
    jc .e
    mov cx, ax
    pop ax
    cmp bl, '<'
    jne .right
    shl ax, cl
    jmp .l
.right:
    shr ax, cl
    jmp .l
.d: pop ax
    clc
.r: ret
.e: pop dx
    stc
    ret
expr_sum:
    call expr_term
    jc .r
.l:
    push ax
    call skip_sp
    mov al, [si]
    cmp al, '+'
    je .add
    cmp al, '-'
    je .sub
    pop ax
    clc
.r: ret
.add:
    inc si
    call expr_term
    jc .e
    pop dx
    add ax, dx
    jmp .l
.sub:
    inc si
    call expr_term
    jc .e
    pop dx
    sub dx, ax
    mov ax, dx
    jmp .l
.e: pop dx
    stc
    ret
expr_term:
    call expr_factor
    jc .r
.l:
    push ax
    call skip_sp
    mov al, [si]
    cmp al, '*'
    je .mul
    cmp al, '/'
    je .div
    pop ax
    clc
.r: ret
.mul:
    inc si
    call expr_factor
    jc .e
    pop dx
    mul dx
    jmp .l
.div:
    inc si
    call expr_factor
    jc .e
    pop dx
    xchg ax, dx
    test dx, dx
    jz .z
    push dx
    xor dx, dx
    pop cx
    div cx
    jmp .l
.z: mov word [errmsg], e_div0
    stc
    ret
.e: pop dx
    stc
    ret
expr_factor:
    call skip_sp
    mov al, [si]
    cmp al, '('
    je .paren
    cmp al, '-'
    je .neg
    cmp al, '+'
    je .pos
    cmp al, '~'
    je .not
    cmp al, 0x27                    ; 'c'
    je .chr
    cmp al, '$'
    je .dollar
    cmp al, '0'
    jb .ident
    cmp al, '9'
    jbe .num
.ident:
    call peek_ident
    jc .bad
    call get_ident
    ; регистр здесь недопустим — просто символ
    call make_fullname
    call find_sym
    jc .undef
    mov ax, [sym_val]
    mov cx, [sym_line]
    cmp cx, [lineno]
    jb .ok
    mov byte [fwd], 1
.ok:
    clc
    ret
.undef:
    cmp byte [pass], 1
    jne .undef2
    mov byte [fwd], 1
    xor ax, ax
    clc
    ret
.undef2:
    mov word [errmsg], e_undef
    stc
    ret
.paren:
    inc si
    call expr_or
    jc .r
    call skip_sp
    cmp byte [si], ')'
    jne .bad
    inc si
    clc
.r: ret
.neg:
    inc si
    call expr_factor
    jc .r
    neg ax
    clc
    ret
.not:
    inc si
    call expr_factor
    jc .r
    not ax
    clc
    ret
.pos:
    inc si
    jmp expr_factor
.chr:
    inc si
    lodsb
    xor ah, ah
    cmp byte [si], 0x27
    je .chr1
    mov ah, [si]                    ; 'AB' = 'A' | 'B' << 8
    inc si
    cmp byte [si], 0x27
    jne .bad
.chr1:
    inc si
    clc
    ret
.dollar:
    inc si
    cmp byte [si], '$'
    jne .here
    inc si
    mov ax, [origin]
    clc
    ret
.here:
    mov ax, [pc]
    clc
    ret
.num:
    call parse_number
    ret
.bad:
    mov word [errmsg], e_expr
    stc
    ret

; число в SI -> AX (10, 0x, суффикс h, 0b)
parse_number:
    push si
.e: lodsb
    call is_alnum
    jnc .e
    dec si
    dec si
    mov al, [si]
    pop si
    or al, 0x20
    cmp al, 'h'
    je .hsuffixed
    cmp word [si], '0x'
    je .hex
    cmp word [si], '0X'
    je .hex
    cmp word [si], '0b'
    je .bin
    cmp word [si], '0B'
    je .bin
.hsuffixed:
    xor ax, ax                      ; как hex
    xor bx, bx                      ; как dec
    mov byte [nondec], 0              ; 1 = встретилась не-десятичная цифра
.scan:
    mov cl, [si]
    call hexval
    jc .scan_end
    cmp cl, 9
    jbe .dig
    mov byte [nondec], 1
.dig:
    shl ax, 4
    xor ch, ch
    add ax, cx
    push ax
    mov ax, bx
    mov bx, 10
    mul bx
    add ax, cx
    mov bx, ax
    pop ax
    inc si
    jmp .scan
.scan_end:
    cmp byte [si], 'h'
    je .hsuf
    cmp byte [si], 'H'
    je .hsuf
    cmp byte [nondec], 0
    jne .bad
    mov ax, bx
    clc
    ret
.hsuf:
    inc si
    clc
    ret
.bad:
    mov word [errmsg], e_number
    stc
    ret
.hex:
    add si, 2
    xor ax, ax
.hl:
    mov cl, [si]
    call hexval
    jc .hd
    shl ax, 4
    xor ch, ch
    add ax, cx
    inc si
    jmp .hl
.hd:
    clc
    ret
.bin:
    add si, 2
    xor ax, ax
.bl:
    mov cl, [si]
    sub cl, '0'
    cmp cl, 1
    ja .bd
    shl ax, 1
    xor ch, ch
    add ax, cx
    inc si
    jmp .bl
.bd:
    clc
    ret

hexval:                             ; CL символ -> CL значение; CF=1 не hex
    cmp cl, '0'
    jb .n
    cmp cl, '9'
    ja .a
    sub cl, '0'
    clc
    ret
.a: or cl, 0x20
    cmp cl, 'a'
    jb .n
    cmp cl, 'f'
    ja .n
    sub cl, 'a' - 10
    clc
    ret
.n: stc
    ret

;---------------------------------------------------------------- операнды
; parse_operand: SI -> операнд; заполняет op_* (структура opa или opb по [cur_op])
parse_operand:
    mov di, [cur_op]
    mov byte [di + O_TYPE], OP_NONE
    mov byte [di + O_SIZE], 0
    mov byte [di + O_SEGP], 0
    mov byte [di + O_FWD], 0
    call skip_sp
    ; размер byte/word/short/near/far
    call peek_ident
    jc .not_ident
    push si
    call get_ident
    mov bx, tok
    cmp word [bx], 'BY'
    jne .w
    cmp word [bx + 2], 'TE'
    jne .w
    cmp byte [bx + 4], 0
    jne .w
    pop ax
    mov byte [di + O_SIZE], 1
    jmp parse_operand.after_size
.w:
    cmp word [bx], 'WO'
    jne .sh
    cmp word [bx + 2], 'RD'
    jne .sh
    cmp byte [bx + 4], 0
    jne .sh
    pop ax
    mov byte [di + O_SIZE], 2
    jmp parse_operand.after_size
.sh:
    cmp word [bx], 'SH'
    jne .nr
    cmp word [bx + 2], 'OR'
    jne .nr
    cmp word [bx + 4], 'T'
    jne .nr
    pop ax
    mov byte [di + O_SIZE], 3       ; short
    jmp parse_operand.after_size
.nr:
    cmp word [bx], 'NE'
    jne .fr
    cmp word [bx + 2], 'AR'
    jne .fr
    cmp byte [bx + 4], 0
    jne .fr
    pop ax
    jmp parse_operand.after_size
.fr:
    cmp word [bx], 'FA'
    jne .reg
    cmp byte [bx + 2], 'R'
    jne .reg
    cmp byte [bx + 3], 0
    jne .reg
    pop ax
    mov byte [di + O_SIZE], 4       ; far
    jmp parse_operand.after_size
.reg:
    ; регистр?
    call lookup_reg                 ; tok -> AL код, AH класс (1 r8, 2 r16, 3 sreg); CF нет
    jc .sym
    pop bx                          ; отбросить сохранённый SI
    mov [di + O_TYPE], ah
    mov [di + O_REG], al
    mov byte [di + O_SIZE], 1
    cmp ah, OP_R8
    je .r_ok
    mov byte [di + O_SIZE], 2
.r_ok:
    clc
    ret
.sym:
    pop si                          ; выражение (imm)
.not_ident:
    call skip_sp
    cmp byte [si], '['
    je .mem
    call parse_expr
    jc .r
    mov [di + O_VAL], ax
    mov al, [fwd]
    mov [di + O_FWD], al
    mov byte [di + O_TYPE], OP_IMM
    ; далее может быть ':' (far ptr seg:off)
    call skip_sp
    cmp byte [si], ':'
    jne .ok
    inc si
    mov ax, [di + O_VAL]
    mov [di + O_SEG], ax
    call parse_expr
    jc .r
    mov [di + O_VAL], ax
    mov byte [di + O_TYPE], OP_IMM
    mov byte [di + O_SIZE], 4       ; far seg:off
.ok:
    clc
.r: ret
.after_size:
    call skip_sp
    cmp byte [si], '['
    je .mem
    ; "short label" / "byte 5" — выражение
    jmp .not_ident
.mem:
    inc si
    mov byte [di + O_TYPE], OP_MEM
    mov byte [di + O_BASE], 0xFF    ; нет base/index
    mov word [di + O_VAL], 0
    mov byte [di + O_HASD], 0
    mov byte [di + O_BXF], 0
    mov byte [di + O_BPF], 0
    mov byte [di + O_SIF], 0
    mov byte [di + O_DIF], 0
    ; сегментный префикс ES: CS: SS: DS:
    call skip_sp
    push si
    call peek_ident
    jc .nosp
    call get_ident
    call skip_sp
    cmp byte [si], ':'
    jne .nosp
    call lookup_reg
    jc .nosp
    cmp ah, OP_SREG
    jne .nosp
    inc si                          ; ':'
    pop bx
    mov ah, al
    mov al, 0x26                    ; ES
    cmp ah, 0
    je .sp_set
    mov al, 0x2E                    ; CS
    cmp ah, 1
    je .sp_set
    mov al, 0x36                    ; SS
    cmp ah, 2
    je .sp_set
    mov al, 0x3E                    ; DS
.sp_set:
    mov [di + O_SEGP], al
    jmp .terms
.nosp:
    pop si
.terms:
    call skip_sp
    mov byte [sign], 0
    cmp byte [si], ']'
    je .mem_done
    cmp byte [si], '+'
    jne .t_sign2
    inc si
    jmp .term
.t_sign2:
    cmp byte [si], '-'
    jne .term
    inc si
    mov byte [sign], 1
.term:
    call skip_sp
    push si
    call peek_ident
    jc .t_expr
    call get_ident
    call lookup_reg
    jc .t_expr
    cmp ah, OP_R16
    jne .t_bad
    pop bx                          ; принять регистр
    cmp al, 3
    je .t_bx
    cmp al, 5
    je .t_bp
    cmp al, 6
    je .t_si
    cmp al, 7
    je .t_di
.t_bad:
    mov word [errmsg], e_addr
    stc
    ret
.t_bx: mov byte [di + O_BXF], 1
    jmp .terms
.t_bp: mov byte [di + O_BPF], 1
    jmp .terms
.t_si: mov byte [di + O_SIF], 1
    jmp .terms
.t_di: mov byte [di + O_DIF], 1
    jmp .terms
.t_expr:
    pop si
    mov byte [fwd], 0
    call expr_term                  ; слагаемое (с * /)
    jc .r
    cmp byte [sign], 0
    je .t_add
    neg ax
.t_add:
    add [di + O_VAL], ax
    mov byte [di + O_HASD], 1
    cmp byte [fwd], 0
    je .terms
    mov byte [di + O_FWD], 1
    jmp .terms
.mem_done:
    inc si
    ; r/m код
    mov al, [di + O_BXF]
    shl al, 1
    or al, [di + O_BPF]
    shl al, 1
    or al, [di + O_SIF]
    shl al, 1
    or al, [di + O_DIF]             ; биты: bx bp si di
    test al, al
    jz .m_ok                        ; только смещение: O_BASE = 0xFF
    mov bx, rm_tab
    xlat                            ; -> код r/m или 0xFF
    cmp al, 0xFF
    je .t_bad
    mov [di + O_BASE], al
.m_ok:
    clc
    ret

; таблица r/m по битам bx bp si di (0..15)
rm_tab: db 0xFF, 5, 4, 0xFF, 6, 3, 2, 0xFF, 7, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
;            0   di  si  sidi bp bpdi bpsi .. bx bxdi bxsi

; tok -> регистр: AL код, AH класс; CF=1 нет
lookup_reg:
    push si
    push di
    push cx
    cmp byte [tok + 2], 0
    je .l2
    ; 32-битный регистр EAX..EDI -> как r16 + флаг o32 (префикс 66h)
    cmp byte [tok], 'E'
    jne .no
    cmp byte [tok + 3], 0
    jne .no
    mov si, reg_names + 16
    xor cx, cx
.e:
    mov ax, [si]
    cmp ax, [tok + 1]
    je .ef
    add si, 2
    inc cx
    cmp cx, 8
    jb .e
    jmp .no
.ef:
    mov byte [op32], 1
    mov ax, cx
    mov ah, OP_R16
    jmp .d
.l2:
    mov si, reg_names
    xor cx, cx
.l:
    mov ax, [si]
    cmp ax, [tok]
    je .f
    add si, 2
    inc cx
    cmp cx, 20
    jb .l
.no:
    pop cx
    pop di
    pop si
    stc
    ret
.f:
    mov ax, cx
    mov ah, OP_R8
    cmp al, 8
    jb .d
    sub al, 8
    mov ah, OP_R16
    cmp al, 8
    jb .d
    sub al, 8
    mov ah, OP_SREG
.d:
    pop cx
    pop di
    pop si
    clc
    ret
reg_names: db "ALCLDLBLAHCHDHBH", "AXCXDXBXSPBPSIDI", "ESCSSSDS"

; разобрать до двух операндов через запятую -> opa, opb; [nops]
parse_operands:
    mov byte [nops], 0
    call skip_sp
    call at_eol
    je .d
    mov word [cur_op], opa
    call parse_operand
    jc .r
    mov byte [nops], 1
    call skip_sp
    cmp byte [si], ','
    jne .d
    inc si
    mov word [cur_op], opb
    call parse_operand
    jc .r
    mov byte [nops], 2
.d: clc
.r: ret

;---------------------------------------------------------------- вывод байтов
; emit: байт AL в выходной поток. Если в команде встретился 32-битный регистр
; ([op32]=1), перед первым байтом кода (после префикса сегмента) вставляется 66h.
emit:                               ; AL
    cmp byte [op32], 1
    jne emit_raw
    mov byte [op32], 2
    push ax
    mov al, 0x66
    call emit_raw
    pop ax
emit_raw:
    push bx
    cmp byte [bss_mode], 0
    jne .inbss
    mov bx, [outlen]
    cmp bx, OUT_MAX
    jae .ovf
    cmp byte [pass], 1
    je .n
    mov [outbuf + bx], al
.n: inc word [outlen]
    inc word [pc]
    pop bx
    clc
    ret
.ovf:
    pop bx
    mov word [errmsg], e_big
    stc
    ret
.inbss:
    pop bx
    mov word [errmsg], e_section
    stc
    ret
emitw:                              ; AX
    push ax
    call emit
    pop ax
    jc .r
    push ax
    mov al, ah
    call emit
    pop ax
.r: ret
; непосредственное значение размером операнда: 16 бит, при 32-битном операнде — 32
; (старшее слово: FFFF для «маленьких отрицательных» >= FF80h, иначе 0)
emit_immw:
    call emitw
    jc .r
    cmp byte [op32], 0
    je .r
    cmp ax, 0xFF80
    mov ax, 0
    jb .z
    dec ax
.z: call emitw
.r: ret

; ModRM + смещение для операнда памяти/регистра в [cur_op] с полем reg = [regfld] (0..7)
emit_modrm:
    mov di, [cur_op]
    mov al, [regfld]
    shl al, 3
    cmp byte [di + O_TYPE], OP_MEM
    je .mem
    ; регистр: mod 11
    or al, 0xC0
    or al, [di + O_REG]
    jmp emit
.mem:
    mov ah, [di + O_BASE]
    cmp ah, 0xFF
    jne .based
    or al, 6                        ; mod00 rm110 disp16
    call emit
    jc .r
    mov ax, [di + O_VAL]
    jmp emitw
.based:
    or al, ah
    ; передние ссылки: значение с предыдущего прохода (многопроходная оптимизация, как NASM -Ox)
    mov dx, [di + O_VAL]
    test dx, dx
    jnz .nz
    cmp ah, 6                       ; [bp] требует disp
    je .d8
    jmp emit                        ; mod 00
.nz:
    cmp dx, -128
    jl .d16
    cmp dx, 127
    jg .d16
.d8:
    or al, 0x40
    call emit
    jc .r
    mov al, [di + O_VAL]
    jmp emit
.d16:
    or al, 0x80
    call emit
    jc .r
    mov ax, [di + O_VAL]
    jmp emitw
.r: ret

emit_segp:                          ; префикс сегмента операнда памяти (если есть)
    mov al, [opa + O_SEGP]
    test al, al
    jnz .e
    mov al, [opb + O_SEGP]
    test al, al
    jz .n
.e: call emit_raw
    ret
.n: clc
    ret

; размер операции по операндам -> AL: 1 байт, 2 слово, 0 неизвестно
op_size:
    mov al, [opa + O_SIZE]
    cmp al, 2
    jbe .a
    xor al, al
.a:
    test al, al
    jnz .r
    mov al, [opb + O_SIZE]
    cmp al, 2
    jbe .r
    xor al, al
.r: ret

;---------------------------------------------------------------- обработчики
err_ops:
    mov word [errmsg], e_ops
    stc
    ret
err_size:
    mov word [errmsg], e_size
    stc
    ret

; простая команда без операндов: DX = байт (DH второй байт, если не 0)
h_simple32:                         ; 386: то же с префиксом 66h
    mov byte [op32], 1
h_simple:
    mov al, dl
    call emit
    jc .r
    test dh, dh
    jz .r
    mov al, dh
    call emit
.r: ret

; префикс rep/...: DX байт, затем остаток строки — обычная команда
h_prefix:
    mov al, dl
    call emit
    jc .r
    call skip_sp
    jmp do_instr
.r: ret

; mov
h_mov:
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    mov al, [opa + O_TYPE]
    mov ah, [opb + O_TYPE]
    ; sreg <- r/m16
    cmp al, OP_SREG
    jne .m1
    cmp ah, OP_R16
    je .sr_in
    cmp ah, OP_MEM
    jne err_ops
.sr_in:
    call emit_segp
    mov al, 0x8E
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.m1:
    ; r/m16 <- sreg
    cmp ah, OP_SREG
    jne .m2
    cmp al, OP_R16
    je .sr_out
    cmp al, OP_MEM
    jne err_ops
.sr_out:
    call emit_segp
    mov al, 0x8C
    call emit
    mov al, [opb + O_REG]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.m2:
    cmp ah, OP_IMM
    je .imm
    ; reg <- r/m  (8A/8B) или r/m <- reg (88/89)
    cmp al, OP_R8
    je .reg_dst
    cmp al, OP_R16
    je .reg_dst
    cmp al, OP_MEM
    jne err_ops
    ; mem <- reg
    cmp ah, OP_R8
    je .mem_dst
    cmp ah, OP_R16
    jne err_ops
.mem_dst:
    ; [disp], al/ax -> A2/A3
    cmp byte [opa + O_TYPE], OP_MEM
    jne .mem_dst1
    cmp byte [opa + O_BASE], 0xFF
    jne .mem_dst1
    cmp byte [opb + O_REG], 0
    jne .mem_dst1
    call emit_segp
    mov al, 0xA2
    cmp byte [opb + O_TYPE], OP_R16
    jne .ma1
    inc al
.ma1:
    call emit
    mov ax, [opa + O_VAL]
    jmp emitw
.mem_dst1:
    call emit_segp
    mov al, 0x88
    cmp byte [opb + O_TYPE], OP_R16
    jne .md
    inc al
.md:
    call emit
    mov al, [opb + O_REG]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.reg_dst:
    cmp ah, OP_R8
    je .rr
    cmp ah, OP_R16
    je .rr
    cmp ah, OP_MEM
    jne err_ops
    jmp .rm_src
.rr:
    cmp al, ah
    jne err_size
    jmp .mem_dst                    ; reg,reg — форма 88/89 (как NASM)
.rm_src:
    ; al/ax, [disp] -> A0/A1
    cmp byte [opb + O_TYPE], OP_MEM
    jne .rm_src1
    cmp byte [opb + O_BASE], 0xFF
    jne .rm_src1
    cmp byte [opa + O_REG], 0
    jne .rm_src1
    call emit_segp
    mov al, 0xA0
    cmp byte [opa + O_TYPE], OP_R16
    jne .ma0
    inc al
.ma0:
    call emit
    mov ax, [opb + O_VAL]
    jmp emitw
.rm_src1:
    call emit_segp
    mov al, 0x8A
    cmp byte [opa + O_TYPE], OP_R16
    jne .rs
    inc al
.rs:
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.imm:
    cmp al, OP_R8
    je .r8i
    cmp al, OP_R16
    je .r16i
    cmp al, OP_MEM
    jne err_ops
    ; mem <- imm: C6/C7 /0
    call op_size
    test al, al
    jz err_size
    push ax
    call emit_segp
    mov al, 0xC6
    cmp byte [opa + O_SIZE], 2
    jne .mi
    inc al
.mi:
    call emit
    mov byte [regfld], 0
    mov word [cur_op], opa
    call emit_modrm
    pop ax
    cmp al, 2
    je .mi16
    mov al, [opb + O_VAL]
    jmp emit
.mi16:
    mov ax, [opb + O_VAL]
    jmp emit_immw
.r8i:
    mov al, 0xB0
    add al, [opa + O_REG]
    call emit
    mov al, [opb + O_VAL]
    jmp emit
.r16i:
    mov al, 0xB8
    add al, [opa + O_REG]
    call emit
    mov ax, [opb + O_VAL]
    jmp emit_immw
.r: ret

; группа АЛУ: DX = /digit
h_alu:
    mov [grp], dl
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    mov al, [opa + O_TYPE]
    mov ah, [opb + O_TYPE]
    cmp ah, OP_IMM
    je .imm
    cmp al, OP_MEM
    je .mem_dst
    cmp al, OP_R8
    je .reg_dst
    cmp al, OP_R16
    jne err_ops
.reg_dst:
    cmp ah, OP_MEM
    je .rm_src
    cmp al, ah
    jne err_size
    jmp .md                         ; reg,reg — форма r/m,reg (как NASM)
.rm_src:
    ; reg <- r/m : base+2 (8-бит) / base+3
    call emit_segp
    mov al, [grp]
    shl al, 3
    or al, 2
    cmp byte [opa + O_TYPE], OP_R16
    jne .a1
    inc al
.a1:
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.mem_dst:
    cmp ah, OP_R8
    je .md
    cmp ah, OP_R16
    jne err_ops
.md:
    call emit_segp
    mov al, [grp]
    shl al, 3
    cmp byte [opb + O_TYPE], OP_R16
    jne .a2
    inc al
.a2:
    call emit
    mov al, [opb + O_REG]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.imm:
    call op_size
    test al, al
    jz err_size
    mov [osz], al
    call emit_segp
    ; al/ax, imm -> короткая форма base+4/+5
    cmp byte [opa + O_REG], 0
    jne .not_acc
    mov al, [opa + O_TYPE]
    cmp al, OP_R8
    je .acc8
    cmp al, OP_R16
    jne .not_acc
    ; ax, imm: NASM предпочитает 83 /ib, если imm укладывается в -128..127
    mov ax, [opb + O_VAL]
    cmp ax, -128
    jl .acc16
    cmp ax, 127
    jle .not_acc
.acc16:
    mov al, [grp]
    shl al, 3
    or al, 5
    call emit
    mov ax, [opb + O_VAL]
    jmp emit_immw
.acc8:
    mov al, [grp]
    shl al, 3
    or al, 4
    call emit
    mov al, [opb + O_VAL]
    jmp emit
.not_acc:
    cmp byte [osz], 1
    je .i8
    ; 16 бит: 83 (sign-ext) если imm -128..127, иначе 81
    mov ax, [opb + O_VAL]
    cmp ax, -128
    jl .i16
    cmp ax, 127
    jg .i16
    mov al, 0x83
    call emit
    call .modrm
    mov al, [opb + O_VAL]
    jmp emit
.i16:
    mov al, 0x81
    call emit
    call .modrm
    mov ax, [opb + O_VAL]
    jmp emit_immw
.i8:
    mov al, 0x80
    call emit
    call .modrm
    mov al, [opb + O_VAL]
    jmp emit
.modrm:
    mov al, [grp]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.r: ret

; test
h_test:
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    mov ah, [opb + O_TYPE]
    cmp ah, OP_IMM
    je .imm
    ; test r/m, reg (84/85); reg, r/m — переставить
    mov al, [opa + O_TYPE]
    cmp al, OP_MEM
    je .rm_reg
    cmp ah, OP_MEM
    jne .rr
    ; reg, mem -> swap
    call swap_ops
.rm_reg:
    mov ah, [opb + O_TYPE]
    cmp ah, OP_R8
    je .go
    cmp ah, OP_R16
    jne err_ops
    jmp .go
.rr:
    cmp al, ah
    jne err_size
.go:
    call emit_segp
    mov al, 0x84
    cmp byte [opb + O_TYPE], OP_R16
    jne .g1
    inc al
.g1:
    call emit
    mov al, [opb + O_REG]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.imm:
    call op_size
    test al, al
    jz err_size
    cmp byte [opa + O_REG], 0
    jne .t_gen
    cmp byte [opa + O_TYPE], OP_R8
    je .ta8
    cmp byte [opa + O_TYPE], OP_R16
    jne .t_gen
    mov al, 0xA9
    call emit
    mov ax, [opb + O_VAL]
    jmp emit_immw
.ta8:
    mov al, 0xA8
    call emit
    mov al, [opb + O_VAL]
    jmp emit
.t_gen:
    push ax
    call emit_segp
    mov al, 0xF6
    cmp byte [opa + O_SIZE], 2
    jne .t1
    inc al
.t1:
    call emit
    mov byte [regfld], 0
    mov word [cur_op], opa
    call emit_modrm
    pop ax
    cmp al, 2
    je .t16
    mov al, [opb + O_VAL]
    jmp emit
.t16:
    mov ax, [opb + O_VAL]
    jmp emit_immw
.r: ret

swap_ops:
    push si
    push di
    push cx
    mov si, opa
    mov di, opb
    mov cx, O_LEN
.l: mov al, [si]
    xchg al, [di]
    mov [si], al
    inc si
    inc di
    loop .l
    pop cx
    pop di
    pop si
    ret

; xchg
h_xchg:
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    cmp byte [opa + O_TYPE], OP_MEM
    jne .a
    call swap_ops                   ; xchg reg, mem
.a:
    mov al, [opa + O_TYPE]
    cmp al, OP_R8
    je .g
    cmp al, OP_R16
    jne err_ops
.g:
    mov ah, [opb + O_TYPE]
    cmp ah, OP_MEM
    je .go
    cmp ah, al
    jne err_size
.go:
    cmp al, OP_R16
    jne .gen
    cmp ah, OP_R16
    jne .gen
    cmp byte [opa + O_REG], 0
    je .x_acc_a
    cmp byte [opb + O_REG], 0
    jne .gen
    mov al, [opa + O_REG]
    jmp .x_acc
.x_acc_a:
    mov al, [opb + O_REG]
.x_acc:
    add al, 0x90
    jmp emit
.gen:
    call emit_segp
    mov al, 0x86
    cmp byte [opa + O_TYPE], OP_R16
    jne .x1
    inc al
.x1:
    call emit
    cmp byte [opb + O_TYPE], OP_MEM
    je .x_mem
    mov al, [opb + O_REG]           ; reg,reg: NASM кладёт второй операнд в поле reg
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.x_mem:
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.r: ret

; lea r16, mem
h_lea:
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    cmp byte [opa + O_TYPE], OP_R16
    jne err_ops
    cmp byte [opb + O_TYPE], OP_MEM
    jne err_ops
    call emit_segp
    mov al, 0x8D
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.r: ret

; inc/dec: DX = /0 или /1
h_incdec:
    mov [grp], dl
    call parse_operands
    jc .r
    cmp byte [nops], 1
    jne err_ops
    mov al, [opa + O_TYPE]
    cmp al, OP_R16
    jne .rm
    mov al, 0x40
    cmp byte [grp], 0
    je .q
    mov al, 0x48
.q: add al, [opa + O_REG]
    jmp emit
.rm:
    cmp al, OP_R8
    je .ok
    cmp al, OP_MEM
    jne err_ops
    cmp byte [opa + O_SIZE], 0
    je err_size
.ok:
    call emit_segp
    mov al, 0xFE
    cmp byte [opa + O_SIZE], 2
    jne .e
    inc al
.e: call emit
    mov al, [grp]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.r: ret

; группа F6/F7: not neg mul imul div idiv — DX = /digit
h_grp3:
    mov [grp], dl
    call parse_operands
    jc .r
    cmp byte [nops], 1
    je .one
    cmp byte [nops], 2
    jne err_ops
    cmp byte [grp], 5               ; imul r16, r/m16 | imul r16, imm (386)
    jne err_ops
    cmp byte [opa + O_TYPE], OP_R16
    jne err_ops
    cmp byte [opb + O_TYPE], OP_IMM
    je .imul_imm
    call emit_segp
    mov al, 0x0F
    call emit
    mov al, 0xAF
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.imul_imm:
    mov ax, [opb + O_VAL]
    cmp ax, -128
    jl .imul_w
    cmp ax, 127
    jg .imul_w
    mov al, 0x6B
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opa
    call emit_modrm
    mov al, [opb + O_VAL]
    jmp emit
.imul_w:
    mov al, 0x69
    call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opa
    call emit_modrm
    mov ax, [opb + O_VAL]
    jmp emit_immw
.one:
    mov al, [opa + O_TYPE]
    cmp al, OP_R8
    je .ok
    cmp al, OP_R16
    je .ok
    cmp al, OP_MEM
    jne err_ops
    cmp byte [opa + O_SIZE], 0
    je err_size
.ok:
    call emit_segp
    mov al, 0xF6
    cmp byte [opa + O_SIZE], 2
    jne .e
    inc al
.e: call emit
    mov al, [grp]
    mov [regfld], al
    mov word [cur_op], opa
    jmp emit_modrm
.r: ret

; movzx/movsx r16, r/m8|r/m16 (386): DX = B6/BE
h_movx:
    push dx
    call parse_operands
    pop dx
    jc .r
    cmp byte [nops], 2
    jne err_ops
    cmp byte [opa + O_TYPE], OP_R16
    jne err_ops
    mov al, [opb + O_TYPE]
    cmp al, OP_R8
    je .ok
    cmp al, OP_R16
    je .ok
    cmp al, OP_MEM
    jne err_ops
    cmp byte [opb + O_SIZE], 0
    je err_size
.ok:
    call emit_segp
    mov al, 0x0F
    call emit
    mov al, dl
    cmp byte [opb + O_SIZE], 2
    jne .b
    inc al
.b: call emit
    mov al, [opa + O_REG]
    mov [regfld], al
    mov word [cur_op], opb
    jmp emit_modrm
.r: ret

; сдвиги: DX = /digit; второй операнд 1, cl или imm
h_shift:
    mov [grp], dl
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    mov al, [opa + O_TYPE]
    cmp al, OP_R8
    je .ok
    cmp al, OP_R16
    je .ok
    cmp al, OP_MEM
    jne err_ops
    cmp byte [opa + O_SIZE], 0
    je err_size
.ok:
    call emit_segp
    mov ah, [opb + O_TYPE]
    cmp ah, OP_R8
    jne .imm
    cmp byte [opb + O_REG], 1       ; CL
    jne err_ops
    mov al, 0xD2
    jmp .op
.imm:
    cmp ah, OP_IMM
    jne err_ops
    cmp word [opb + O_VAL], 1
    jne .immn
    mov al, 0xD0
    jmp .op
.immn:
    mov al, 0xC0
.op:
    cmp byte [opa + O_SIZE], 2
    jne .e
    inc al
.e:
    push ax
    call emit
    mov al, [grp]
    mov [regfld], al
    mov word [cur_op], opa
    call emit_modrm
    pop ax
    and al, 0xFE
    cmp al, 0xC0
    jne .d
    mov al, [opb + O_VAL]
    jmp emit
.d: clc
.r: ret

; push / pop: DX = 0 push, 1 pop
h_pushpop:
    mov [grp], dl
    call parse_operands
    jc .r
    cmp byte [nops], 1
    jne err_ops
    mov al, [opa + O_TYPE]
    cmp al, OP_R16
    je .r16
    cmp al, OP_SREG
    je .sreg
    cmp al, OP_IMM
    je .imm
    cmp al, OP_MEM
    jne err_ops
    ; push/pop word [mem]: FF /6, 8F /0
    call emit_segp
    mov al, 0xFF
    mov byte [regfld], 6
    cmp byte [grp], 0
    je .m
    mov al, 0x8F
    mov byte [regfld], 0
.m: call emit
    mov word [cur_op], opa
    jmp emit_modrm
.r16:
    mov al, 0x50
    cmp byte [grp], 0
    je .q
    mov al, 0x58
.q: add al, [opa + O_REG]
    jmp emit
.sreg:
    mov al, [opa + O_REG]
    shl al, 3
    or al, 6
    cmp byte [grp], 0
    je .s
    cmp byte [opa + O_REG], 1       ; pop cs нельзя
    je err_ops
    inc al
.s: jmp emit
.imm:
    cmp byte [grp], 0
    jne err_ops
    mov ax, [opa + O_VAL]
    cmp ax, -128
    jl .i16
    cmp ax, 127
    jg .i16
    mov al, 0x6A
    call emit
    mov al, [opa + O_VAL]
    jmp emit
.i16:
    mov al, 0x68
    call emit
    mov ax, [opa + O_VAL]
    jmp emitw
.r: ret

; jmp
h_jmp:
    call parse_operands
    jc .r
    cmp byte [nops], 1
    jne err_ops
    mov al, [opa + O_TYPE]
    cmp al, OP_IMM
    je .imm
    cmp al, OP_R16
    je .rm
    cmp al, OP_MEM
    jne err_ops
    cmp byte [opa + O_SIZE], 4
    je .farm
.rm:
    call emit_segp
    mov al, 0xFF
    call emit
    mov byte [regfld], 4
    mov word [cur_op], opa
    jmp emit_modrm
.farm:
    call emit_segp
    mov al, 0xFF
    call emit
    mov byte [regfld], 5
    mov word [cur_op], opa
    jmp emit_modrm
.imm:
    cmp byte [opa + O_SIZE], 4
    je .far
    cmp byte [opa + O_SIZE], 3
    je .short
    cmp byte [opa + O_SIZE], 0
    jne .near
    call jump_is_long
    jnc .short
.near:
    ; near rel16
    mov al, 0xE9
    call emit
    mov ax, [opa + O_VAL]
    sub ax, [pc]
    sub ax, 2
    jmp emitw
.short:
    mov al, 0xEB
    call emit
    jmp emit_rel8
.far:
    mov al, 0xEA
    call emit
    mov ax, [opa + O_VAL]
    call emitw
    mov ax, [opa + O_SEG]
    jmp emitw
.r: ret

; rel8 от pc+1 к opa.VAL (с проверкой на 2-м проходе)
emit_rel8:
    mov ax, [opa + O_VAL]
    sub ax, [pc]
    dec ax
    cmp byte [pass], 1
    je .e
    cmp ax, -128
    jl .far
    cmp ax, 127
    jg .far
.e: jmp emit
.far:
    mov word [errmsg], e_range
    stc
    ret

; call
h_call:
    call parse_operands
    jc .r
    cmp byte [nops], 1
    jne err_ops
    mov al, [opa + O_TYPE]
    cmp al, OP_IMM
    je .imm
    cmp al, OP_R16
    je .rm
    cmp al, OP_MEM
    jne err_ops
    cmp byte [opa + O_SIZE], 4
    je .farm
.rm:
    call emit_segp
    mov al, 0xFF
    call emit
    mov byte [regfld], 2
    mov word [cur_op], opa
    jmp emit_modrm
.farm:
    call emit_segp
    mov al, 0xFF
    call emit
    mov byte [regfld], 3
    mov word [cur_op], opa
    jmp emit_modrm
.imm:
    cmp byte [opa + O_SIZE], 4
    je .far
    mov al, 0xE8
    call emit
    mov ax, [opa + O_VAL]
    sub ax, [pc]
    sub ax, 2
    jmp emitw
.far:
    mov al, 0x9A
    call emit
    mov ax, [opa + O_VAL]
    call emitw
    mov ax, [opa + O_SEG]
    jmp emitw
.r: ret

; j<cc> / loop / jcxz: DX = опкод, rel8
h_jcc:
    push dx
    call parse_operands
    pop dx
    jc .r
    cmp byte [nops], 1
    jne err_ops
    cmp byte [opa + O_TYPE], OP_IMM
    jne err_ops
    cmp byte [opa + O_SIZE], 3      ; явный short
    je .short
    call jump_is_long               ; -> CF=1 нужна длинная форма
    jc .near
.short:
    mov al, dl
    call emit
    jmp emit_rel8
.near:
    mov al, 0x0F
    call emit
    mov al, dl
    add al, 0x10
    call emit
    mov ax, [opa + O_VAL]
    sub ax, [pc]
    sub ax, 2
    jmp emitw
.r: ret

; loop/jcxz: только короткая форма
h_loop:
    push dx
    call parse_operands
    pop dx
    jc .r
    cmp byte [nops], 1
    jne err_ops
    cmp byte [opa + O_TYPE], OP_IMM
    jne err_ops
    mov al, dl
    call emit
    jmp emit_rel8
.r: ret

; Решение short/near для перехода без явного размера (opa = цель).
; Каждый такой переход имеет порядковый номер [jidx]; бит в jlong "залипает":
; раз признали длинным — остаётся длинным (так сходится, как оптимизатор NASM).
; -> CF=1 длинный
jump_is_long:
    mov bx, [jidx]
    inc word [jidx]
    mov cx, bx
    and cl, 7
    shr bx, 1
    shr bx, 1
    shr bx, 1
    mov ch, 1
    shl ch, cl
    test [jlong + bx], ch
    jnz .long
    cmp byte [pass], 1
    jne .chk
    cmp byte [opa + O_FWD], 0
    jne .short                      ; 1-й проход, цель впереди — считаем коротким
.chk:
    mov ax, [opa + O_VAL]
    sub ax, [pc]
    sub ax, 2                       ; rel8 считается от конца 2-байтной команды
    cmp ax, -128
    jl .mark
    cmp ax, 127
    jg .mark
.short:
    clc
    ret
.mark:
    or [jlong + bx], ch
    mov byte [changed], 1
.long:
    stc
    ret

; ret/retf: DX = опкод без imm (C3/CB); с операндом — C2/CA
h_ret:
    push dx
    call parse_operands
    pop dx
    jc .r
    cmp byte [nops], 0
    jne .imm
    mov al, dl
    jmp emit
.imm:
    cmp byte [opa + O_TYPE], OP_IMM
    jne err_ops
    mov al, dl
    dec al
    call emit
    mov ax, [opa + O_VAL]
    jmp emitw
.r: ret

; int N
h_int:
    call parse_operands
    jc .r
    cmp byte [nops], 1
    jne err_ops
    cmp byte [opa + O_TYPE], OP_IMM
    jne err_ops
    mov al, 0xCD
    call emit
    mov al, [opa + O_VAL]
    jmp emit
.r: ret

; in al/ax, dx|imm
h_in:
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    mov al, [opa + O_TYPE]
    cmp byte [opa + O_REG], 0       ; AL/AX
    jne err_ops
    mov bl, 0                       ; 0 = byte, 1 = word
    cmp al, OP_R8
    je .sz
    cmp al, OP_R16
    jne err_ops
    mov bl, 1
.sz:
    cmp byte [opb + O_TYPE], OP_R16
    jne .imm
    cmp byte [opb + O_REG], 2       ; DX
    jne err_ops
    mov al, 0xEC
    add al, bl
    jmp emit
.imm:
    cmp byte [opb + O_TYPE], OP_IMM
    jne err_ops
    mov al, 0xE4
    add al, bl
    call emit
    mov al, [opb + O_VAL]
    jmp emit
.r: ret

; out dx|imm, al/ax
h_out:
    call parse_operands
    jc .r
    cmp byte [nops], 2
    jne err_ops
    mov al, [opb + O_TYPE]
    cmp byte [opb + O_REG], 0
    jne err_ops
    mov bl, 0
    cmp al, OP_R8
    je .sz
    cmp al, OP_R16
    jne err_ops
    mov bl, 1
.sz:
    cmp byte [opa + O_TYPE], OP_R16
    jne .imm
    cmp byte [opa + O_REG], 2
    jne err_ops
    mov al, 0xEE
    add al, bl
    jmp emit
.imm:
    cmp byte [opa + O_TYPE], OP_IMM
    jne err_ops
    mov al, 0xE6
    add al, bl
    call emit
    mov al, [opa + O_VAL]
    jmp emit
.r: ret

;---------------------------------------------------------------- директивы
; db / dw: DX = 1 / 2
h_data:
    mov [osz], dl
.item:
    call skip_sp
    cmp byte [si], '"'
    je .str
    cmp byte [si], 0x27
    jne .expr
    ; 'строка' длиной > 1 — тоже строка
    cmp byte [si + 2], 0x27
    je .expr
.str:
    lodsb
    mov ah, al                      ; кавычка
    xor cx, cx                      ; длина строки
.sl:
    lodsb
    test al, al
    jz .unterm
    cmp al, 13
    je .unterm
    cmp al, 10
    je .unterm
    cmp al, ah
    je .se
    push ax
    call emit
    pop ax
    inc cx
    jmp .sl
.se:
    ; строка в dw/dd дополняется нулями до кратной длины (как в NASM)
    mov al, [osz]
    xor ah, ah
    mov bx, ax
    mov ax, cx
    xor dx, dx
    div bx                          ; DX = остаток
    test dx, dx
    jz .next
    mov cx, bx
    sub cx, dx                      ; сколько нулей добавить
.pad:
    push cx
    xor al, al
    call emit
    pop cx
    loop .pad
    jmp .next
.expr:
    call parse_expr
    jc .r
    cmp byte [osz], 2
    je .w
    cmp byte [osz], 4
    je .dd
    call emit
    jmp .next
.dd:
    call emitw
    xor ax, ax
    call emitw
    jmp .next
.w: call emitw
.next:
    call skip_sp
    cmp byte [si], ','
    jne .d
    inc si
    jmp .item
.d: clc
.r: ret
.unterm:
    mov word [errmsg], e_string
    stc
    ret

; times N <директива/команда>
h_times:
    call parse_expr
    jc .r
    mov [times_n], ax
    call skip_sp
    mov [times_si], si
.l:
    cmp word [times_n], 0
    je .d
    mov si, [times_si]
    call peek_ident
    jc .bad
    call get_ident
    call skip_sp
    call find_mnemonic
    jc .bad
    mov ax, [bx]
    mov dx, [bx + 2]
    call ax
    jc .r
    dec word [times_n]
    jmp .l
.d: clc
.r: ret
.bad:
    mov word [errmsg], e_syntax
    stc
    ret

; resb / resw: DX = 1/2
h_res:
    push dx
    call parse_expr
    pop dx
    jc .r
    cmp dl, 2
    jne .cnt
    shl ax, 1
.cnt:
    cmp byte [bss_mode], 0
    je .emit
    add [pc], ax                    ; .bss: только сдвигаем адрес
    clc
    ret
.emit:
    mov cx, ax
    jcxz .d
.z: xor al, al
    call emit
    jc .r
    loop .z
.d: clc
.r: ret

h_org:
    call parse_expr
    jc .r
    mov [origin], ax
    mov [pc], ax
    clc
.r: ret

h_align:
    call parse_expr
    jc .r
    test ax, ax
    jz .d
    mov cx, ax
    ; выравнивание внутри секции поднимает выравнивание самой секции (как в NASM)
    cmp byte [bss_mode], 0
    je .nb
    cmp ax, [bss_align]
    jbe .l
    mov [bss_align], ax
    mov byte [changed], 1
    jmp .l
.nb:
    cmp byte [in_data], 0
    je .l
    cmp ax, [data_align]
    jbe .l
    mov [data_align], ax
    mov byte [changed], 1
.l: mov ax, [pc]
    xor dx, dx
    div cx
    test dx, dx
    jz .d
    cmp byte [bss_mode], 0
    jne .bss
    mov al, 0x90                    ; в коде NASM выравнивает NOP-ами
    cmp byte [in_data], 0
    je .pad
    xor al, al
.pad:
    call emit
    jc .r
    jmp .l
.bss:
    inc word [pc]
    jmp .l
.d: clc
.r: ret

; section .text / .data / .bss  (.data и .bss выравниваются на 4, как в nasm -f bin)
h_section:
    call peek_ident
    jc .bad
    call get_ident
    mov bx, tok
    cmp byte [bx], '.'
    jne .ok
    cmp word [bx + 1], 'BS'
    jne .data
    cmp byte [bx + 3], 'S'
    jne .data
    ; .bss: далее только resb/resw
    mov cx, [bss_align]
.ba: mov ax, [pc]
    xor dx, dx
    div cx
    test dx, dx
    jz .bd
    inc word [pc]
    jmp .ba
.bd:
    mov byte [bss_mode], 1
    clc
    ret
.data:
    cmp word [bx + 1], 'DA'
    jne .text
    cmp byte [bss_mode], 0
    jne .bad
    mov byte [in_data], 1
    mov cx, [data_align]
.al: mov ax, [pc]
    xor dx, dx
    div cx
    test dx, dx
    jz .ok
    xor al, al
    call emit
    jc .r
    jmp .al
.text:
    cmp byte [bss_mode], 0
    jne .bad                        ; после .bss код не поддерживается
.ok:
    clc
.r: ret
.bad:
    mov word [errmsg], e_section
    stc
    ret

h_ignore:                           ; bits 16 / section / cpu ... — до конца строки
    call at_eol
    je .d
    inc si
    jmp h_ignore
.d: clc
    ret

;---------------------------------------------------------------- таблица мнемоник
; запись: dw имя, dw обработчик, dw параметр
; запись: имя ASCIIZ, dw обработчик, dw параметр. find_mnemonic -> BX на dw обработчик
find_mnemonic:
    push si
    push di
    mov si, mtab
.l:
    cmp byte [si], 0
    je .no
    mov di, tok
.c: lodsb
    cmp al, [di]
    jne .n
    inc di
    test al, al
    jnz .c
    mov bx, si
    pop di
    pop si
    clc
    ret
.n: test al, al
    jz .n2
.sk: lodsb
    test al, al
    jnz .sk
.n2: add si, 4
    jmp .l
.no:
    pop di
    pop si
    stc
    ret

%macro M 3
    db %1, 0
    dw %2, %3
%endmacro

mtab:
    M "MOV", h_mov, 0
    M "ADD", h_alu, 0
    M "OR",  h_alu, 1
    M "ADC", h_alu, 2
    M "SBB", h_alu, 3
    M "AND", h_alu, 4
    M "SUB", h_alu, 5
    M "XOR", h_alu, 6
    M "CMP", h_alu, 7
    M "TEST", h_test, 0
    M "XCHG", h_xchg, 0
    M "LEA", h_lea, 0
    M "INC", h_incdec, 0
    M "DEC", h_incdec, 1
    M "NOT", h_grp3, 2
    M "NEG", h_grp3, 3
    M "MUL", h_grp3, 4
    M "IMUL", h_grp3, 5
    M "DIV", h_grp3, 6
    M "IDIV", h_grp3, 7
    M "MOVZX", h_movx, 0xB6
    M "MOVSX", h_movx, 0xBE
    M "ROL", h_shift, 0
    M "ROR", h_shift, 1
    M "RCL", h_shift, 2
    M "RCR", h_shift, 3
    M "SHL", h_shift, 4
    M "SAL", h_shift, 4
    M "SHR", h_shift, 5
    M "SAR", h_shift, 7
    M "PUSH", h_pushpop, 0
    M "POP", h_pushpop, 1
    M "JMP", h_jmp, 0
    M "CALL", h_call, 0
    M "RET", h_ret, 0xC3
    M "RETN", h_ret, 0xC3
    M "RETF", h_ret, 0xCB
    M "INT", h_int, 0
    M "IN", h_in, 0
    M "OUT", h_out, 0
    M "JO", h_jcc, 0x70
    M "JNO", h_jcc, 0x71
    M "JB", h_jcc, 0x72
    M "JC", h_jcc, 0x72
    M "JNAE", h_jcc, 0x72
    M "JNB", h_jcc, 0x73
    M "JAE", h_jcc, 0x73
    M "JNC", h_jcc, 0x73
    M "JE", h_jcc, 0x74
    M "JZ", h_jcc, 0x74
    M "JNE", h_jcc, 0x75
    M "JNZ", h_jcc, 0x75
    M "JBE", h_jcc, 0x76
    M "JNA", h_jcc, 0x76
    M "JA", h_jcc, 0x77
    M "JNBE", h_jcc, 0x77
    M "JS", h_jcc, 0x78
    M "JNS", h_jcc, 0x79
    M "JP", h_jcc, 0x7A
    M "JPE", h_jcc, 0x7A
    M "JNP", h_jcc, 0x7B
    M "JPO", h_jcc, 0x7B
    M "JL", h_jcc, 0x7C
    M "JNGE", h_jcc, 0x7C
    M "JGE", h_jcc, 0x7D
    M "JNL", h_jcc, 0x7D
    M "JLE", h_jcc, 0x7E
    M "JNG", h_jcc, 0x7E
    M "JG", h_jcc, 0x7F
    M "JNLE", h_jcc, 0x7F
    M "JCXZ", h_loop, 0xE3
    M "LOOP", h_loop, 0xE2
    M "LOOPE", h_loop, 0xE1
    M "LOOPZ", h_loop, 0xE1
    M "LOOPNE", h_loop, 0xE0
    M "LOOPNZ", h_loop, 0xE0
    M "REP", h_prefix, 0xF3
    M "REPE", h_prefix, 0xF3
    M "REPZ", h_prefix, 0xF3
    M "REPNE", h_prefix, 0xF2
    M "REPNZ", h_prefix, 0xF2
    M "MOVSB", h_simple, 0xA4
    M "MOVSW", h_simple, 0xA5
    M "CMPSB", h_simple, 0xA6
    M "CMPSW", h_simple, 0xA7
    M "STOSB", h_simple, 0xAA
    M "STOSW", h_simple, 0xAB
    M "LODSB", h_simple, 0xAC
    M "LODSW", h_simple, 0xAD
    M "SCASB", h_simple, 0xAE
    M "SCASW", h_simple, 0xAF
    M "PUSHA", h_simple, 0x60
    M "POPA", h_simple, 0x61
    M "PUSHF", h_simple, 0x9C
    M "POPF", h_simple, 0x9D
    M "IRET", h_simple, 0xCF
    M "INT3", h_simple, 0xCC
    M "INTO", h_simple, 0xCE
    M "CLC", h_simple, 0xF8
    M "STC", h_simple, 0xF9
    M "CMC", h_simple, 0xF5
    M "CLD", h_simple, 0xFC
    M "STD", h_simple, 0xFD
    M "CLI", h_simple, 0xFA
    M "STI", h_simple, 0xFB
    M "HLT", h_simple, 0xF4
    M "NOP", h_simple, 0x90
    M "CBW", h_simple, 0x98
    M "CWD", h_simple, 0x99
    M "CWDE", h_simple32, 0x98
    M "CDQ", h_simple32, 0x99
    M "PUSHAD", h_simple32, 0x60
    M "POPAD", h_simple32, 0x61
    M "LAHF", h_simple, 0x9F
    M "SAHF", h_simple, 0x9E
    M "XLAT", h_simple, 0xD7
    M "XLATB", h_simple, 0xD7
    M "WAIT", h_simple, 0x9B
    M "LEAVE", h_simple, 0xC9
    M "DB", h_data, 1
    M "DW", h_data, 2
    M "DD", h_data, 4
    M "TIMES", h_times, 0
    M "RESB", h_res, 1
    M "RESW", h_res, 2
    M "ORG", h_org, 0
    M "ALIGN", h_align, 0
    M "ALIGNB", h_align, 0
    M "BITS", h_ignore, 0
    M "SECTION", h_section, 0
    M "SEGMENT", h_section, 0
    M "CPU", h_ignore, 0
    M "USE16", h_ignore, 0
    db 0

;---------------------------------------------------------------- данные
msg_usage   db "iron - frasm assembler (8086/186, flat binary)", 13, 10
            db "Usage: iron SOURCE.ASM OUT.FAP", 13, 10, 0
msg_noread  db "iron: cannot read source", 13, 10, 0
msg_nowrite db "iron: cannot write output", 13, 10, 0
msg_ok1     db "iron: ok, ", 0
msg_ok2     db " bytes -> ", 0
msg_ok3     db " (", 0
msg_ok4     db " symbols, ", 0
msg_ok5     db " passes)", 13, 10, 0
s_endif     db "ENDIF", 0
s_else      db "ELSE", 0
s_ifdef     db "IFDEF", 0
s_ifndef    db "IFNDEF", 0
s_define    db "DEFINE", 0
s_include   db "INCLUDE", 0
s_macro     db "MACRO", 0
s_endmacro  db "ENDMACRO", 0
msg_colon   db ":", 0
msg_colon2  db ": error: ", 0
crlf        db 13, 10, 0
e_syntax    db "syntax error", 0
e_unknown   db "unknown instruction or directive", 0
e_junk      db "unexpected text after instruction", 0
e_dup       db "symbol already defined", 0
e_toomany   db "too many symbols", 0
e_internal  db "internal error", 0
e_undef     db "undefined symbol", 0
e_div0      db "division by zero", 0
e_expr      db "bad expression", 0
e_number    db "bad number", 0
e_addr      db "bad address expression", 0
e_ops       db "invalid operands", 0
e_size      db "operand size not specified", 0
e_big       db "output too large", 0
e_range     db "short jump out of range", 0
e_string    db "unterminated string", 0
e_pp        db "unsupported preprocessor directive", 0
e_noinc     db "cannot read include file", 0
e_nest      db "nested %include is not supported", 0
e_endm      db "%endmacro not found", 0
e_section   db "bad section usage (data after .bss?)", 0

; операнд (структура)
O_TYPE   equ 0
O_REG    equ 1
O_SIZE   equ 2                      ; 0 ?, 1 byte, 2 word, 3 short, 4 far
O_SEGP   equ 3
O_FWD    equ 4
O_BASE   equ 5                      ; r/m код или 0xFF
O_HASD   equ 6
O_BXF    equ 7
O_BPF    equ 8
O_SIF    equ 9
O_DIF    equ 10
O_VAL    equ 12
O_SEG    equ 14
O_LEN    equ 16

opa         times O_LEN db 0
opb         times O_LEN db 0
cur_op      dw opa
nops        db 0
op32        db 0                    ; 1 = нужен префикс 66h, 2 = уже выдан
regfld      db 0
grp         db 0
osz         db 0
sign        db 0
nondec      db 0
fwd         db 0
pass        db 1
prefix      db 0
pc          dw 0
origin      dw 0
outlen      dw 0
main_len    dw 0
append      dw 0
spos        dw 0
send        dw 0
fname       dw srcpath
sv_pos      dw 0
sv_end      dw 0
sv_line     dw 0
sv_fname    dw 0
sv_seg      dw 0
sseg        dw 0
seg_main    dw 0
seg_inc     dw 0
mx_seg      dw 0
inc_depth   db 0
pp_skip     db 0
pp_err      db 0
bss_mode    db 0
in_data     db 0
mx_active   db 0
mx_pos      dw 0
mx_end      dw 0
mx_id       dw 0
lbl_end     dw 0
nmac        dw 0
ninc        dw 0
ndef        dw 0
sym_val     dw 0
jidx        dw 0
bss_align   dw 4
data_align  dw 4
changed     db 0
sym_line    dw 0
lineno      dw 0
lstart      dw 0
nsyms       dw 0
eqval       dw 0
times_n     dw 0
times_si    dw 0
errmsg      dw e_syntax
TOK_RAW  equ 34                     ; смещение копии в исходном регистре
tok         times 68 db 0
tok2        times 68 db 0
lastglob    times 34 db 0
fullname    times 70 db 0
srcpath     times 80 db 0
outpath     times 80 db 0

section .bss
syms        resb SYM_MAX * SYM_SIZE
outbuf      resb OUT_MAX
linebuf     resb LINE_MAX
argbuf      resb 300
arg_off     resw ARG_MAX + 1
macs        resb MAC_MAX * MAC_SIZE
incs        resb INC_MAX * INC_SIZE
defs        resb DEF_MAX * 32
incpath     resb 120
JL_BYTES equ 512                    ; до 4096 переходов
jlong       resb JL_BYTES
