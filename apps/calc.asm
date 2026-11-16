;======================================
; File name: apps/calc.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: calc — калькулятор (внешняя программа .FAP)
;======================================
; calc EXPR        — вычислить и напечатать
; calc             — оконный режим: кнопки, мышь и клавиатура, Esc — выход (также calc -g)
; calc -c          — консольный диалог: calc> ... (пустая строка/q — выход)
; Целые 32-битные со знаком: + - * / % ( ) унарный минус, 0x... — шестнадцатеричные.

%include "fapi.inc"
    cpu 386

EXPR_MAX equ 60

    FAPI_HEADER

start:
    cld
    mov si, 0x80
    call skip_sp
    cmp byte [si], 0
    je gui_mode
    cmp word [si], '-g'
    je gui_mode
    cmp word [si], '-c'
    je text_repl
    ; --- calc EXPR ---
    mov di, expr
    call copy_line
    call eval_print
    FAPI FAPI_PUTS
    FAPI_PRINT s_crlf
    FAPI_QUIT

;---------------------------------------------------------------- текстовый диалог
text_repl:
    FAPI_PRINT s_hello
.loop:
    FAPI_PRINT s_prompt
    mov di, expr
    mov cx, EXPR_MAX
    call read_line                  ; -> expr (ASCIIZ), CF=1 если Esc
    jc .quit
    mov si, expr
    call skip_sp
    cmp byte [si], 0
    je .quit
    cmp word [si], 'q'              ; "q",0
    je .quit
    call eval_print
    push si
    FAPI_PRINT s_eq
    pop si
    FAPI FAPI_PUTS
    FAPI_PRINT s_crlf
    jmp .loop
.quit:
    FAPI_QUIT

; ввод строки с клавиатуры в DS:DI (CX макс), Enter завершает; CF=1 при Esc
read_line:
    push bx
    xor bx, bx
.rl:
    FAPI FAPI_GETKEY
    cmp al, 13
    je .rl_done
    cmp al, 27
    je .rl_esc
    cmp al, 8
    je .rl_bs
    cmp al, ' '
    jb .rl
    cmp bx, cx
    jae .rl
    mov [di + bx], al
    inc bx
    FAPI FAPI_PUTC
    jmp .rl
.rl_bs:
    test bx, bx
    jz .rl
    dec bx
    FAPI_PRINT s_bs
    jmp .rl
.rl_done:
    mov byte [di + bx], 0
    FAPI_PRINT s_crlf
    pop bx
    clc
    ret
.rl_esc:
    mov byte [di], 0
    FAPI_PRINT s_crlf
    pop bx
    stc
    ret

; вычислить expr -> SI = строка результата или ошибки
eval_print:
    mov si, expr
    call evaluate                   ; -> EAX, CF=1 ошибка (SI -> сообщение)
    jc .ep_r
    mov di, outbuf
    call i32_to_str
    mov si, outbuf
.ep_r:
    ret

;---------------------------------------------------------------- разбор выражения
; DS:SI = выражение. -> EAX результат, CF=0; или CF=1, SI -> текст ошибки
evaluate:
    mov [p_ptr], si
    mov byte [p_depth], 0
    call parse_expr
    jc .ev_err
    mov si, [p_ptr]
    call skip_sp
    mov [p_ptr], si
    cmp byte [si], 0
    jne .ev_syntax
    clc
    ret
.ev_syntax:
    mov si, e_syntax
.ev_err:
    stc
    ret

; expr := term (('+'|'-') term)*
parse_expr:
    inc byte [p_depth]
    cmp byte [p_depth], 40
    ja .pe_deep
    call parse_term
    jc .pe_r
.pe_loop:
    push eax
    call peek
    cmp al, '+'
    je .pe_add
    cmp al, '-'
    je .pe_sub
    pop eax
    clc
    jmp .pe_r
.pe_add:
    inc word [p_ptr]
    call parse_term
    pop ebx
    jc .pe_r
    add eax, ebx
    jmp .pe_loop
.pe_sub:
    inc word [p_ptr]
    call parse_term
    pop ebx
    jc .pe_r
    sub ebx, eax
    mov eax, ebx
    jmp .pe_loop
.pe_deep:
    mov si, e_deep
    stc
.pe_r:
    dec byte [p_depth]
    ret

; term := factor (('*'|'/'|'%') factor)*
parse_term:
    call parse_factor
    jc .pt_r
.pt_loop:
    push eax
    call peek
    cmp al, '*'
    je .pt_mul
    cmp al, '/'
    je .pt_div
    cmp al, '%'
    je .pt_mod
    pop eax
    clc
.pt_r:
    ret
.pt_mul:
    inc word [p_ptr]
    call parse_factor
    pop ebx
    jc .pt_r
    imul eax, ebx
    jmp .pt_loop
.pt_div:
    inc word [p_ptr]
    call parse_factor
    pop ebx
    jc .pt_r
    call sdiv                       ; EBX / EAX -> EAX частное, EDX остаток
    jc .pt_r
    jmp .pt_loop
.pt_mod:
    inc word [p_ptr]
    call parse_factor
    pop ebx
    jc .pt_r
    call sdiv
    jc .pt_r
    mov eax, edx
    jmp .pt_loop

; EBX / EAX -> EAX, EDX; CF=1 при делении на ноль
sdiv:
    test eax, eax
    jz .sd_zero
    mov ecx, eax
    mov eax, ebx
    cdq
    idiv ecx
    clc
    ret
.sd_zero:
    mov si, e_div0
    stc
    ret

; factor := '-' factor | '+' factor | '(' expr ')' | number
parse_factor:
    call peek
    cmp al, '-'
    je .pf_neg
    cmp al, '+'
    je .pf_pos
    cmp al, '('
    je .pf_par
    cmp al, '0'
    jb .pf_bad
    cmp al, '9'
    ja .pf_bad
    jmp parse_number
.pf_neg:
    inc word [p_ptr]
    call parse_factor
    jc .pf_r
    neg eax
    clc
    ret
.pf_pos:
    inc word [p_ptr]
    jmp parse_factor
.pf_par:
    inc word [p_ptr]
    call parse_expr
    jc .pf_r
    push eax
    call peek
    mov bl, al
    pop eax
    cmp bl, ')'
    jne .pf_paren
    inc word [p_ptr]
    clc
.pf_r:
    ret
.pf_paren:
    mov si, e_paren
    stc
    ret
.pf_bad:
    mov si, e_syntax
    test al, al
    jnz .pf_r2
    mov si, e_empty
.pf_r2:
    stc
    ret

; число: десятичное или 0x...; -> EAX
parse_number:
    mov si, [p_ptr]
    xor eax, eax
    cmp word [si], '0x'
    je .pn_hex
    cmp word [si], '0X'
    je .pn_hex
.pn_dec:
    movzx ebx, byte [si]
    cmp bl, '0'
    jb .pn_done
    cmp bl, '9'
    ja .pn_done
    sub bl, '0'
    imul eax, 10
    add eax, ebx
    inc si
    jmp .pn_dec
.pn_hex:
    add si, 2
.pn_hl:
    mov bl, [si]
    cmp bl, '0'
    jb .pn_done
    cmp bl, '9'
    jbe .pn_hd
    or bl, 0x20
    cmp bl, 'a'
    jb .pn_done
    cmp bl, 'f'
    ja .pn_done
    sub bl, 'a' - 10 - '0'
.pn_hd:
    sub bl, '0'
    movzx ebx, bl
    shl eax, 4
    add eax, ebx
    inc si
    jmp .pn_hl
.pn_done:
    mov [p_ptr], si
    clc
    ret

; пропустить пробелы, AL = следующий символ (не сдвигая указатель)
peek:
    mov si, [p_ptr]
    call skip_sp
    mov [p_ptr], si
    mov al, [si]
    ret

skip_sp:
    cmp byte [si], ' '
    jne .r
    inc si
    jmp skip_sp
.r: ret

; скопировать строку DS:SI -> DS:DI (до EXPR_MAX)
copy_line:
    push cx
    mov cx, EXPR_MAX
.cl:
    lodsb
    stosb
    test al, al
    jz .cl_r
    loop .cl
    mov byte [di - 1], 0
.cl_r:
    pop cx
    ret

; EAX (знаковое) -> ASCIIZ в DS:DI
i32_to_str:
    push eax
    push ebx
    push ecx
    push edx
    test eax, eax
    jns .pos
    mov byte [di], '-'
    inc di
    neg eax
.pos:
    mov ebx, 10
    xor cx, cx
.div:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .div
.out:
    pop ax
    add al, '0'
    stosb
    loop .out
    mov byte [di], 0
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

;---------------------------------------------------------------- оконный режим
WX   equ 24                         ; левый столбец окна
WY   equ 3                          ; верхняя строка
WW   equ 32
WH   equ 19
A_WIN equ 0x70
A_DSP equ 0x1F
A_BTN equ 0x2F
A_BOP equ 0x4F
A_TTL equ 0x30

gui_mode:
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    mov byte [expr], 0
    mov byte [g_fresh], 0
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    FAPI FAPI_CLS
    call g_draw_all
.loop:
    call g_draw_display
.wait:
    FAPI FAPI_KEYHIT
    jnz .key
    call g_mouse
    jc .loop
    hlt
    jmp .wait
.key:
    FAPI FAPI_GETKEY
    cmp al, 27
    je .quit
    cmp al, 13
    je .enter
    cmp al, 8
    je .bs
    cmp al, '='
    je .enter
    cmp al, 'c'
    je .clear
    cmp al, 'C'
    je .clear
    call g_is_char
    jc .loop
    call g_append
    jmp .loop
.enter:
    call g_eval
    jmp .loop
.bs:
    call g_backspace
    jmp .loop
.clear:
    mov byte [expr], 0
    mov byte [g_fresh], 0
    jmp .loop
.quit:
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

; CF=1 если AL не допустимый символ выражения
g_is_char:
    cmp al, ' '
    je .ok
    cmp al, '0'
    jb .chk
    cmp al, '9'
    jbe .ok
.chk:
    push si
    mov si, g_ops
.l:
    cmp byte [si], 0
    je .no
    cmp al, [si]
    je .yes
    inc si
    jmp .l
.yes:
    pop si
.ok:
    clc
    ret
.no:
    pop si
    stc
    ret

; добавить символ AL к expr
g_append:
    push di
    cmp byte [g_fresh], 0           ; показан результат: цифра начинает новое выражение
    je .ga_go
    mov byte [g_fresh], 0
    cmp al, '0'
    jb .ga_go
    cmp al, '9'
    ja .ga_go
    mov byte [expr], 0
.ga_go:
    mov di, expr
    call str_end
    cmp di, expr + EXPR_MAX - 1
    jae .ga_r
    stosb
    mov byte [di], 0
.ga_r:
    pop di
    ret

g_backspace:
    push di
    mov byte [g_fresh], 0
    mov di, expr
    call str_end
    cmp di, expr
    je .gb_r
    mov byte [di - 1], 0
.gb_r:
    pop di
    ret

; DI -> конец строки (на 0)
str_end:
    cmp byte [di], 0
    je .r
    inc di
    jmp str_end
.r: ret

g_eval:
    mov si, expr
    call skip_sp
    cmp byte [si], 0
    je .ge_r
    call eval_print                 ; SI -> результат/ошибка
    push ds
    pop es
    mov di, expr
    call copy_line
    mov byte [g_fresh], 1
.ge_r:
    ret

; --- рисование ---
g_draw_all:
    ; окно
    mov dh, WY
    mov dl, WX
    mov ch, WH
    mov cl, WW
    mov al, ' '
    mov bl, A_WIN
    FAPI FAPI_FILLRECT
    ; заголовок
    mov dh, WY
    mov dl, WX
    mov ch, 1
    mov cl, WW
    mov al, ' '
    mov bl, A_TTL
    FAPI FAPI_FILLRECT
    mov si, s_title
    mov dh, WY
    mov dl, WX + 1
    mov bl, A_TTL
    FAPI FAPI_PUTSAT
    mov si, s_esc
    mov dh, WY
    mov dl, WX + WW - 10
    mov bl, A_TTL
    FAPI FAPI_PUTSAT
    ; кнопки
    xor bx, bx                      ; индекс кнопки
.btn:
    cmp bx, 20
    jae .done
    call g_btn_pos                  ; -> DH,DL позиция, AL метка
    push bx
    push ax
    mov ch, 1
    mov cl, 6
    mov al, ' '
    mov bl, A_BTN
    cmp byte [g_islabel], 0
    je .b1
    mov bl, A_BOP
.b1:
    FAPI FAPI_FILLRECT
    pop ax
    pop bx
    push bx
    mov si, g_labels
    mov ax, bx
    shl ax, 1
    shl ax, 1                       ; 4 байта на метку
    add si, ax
    add dl, 2
    mov bl, A_BTN
    cmp byte [g_islabel], 0
    je .b2
    mov bl, A_BOP
.b2:
    FAPI FAPI_PUTSAT
    pop bx
    inc bx
    jmp .btn
.done:
    ret

; BX = индекс (0..19) -> DH строка, DL столбец кнопки; g_islabel=1 для операций
g_btn_pos:
    push ax
    mov ax, bx
    push bx
    mov bl, 4
    div bl                          ; AL = ряд, AH = колонка
    mov dh, al
    add dh, dh                      ; ряды через строку
    add dh, WY + 4
    mov dl, ah
    mov bl, 7
    push ax
    mov al, ah
    mul bl
    mov dl, al
    pop ax
    add dl, WX + 2
    pop bx
    mov byte [g_islabel], 0
    cmp bx, 15                      ; нижний ряд и правый столбец — операции
    jb .gp_chk
    mov byte [g_islabel], 1
    jmp .gp_r
.gp_chk:
    cmp ah, 3
    jne .gp_r
    mov byte [g_islabel], 1
.gp_r:
    pop ax
    ret

g_draw_display:
    mov dh, WY + 2
    mov dl, WX + 2
    mov ch, 1
    mov cl, WW - 4
    mov al, ' '
    mov bl, A_DSP
    FAPI FAPI_FILLRECT
    ; правое выравнивание (последние 27 символов)
    mov si, expr
    push ds
    pop es
    mov di, si
    call str_end
    mov cx, di
    sub cx, si                      ; длина
    mov ax, cx
    cmp ax, WW - 5
    jbe .fit
    sub ax, WW - 5
    add si, ax
    mov cx, WW - 5
.fit:
    mov dl, WX + WW - 3
    sub dl, cl
    mov dh, WY + 2
    mov bl, A_DSP
    FAPI FAPI_PUTSAT
    ret

; --- мышь: CF=1 если было действие ---
g_mouse:
    FAPI FAPI_MOUSE
    test ah, ah
    jz .none
    mov bl, al
    xor bl, [g_mprev]
    and bl, al
    mov [g_mprev], al
    test bl, 1
    jz .none
    ; найти кнопку под (CX, DX)
    mov [g_mcol], cx
    mov [g_mrow], dx
    xor bx, bx
.find:
    cmp bx, 20
    jae .none
    call g_btn_pos
    xor ah, ah
    mov al, dh
    cmp ax, [g_mrow]
    jne .next
    mov al, dl
    cmp [g_mcol], ax
    jb .next
    add ax, 6
    cmp [g_mcol], ax
    jb .hit
.next:
    inc bx
    jmp .find
.hit:
    mov si, g_keys
    mov al, [si + bx]
    cmp al, '='
    je .eq
    cmp al, 'C'
    je .clr
    cmp al, 8
    je .bs
    call g_append
    stc
    ret
.eq:
    call g_eval
    stc
    ret
.clr:
    mov byte [expr], 0
    mov byte [g_fresh], 0
    stc
    ret
.bs:
    call g_backspace
    stc
    ret
.none:
    clc
    ret

;---------------------------------------------------------------- данные
s_hello  db "calc: integer calculator (+ - * / % parentheses, 0x hex). Empty line or q = exit.", 13, 10, 0
s_prompt db "calc> ", 0
s_eq     db "= ", 0
s_crlf   db 13, 10, 0
s_bs     db 8, " ", 8, 0
s_title  db " calc ", 0
s_esc    db "Esc exit ", 0
e_syntax db "Syntax error", 0
e_empty  db "Empty expression", 0
e_paren  db "Missing )", 0
e_div0   db "Division by zero", 0
e_deep   db "Too deep", 0
g_ops    db "+-*/%()", 0
; кнопки 5x4: метки (4 байта каждая) и символы
g_labels db "7",0,0,0, "8",0,0,0, "9",0,0,0, "/",0,0,0
         db "4",0,0,0, "5",0,0,0, "6",0,0,0, "*",0,0,0
         db "1",0,0,0, "2",0,0,0, "3",0,0,0, "-",0,0,0
         db "0",0,0,0, "(",0,0,0, ")",0,0,0, "+",0,0,0
         db "C",0,0,0, "<-",0,0,  "%",0,0,0, "=",0,0,0
g_keys   db "789/456*123-0()+C", 8, "%="
g_islabel db 0
g_fresh  db 0
g_mprev  db 0
g_mcol   dw 0
g_mrow   dw 0
p_ptr    dw 0
p_depth  db 0
expr     times EXPR_MAX + 1 db 0
outbuf   times 16 db 0
