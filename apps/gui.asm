;======================================
; File name: apps/gui.asm
; Project: FERRIX-OS
; Description: gui — оконный менеджер и рабочий стол (внешняя программа .FAP)
;======================================
; gui                — рабочий стол с обоями из /SYSTEM/GUI.CFG (по умолчанию синий тон)
; gui -t N           — обои: тон N (0..7), сохраняется
; gui -w FILE.BMP    — обои: картинка BMP (8/24 бит), сохраняется
;
; Как это работает. gui ставит себя обработчиком оконного менеджера (FAPI_WM):
; с этого момента ядро отдаёт gui все int 80h из любых других сегментов.
; Каждая программа .FAP загружается в свой сегмент (5000h, 7000h, 8000h), получает
; виртуальный экран 80x25 (его сегмент лежит в слове 0010h программы) и окно с рамкой.
; Вывод (putc/puts/putat/...) gui рисует в виртуальный экран, ввод (getkey/mouse)
; отдаёт активному окну. Многозадачность кооперативная: программа, ждущая клавишу,
; «паркуется» (сохраняется SS:SP), а управление передаётся другому окну.
; Экран — текстовый режим 80x50; строка 49 — панель задач.
; Первое окно — FM; его закрытие завершает gui.

%include "fapi.inc"

MAXWIN   equ 3
ROWS     equ 50
TBROW    equ 49                     ; панель задач
GUI_SEG  equ 0x4000

; запись окна
W_USED   equ 0                      ; db 0 свободно / 1 занято
W_MIN    equ 1                      ; db свёрнуто
W_SEG    equ 2                      ; dw сегмент программы
W_X      equ 4                      ; dw столбец (со знаком)
W_Y      equ 6                      ; dw строка заголовка
W_SS     equ 8                      ; dw сохранённый SS
W_SP     equ 10                     ; dw сохранённый SP
W_ENTRY  equ 12                     ; dw точка входа
W_CURR   equ 14                     ; db курсор строка
W_CURC   equ 15                     ; db курсор столбец
W_CVIS   equ 16                     ; db курсор виден
W_PEND   equ 17                     ; db есть отложенная команда (exec)
W_PPAUSE equ 18                     ; db пауза после команды
W_MAINW  equ 19                     ; db главное окно (FM) — закрытие завершает gui
W_VSEG   equ 20                     ; dw сегмент виртуального экрана
W_TITLE  equ 22                     ; 16 байт
W_PATH   equ 38                     ; 80 байт — путь программы
W_ARGS   equ 118                    ; 128 байт — аргументы
W_CMD    equ 246                    ; 128 байт — отложенная команда
W_CX0    equ 374                    ; dw левый столбец содержимого (авторазмер)
W_CY0    equ 376                    ; dw верхняя строка содержимого
W_W      equ 378                    ; dw ширина окна (знакомест)
W_H      equ 380                    ; dw высота содержимого (строк)
W_ANIM   equ 382                    ; db 1 = окно уже показано (анимация открытия сыграна)
W_SIZE   equ 384
MINW     equ 24                     ; минимальная ширина окна

; кадр регистров программы в обработчике (после push es/push ds/pusha), SS:BP
F_DI equ 0
F_SI equ 2
F_BP equ 4
F_BX equ 8
F_DX equ 10
F_CX equ 12
F_AX equ 14
F_DS equ 16
F_ES equ 18

REQ_NONE  equ 0
REQ_SPAWN equ 1
REQ_CLOSE equ 2
REQ_SHOW  equ 3                     ; показать окно req_win (после idle)
REQ_QUIT  equ 4

A_TACT   equ 0x1F                   ; заголовок активного окна
A_TINA   equ 0x78                   ; заголовок неактивного
A_TBAR   equ 0x70                   ; панель задач
A_BTN    equ 0x4F                   ; кнопка закрытия
A_SHADOW equ 0x08                   ; тень окна (тёмно-серый на чёрном)
A_ANIM   equ 0x0F                   ; рамка анимации
ANIM_STEPS equ 6

    FAPI_HEADER

start:
    cld
    mov [main_sp_init], sp
    ; сегменты виртуальных экранов (буферы выровнены на параграф)
    mov ax, vscr0
    call seg_of
    mov [windows + W_VSEG], ax
    mov ax, vscr1
    call seg_of
    mov [windows + W_SIZE + W_VSEG], ax
    mov ax, vscr2
    call seg_of
    mov [windows + 2 * W_SIZE + W_VSEG], ax
    ; --- аргументы ---
    call cfg_load
    mov si, 0x80
    call skip_sp
    cmp byte [si], 0
    je .args_done
    cmp word [si], '-t'
    je .arg_tone
    cmp word [si], '-w'
    je .arg_wall
    jmp .usage
.arg_tone:
    add si, 2
    call skip_sp
    mov al, [si]
    sub al, '0'
    cmp al, 7
    ja .usage
    mov [cfg_tone], al
    mov byte [cfg_wall], 0
    call cfg_save
    jmp .args_done
.arg_wall:
    add si, 2
    call skip_sp
    cmp byte [si], 0
    je .usage
    mov di, cfg_wall
    mov cx, 79
.cw:
    lodsb
    cmp al, ' '
    je .cw_end
    test al, al
    jz .cw_end
    stosb
    loop .cw
.cw_end:
    mov byte [di], 0
    call cfg_save
.args_done:
    ; --- экран 80x50, обои ---
    call screen_init
    call wall_build
    ; --- установить оконный менеджер ---
    mov al, 0
    mov dx, wm_entry
    mov cl, ROWS
    FAPI FAPI_WM
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    ; --- первое окно: FM ---
    mov si, s_fmpath
    mov di, s_empty
    call spawn                      ; -> AX окно или CF
    jc .nofm
    mov bx, ax
    call win_ptr
    mov byte [bx + W_MAINW], 1
    mov [req_win], ax
    mov byte [req], REQ_SHOW
    jmp main_loop
.nofm:
    call screen_restore
    FAPI_PRINT s_nofm
    FAPI_QUIT
.usage:
    FAPI_PRINT s_usage
    FAPI_QUIT

;---------------------------------------------------------------- главный поток
; Обрабатывает запросы окон (req), затем отдаёт управление активному окну.
main_loop:
    mov al, [req]
    mov byte [req], REQ_NONE
    cmp al, REQ_QUIT
    je shutdown
    cmp al, REQ_SPAWN
    je .spawn
    cmp al, REQ_CLOSE
    je .close
    jmp .pick
.spawn:
    mov si, req_path
    mov di, req_args
    call spawn
    jnc .pick
    mov si, s_nowin
    call tb_message
    jmp .pick
.close:
    mov ax, [req_win]
    call win_close                  ; выполняет отложенную команду / перезапускает / освобождает
    cmp byte [req], REQ_QUIT
    je shutdown
.pick:
    ; ещё не запущенные окна — запустить (они нарисуются и уступят верхнему)
    xor cx, cx
.kick:
    mov ax, cx
    call win_ptr
    cmp byte [bx + W_USED], 0
    je .kn
    cmp byte [bx + W_MIN], 0
    jne .kn
    cmp word [bx + W_SP], 0xFFF6
    jne .kn
    call switch_to                  ; вернёмся по следующему запросу
    jmp main_loop
.kn:
    inc cx
    cmp cx, MAXWIN
    jb .kick
    call top_visible                ; -> AX окно или CF
    jc .idle
    call switch_to                  ; вернёмся сюда с новым req
    jmp main_loop
.idle:
    ; нет видимых окон: ждём клика по панели задач (или Esc — выход, если окон нет вовсе)
    call pump_iter
    cmp byte [req], REQ_NONE
    jne main_loop
    call any_window
    jnc .idle_key
    mov byte [req], REQ_QUIT        ; окон не осталось
    jmp main_loop
.idle_key:
    mov ah, 0x11
    int 0x16
    jz .idle_hlt
    mov ah, 0x10
    int 0x16                        ; клавиши в простое игнорируем
.idle_hlt:
    hlt
    jmp .idle

shutdown:
    mov al, 1
    FAPI FAPI_WM                    ; снять обработчик
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    call screen_restore
    FAPI FAPI_UIREDRAW
    mov ax, [main_sp_init]
    mov sp, ax
    FAPI_QUIT

;---------------------------------------------------------------- переключение контекстов
; AX = окно -> стать текущим (сохранив текущий контекст)
switch_to:
    push bx
    mov bx, ax
    call win_ptr
    lea di, [bx + W_SS]
    mov [cur_win], ax
    pop bx
    jmp ctx_switch
; переключиться на главный поток
switch_to_main:
    mov di, main_ctx
    mov word [cur_win], -1
    jmp ctx_switch
; общий переключатель: сохранить SS:SP в [cur_ctx], загрузить из DI, cur_ctx = DI
ctx_switch:
    push bp
    push si
    mov si, [cur_ctx]
    mov [si], ss
    mov [si + 2], sp
    mov [cur_ctx], di
    cli
    mov ss, [di]
    mov sp, [di + 2]
    sti
    pop si
    pop bp
    ret

; первая активация окна: сюда приходит ctx_switch по подготовленному стеку
start_app:
    mov ax, [cur_win]
    call win_ptr
    mov ax, [bx + W_SEG]
    push ax
    push word [bx + W_ENTRY]
    mov ds, ax
    mov es, ax
    mov si, 0x80
    xor ax, ax
    xor bx, bx
    xor cx, cx
    xor dx, dx
    xor di, di
    xor bp, bp
    retf
; программа вышла через retf
app_retf_stub:
    mov ax, cs
    mov ds, ax
    jmp do_exit

;---------------------------------------------------------------- окна
; AX = индекс -> BX = адрес записи
win_ptr:
    push ax
    push dx
    mov bx, W_SIZE
    mul bx
    add ax, windows
    mov bx, ax
    pop dx
    pop ax
    ret

; верхнее видимое окно -> AX; CF=1 нет
top_visible:
    push bx
    push cx
    mov cx, [zcount]
.l:
    jcxz .none
    dec cx
    mov bx, cx
    mov al, [zorder + bx]
    xor ah, ah
    push ax
    call win_ptr
    pop ax
    cmp byte [bx + W_MIN], 0
    jne .l
    pop cx
    pop bx
    clc
    ret
.none:
    pop cx
    pop bx
    stc
    ret

; есть ли хоть одно окно: CF=1 нет
any_window:
    cmp word [zcount], 0
    je .no
    clc
    ret
.no:
    stc
    ret

; поднять окно AX наверх z-порядка
z_raise:
    push bx
    push cx
    push si
    push di
    call z_remove
    mov bx, [zcount]
    mov [zorder + bx], al
    inc word [zcount]
    pop di
    pop si
    pop cx
    pop bx
    ret
; убрать окно AX из z-порядка
z_remove:
    push bx
    push cx
    xor bx, bx
.find:
    cmp bx, [zcount]
    jae .done
    cmp [zorder + bx], al
    je .shift
    inc bx
    jmp .find
.shift:
    mov cx, [zcount]
    dec cx
    sub cx, bx
    jcxz .last
.sh:
    mov ch, [zorder + bx + 1]
    mov [zorder + bx], ch
    inc bx
    dec cl
    jnz .sh
.last:
    dec word [zcount]
.done:
    pop cx
    pop bx
    ret

; запустить программу: DS:SI путь, DS:DI аргументы -> AX окно; CF=1 ошибка
spawn:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    ; свободный слот
    xor cx, cx
.slot:
    mov ax, cx
    call win_ptr
    cmp byte [bx + W_USED], 0
    je .found
    inc cx
    cmp cx, MAXWIN
    jb .slot
    jmp .fail
.found:
    mov [sp_win], cx
    ; загрузить образ
    push si
    push di
    mov dx, [bx + W_SEG]
    mov cx, [bx + W_VSEG]
    push ds
    pop es                          ; ES:DI аргументы
    mov al, 2
    FAPI FAPI_WM
    pop di
    pop si
    jc .fail
    mov [bx + W_ENTRY], ax
    ; запомнить путь и аргументы
    push si
    push di
    push ds
    pop es
    lea di, [bx + W_PATH]
    mov cx, 80
    call str_copy_n
    pop si                          ; аргументы -> W_ARGS
    lea di, [bx + W_ARGS]
    mov cx, 128
    call str_copy_n
    pop si
    ; заголовок: имя файла без пути и расширения
    call basename
    lea di, [bx + W_TITLE]
    mov cx, 15
.tt:
    lodsb
    cmp al, '.'
    je .tt_end
    test al, al
    jz .tt_end
    stosb
    loop .tt
.tt_end:
    mov byte [di], 0
    ; окно
    mov byte [bx + W_USED], 1
    mov byte [bx + W_MIN], 0
    mov byte [bx + W_PEND], 0
    mov byte [bx + W_MAINW], 0
    mov byte [bx + W_ANIM], 0
    mov ax, [sp_win]
    push bx
    mov bx, ax
    shl bx, 1
    shl bx, 1
    mov cx, [win_pos + bx]          ; x
    mov dx, [win_pos + bx + 2]      ; y
    pop bx
    mov [bx + W_X], cx
    mov [bx + W_Y], dx
    call win_reset                  ; экран, курсор, стек
    mov ax, [sp_win]
    call z_raise
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    clc
    ret
.fail:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    stc
    ret

; BX -> окно: очистить виртуальный экран, курсор, подготовить стек первого запуска
win_reset:
    push ax
    push cx
    push di
    push es
    mov es, [bx + W_VSEG]
    xor di, di
    mov ax, 0x0720
    mov cx, 2000
    rep stosw
    mov byte [bx + W_CURR], 0
    mov byte [bx + W_CURC], 0
    mov byte [bx + W_CVIS], 1
    ; стек: [FFFE]=GUI_SEG [FFFC]=app_retf_stub (retf программы), [FFFA]=start_app, [FFF8]=bp, [FFF6]=si
    mov es, [bx + W_SEG]
    mov word [es:0xFFFE], GUI_SEG
    mov word [es:0xFFFC], app_retf_stub
    mov word [es:0xFFFA], start_app
    mov word [es:0xFFF8], 0
    mov word [es:0xFFF6], 0
    mov ax, [bx + W_SEG]
    mov [bx + W_SS], ax
    mov word [bx + W_SP], 0xFFF6
    pop es
    pop di
    pop cx
    pop ax
    ret

; закрыть окно AX (главный поток): отложенная команда -> выполнить и перезапустить,
; иначе освободить; главное окно -> завершение gui
win_close:
    push ax
    call win_ptr
    cmp byte [bx + W_PEND], 0
    je .free
    ; отложенная команда
    mov byte [bx + W_PEND], 0
    push bx
    lea si, [bx + W_CMD]
    mov al, [bx + W_PPAUSE]
    call run_command                ; запуск .FAP в новом окне или команда на весь экран
    pop bx
    ; перезапустить программу окна с теми же аргументами (программа могла изменить
    ; свою строку аргументов в seg:0080 перед выходом — как в ядре, берём её оттуда)
    push bx
    push ds
    pop es
    push ds
    lea di, [bx + W_ARGS]
    mov ds, [bx + W_SEG]
    mov si, 0x80
    mov cx, 127
.wc_args:
    lodsb
    stosb
    test al, al
    loopnz .wc_args
    mov byte [es:di], 0
    pop ds
    mov dx, [bx + W_SEG]
    mov cx, [bx + W_VSEG]
    lea si, [bx + W_PATH]
    lea di, [bx + W_ARGS]
    push ds
    pop es
    mov al, 2
    FAPI FAPI_WM
    pop bx
    jc .free
    mov [bx + W_ENTRY], ax
    call win_reset
    pop ax
    ret
.free:
    cmp byte [bx + W_MIN], 0
    jne .f_noanim
    cmp byte [bx + W_ANIM], 0
    je .f_noanim
    mov byte [bx + W_MIN], 1
    call compose                    ; экран без окна
    call anim_close                 ; окно BX схлопывается к центру
.f_noanim:
    mov byte [bx + W_USED], 0
    pop ax
    call z_remove
    push ax
    call win_ptr
    cmp byte [bx + W_MAINW], 0
    je .f_done
    mov byte [req], REQ_QUIT        ; закрыли FM — выходим
.f_done:
    pop ax
    ret

; команда DS:SI (из exec): если это запуск .FAP — новое окно, иначе — на весь экран. AL = пауза
run_command:
    mov [rc_pause], al
    mov [rc_cmd], si
    ; первое слово
    call skip_sp
    mov di, rc_tok
    mov cx, 12
.tok:
    lodsb
    cmp al, ' '
    je .tok_end
    test al, al
    jz .tok_end
    cmp al, 'a'
    jb .tok_st
    cmp al, 'z'
    ja .tok_st
    sub al, 0x20
.tok_st:
    stosb
    loop .tok
.tok_end:
    mov byte [di], 0
    dec si
    cmp byte [si], 0
    je .no_rest
    inc si
.no_rest:
    call skip_sp
    mov [rc_rest], si               ; остаток строки = аргументы
    ; "run PATH [ARGS]"
    mov si, rc_tok
    cmp word [si], 'RU'
    jne .named
    cmp word [si + 2], 'N'
    jne .named
    mov si, [rc_rest]
    mov di, req_path
    mov cx, 79
.rp:
    lodsb
    cmp al, ' '
    je .rp_end
    test al, al
    jz .rp_end
    stosb
    loop .rp
.rp_end:
    mov byte [di], 0
    dec si
    cmp byte [si], 0
    je .rp_noargs
    inc si
.rp_noargs:
    call skip_sp
    mov [rc_rest], si
    ; только .FAP (скрипты .SH — на весь экран)
    mov si, req_path
    call has_fap_ext
    jnc .spawn_it
    jmp .fullscreen
.named:
    ; NAME -> NAME.FAP в текущем каталоге, /SYSTEM/SYSAPPS, корне
    mov si, rc_tok
    mov di, req_path
    call str_copy
    mov si, s_fapext
    call str_copy
    mov si, req_path
    FAPI FAPI_STAT
    jnc .spawn_it
    mov si, s_sysapps
    mov di, req_path
    call str_copy
    mov si, rc_tok
    call str_copy
    mov si, s_fapext
    call str_copy
    mov si, req_path
    FAPI FAPI_STAT
    jnc .spawn_it
    mov si, s_slash
    mov di, req_path
    call str_copy
    mov si, rc_tok
    call str_copy
    mov si, s_fapext
    call str_copy
    mov si, req_path
    FAPI FAPI_STAT
    jnc .spawn_it
    jmp .fullscreen
.spawn_it:
    mov si, [rc_rest]
    mov di, req_args
    mov cx, 127
    call str_copy_n
    mov si, req_path
    mov di, req_args
    call spawn
    jnc .ok
    mov si, s_nowin
    call tb_message
.ok:
    ret
.fullscreen:
    ; выполнить через оболочку на обычном экране 80x25
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    call screen_restore
    FAPI FAPI_CLS
    mov si, [rc_cmd]
    FAPI FAPI_SHELL
    cmp byte [rc_pause], 0
    je .fs_done
    FAPI_PRINT s_pause
    FAPI FAPI_GETKEY
.fs_done:
    call screen_init
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    ret

; SI -> строка; CF=0 если заканчивается на .FAP
has_fap_ext:
    push si
    push di
    mov di, si
.e:
    cmp byte [di], 0
    je .end
    inc di
    jmp .e
.end:
    sub di, si
    cmp di, 4
    jb .no
    add si, di
    sub si, 4
    cmp word [si], '.F'
    jne .no
    cmp word [si + 2], 'AP'
    jne .no
    pop di
    pop si
    clc
    ret
.no:
    pop di
    pop si
    stc
    ret

;---------------------------------------------------------------- обработчик вызовов программ
; Сюда ядро делает far call при int 80h из сегмента программы. Регистры — как в программе.
wm_entry:
    sti
    push es
    push ds
    pusha
    mov bp, sp
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov byte [ret_fl], 0
    ; окно по сегменту стека (SS программы = её сегмент)
    mov ax, ss
    call win_by_seg                 ; -> AX индекс, BX запись
    jc .ret
    mov [cur_win], ax
    mov [cur_rec], bx
    mov al, [bp + F_AX + 1]         ; AH = функция
    cmp al, 0x21
    ja .other
    xor ah, ah
    mov si, ax
    shl si, 1
    call [wm_tab + si]
    jmp .ret
.other:
    call pass                       ; новые функции (AUDIO и т.п.) — напрямую ядру
.ret:
    mov ax, [ret_fl]
    popa
    pop ds
    pop es
    ; CF/ZF из ret_fl
    push ax
    pushf
    pop ax
    and ax, 0xFFBE
    or ax, [cs:ret_fl]
    push ax
    popf
    pop ax
    retf

wm_tab:
    dw do_exit, v_putc, v_puts, v_getkey, v_keyhit, v_setcur
    dw v_getcur, v_cls, pass, pass, pass
    dw v_printdec, pass, v_sleep, v_cls
    dw pass, v_cursor, pass, pass, pass, pass
    dw v_putat, v_fillrect, v_putsat
    dw pass, v_shell, v_exec, pass, pass, pass
    dw v_mouse, v_mouseshow, pass, v_nop

; AX = сегмент -> AX индекс окна, BX запись; CF=1 нет
win_by_seg:
    push cx
    xor cx, cx
.l:
    push ax
    mov ax, cx
    call win_ptr
    pop ax
    cmp byte [bx + W_USED], 0
    je .n
    cmp [bx + W_SEG], ax
    je .f
.n:
    inc cx
    cmp cx, MAXWIN
    jb .l
    pop cx
    stc
    ret
.f:
    mov ax, cx
    pop cx
    clc
    ret

v_nop:
    ret

; прозрачный вызов ядра с регистрами программы
pass:
    mov ax, [bp + F_AX]
    mov bx, [bp + F_BX]
    mov cx, [bp + F_CX]
    mov dx, [bp + F_DX]
    mov si, [bp + F_SI]
    mov di, [bp + F_DI]
    mov es, [bp + F_ES]
    mov ds, [bp + F_DS]
    int 0x80
    mov [bp + F_AX], ax
    mov [bp + F_CX], cx
    mov [bp + F_DX], dx
    mov [bp + F_SI], si
    mov [bp + F_DI], di
    mov ax, cs
    mov ds, ax
    mov es, ax
    jnc .ok
    mov byte [ret_fl], 1
.ok:
    ret

; выход программы
do_exit:
    mov ax, [cur_win]
    mov [req_win], ax
    mov byte [req], REQ_CLOSE
    jmp switch_to_main              ; не возвращается

; --- виртуальный терминал ---
; BX -> окно; AL символ
vt_putc:
    push ax
    push cx
    push di
    push es
    mov es, [bx + W_VSEG]
    cmp al, 13
    je .cr
    cmp al, 10
    je .lf
    cmp al, 8
    je .bs
    cmp al, 7
    je .bell
    cmp al, 9
    jne .ch
    mov al, ' '
.ch:
    call vt_addr                    ; -> DI
    mov ah, 0x07
    stosw
    inc byte [bx + W_CURC]
    cmp byte [bx + W_CURC], 80
    jb .done
    mov byte [bx + W_CURC], 0
.lf:
    inc byte [bx + W_CURR]
    cmp byte [bx + W_CURR], 25
    jb .done
    mov byte [bx + W_CURR], 24
    ; прокрутка
    push ds
    push si
    mov ax, es
    mov ds, ax
    mov si, 160
    xor di, di
    mov cx, 1920
    rep movsw
    mov ax, 0x0720
    mov cx, 80
    rep stosw
    pop si
    pop ds
    jmp .done
.cr:
    mov byte [bx + W_CURC], 0
    jmp .done
.bs:
    cmp byte [bx + W_CURC], 0
    je .done
    dec byte [bx + W_CURC]
    jmp .done
.bell:
    FAPI FAPI_BEEP
.done:
    pop es
    pop di
    pop cx
    pop ax
    ret
; DI = смещение курсора в виртуальном экране
vt_addr:
    push ax
    mov al, [bx + W_CURR]
    mov ah, 160
    mul ah
    mov di, ax
    mov al, [bx + W_CURC]
    xor ah, ah
    shl ax, 1
    add di, ax
    pop ax
    ret

v_putc:
    mov bx, [cur_rec]
    mov al, [bp + F_AX]
    call vt_putc
    ret
v_puts:
    mov bx, [cur_rec]
    mov si, [bp + F_SI]
    mov dx, [bp + F_DS]
.l:
    mov ds, dx                      ; строка — в сегменте программы
    lodsb
    push cs
    pop ds                          ; vt_putc работает с записью окна в нашем сегменте
    test al, al
    jz .d
    call vt_putc
    jmp .l
.d:
    ret
v_printdec:
    mov bx, [cur_rec]
    mov ax, [bp + F_DX]
    mov di, tmpnum
    call u16_to_str
    mov si, tmpnum
.l:
    lodsb
    test al, al
    jz .d
    call vt_putc
    jmp .l
.d:
    ret
v_setcur:
    mov bx, [cur_rec]
    mov ax, [bp + F_DX]
    cmp ah, 25
    jae .r
    cmp al, 80
    jae .r
    mov [bx + W_CURR], ah
    mov [bx + W_CURC], al
.r: ret
v_getcur:
    mov bx, [cur_rec]
    mov ah, [bx + W_CURR]
    mov al, [bx + W_CURC]
    mov [bp + F_DX], ax
    ret
v_cls:
    mov bx, [cur_rec]
    push es
    mov es, [bx + W_VSEG]
    xor di, di
    mov ax, 0x0720
    mov cx, 2000
    rep stosw
    pop es
    mov byte [bx + W_CURR], 0
    mov byte [bx + W_CURC], 0
    ret
v_cursor:
    mov bx, [cur_rec]
    mov byte [bx + W_CVIS], 1
    cmp word [bp + F_CX], 0x2000
    jne .r
    mov byte [bx + W_CVIS], 0
.r: ret
; putat: DH,DL, AL символ, BL атрибут
v_putat:
    mov bx, [cur_rec]
    mov ax, [bp + F_DX]
    cmp ah, 25
    jae .r
    cmp al, 80
    jae .r
    call cell_addr                  ; -> DI
    mov al, [bp + F_AX]
    mov ah, [bp + F_BX]
    push es
    mov es, [bx + W_VSEG]
    stosw
    pop es
.r: ret
; AH строка, AL столбец -> DI
cell_addr:
    push ax
    push dx
    mov dl, al
    mov al, ah
    mov ah, 160
    mul ah
    mov di, ax
    mov al, dl
    xor ah, ah
    shl ax, 1
    add di, ax
    pop dx
    pop ax
    ret
; fillrect: DH,DL угол, CH высота, CL ширина, AL символ, BL атрибут
v_fillrect:
    mov bx, [cur_rec]
    push es
    mov es, [bx + W_VSEG]
    mov dx, [bp + F_DX]
    mov cx, [bp + F_CX]
.row:
    test ch, ch
    jz .d
    cmp dh, 25
    jae .d
    push cx
    push dx
    xor ch, ch
.col:
    jcxz .rd
    cmp dl, 80
    jae .rd
    mov ax, dx
    call cell_addr
    mov al, [bp + F_AX]
    mov ah, [bp + F_BX]
    stosw
    inc dl
    dec cx
    jmp .col
.rd:
    pop dx
    pop cx
    inc dh
    dec ch
    jmp .row
.d:
    pop es
    ret
; putsat: DH,DL, DS:SI строка, BL атрибут
v_putsat:
    mov bx, [cur_rec]
    mov dx, [bp + F_DX]
    cmp dh, 25
    jae .d
    mov si, [bp + F_SI]
    push es
    mov es, [bx + W_VSEG]
    mov ah, [bp + F_BX]
    push ds
    mov ds, [bp + F_DS]
.l:
    lodsb
    test al, al
    jz .e
    cmp dl, 80
    jae .e
    push ax
    mov ax, dx
    call cell_addr
    pop ax
    stosw
    inc dl
    jmp .l
.e:
    pop ds
    pop es
.d: ret

; --- ввод ---
v_getkey:
    call pump_iter
    mov ah, 0x11
    int 0x16
    jnz .key
    hlt
    jmp v_getkey
.key:
    mov ah, 0x10
    int 0x16
    mov [bp + F_AX], ax
    ret
v_keyhit:
    call pump_iter
    mov ah, 0x11
    int 0x16
    jnz .yes
    mov word [bp + F_AX], 0
    mov byte [ret_fl], 0x40         ; ZF
    ret
.yes:
    mov [bp + F_AX], ax
    ret
v_sleep:
    FAPI FAPI_TICKS
    mov si, ax
    add si, [bp + F_CX]
.l:
    call pump_iter
    FAPI FAPI_TICKS
    sub ax, si
    jns .d
    hlt
    jmp .l
.d: ret
; мышь: координаты относительно содержимого текущего окна; кнопки — только внутри него
v_mouse:
    call pump_iter
    FAPI FAPI_MOUSE
    mov bx, [cur_rec]
    sub cx, [bx + W_X]
    sub dx, [bx + W_Y]
    dec dx                          ; относительно видимой части окна
    ; кнопки — только внутри видимой части и не во время перетаскивания
    mov [bp + F_AX], ax
    test ah, ah
    jz .nob
    cmp word [drag_win], -1
    jne .nob
    cmp cx, [bx + W_W]
    jae .nob
    cmp dx, [bx + W_H]
    jae .nob
    jmp .coord
.nob:
    mov byte [bp + F_AX], 0
.coord:
    add cx, [bx + W_CX0]            ; -> координаты виртуального экрана программы
    add dx, [bx + W_CY0]
    mov [bp + F_CX], cx
    mov [bp + F_DX], dx
    ret
v_mouseshow:
    ret                             ; курсор мыши в GUI всегда виден

; exec: запомнить команду, выполнится после выхода программы (как в ядре)
v_exec:
    mov bx, [cur_rec]
    mov si, [bp + F_SI]
    lea di, [bx + W_CMD]
    mov cx, 127
    push ds
    mov ds, [bp + F_DS]
.l:
    lodsb
    stosb
    test al, al
    loopnz .l
    pop ds
    mov byte [di], 0
    mov byte [bx + W_PEND], 1
    mov al, [bp + F_DX]
    mov [bx + W_PPAUSE], al
    ret

; shell: команда выполняется ядром; её вывод (одна строка) переносится в окно
v_shell:
    ; команда выполняется ядром; на время выполнения консольный вывод ядра (print_char)
    ; перенаправляется в виртуальный экран окна (FAPI_WM al=3), а курсор BIOS ставится
    ; в позицию курсора программы — многострочный вывод (play, ls, ...) идёт в окно
    mov bx, [cur_rec]
    push word [bx + W_VSEG]
    ; сохранить курсор BIOS, поставить курсор программы
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [0x0450]
    mov [cs:sh_savecur], ax
    mov ah, [cs:bx + W_CURR]
    mov al, [cs:bx + W_CURC]
    mov [0x0450], ax
    pop ds
    pop cx
    mov al, 3
    FAPI FAPI_WM                    ; AX <- прежний сегмент консоли
    mov [sh_saveseg], ax
    mov byte [dirty], 1
    call compose                    ; показать окно до запуска (play может работать долго)
    call pass
    mov cx, [sh_saveseg]
    mov al, 3
    FAPI FAPI_WM
    mov bx, [cur_rec]
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [0x0450]
    mov [cs:bx + W_CURR], ah
    mov [cs:bx + W_CURC], al
    mov ax, [cs:sh_savecur]
    mov [0x0450], ax
    pop ds
    cmp byte [bx + W_CURR], 25
    jb .ok
    mov byte [bx + W_CURR], 24
.ok:
    ; аппаратный курсор вернуть на место (ядро двигало его int 10h)
    mov dx, [sh_savecur]
    mov ah, 0x02
    xor bh, bh
    int 0x10
    mov byte [dirty], 1
    ret

;---------------------------------------------------------------- насос событий
; Один шаг: перерисовка, обработка мыши (перетаскивание, кнопки, активация). Может
; переключить контекст (тогда вернётся сюда позже).
pump_iter:
    pusha
    ; текущее окно не верхнее (его перекрыли, свернули или только что создали другое) — уступить
    cmp word [cur_win], -1
    je .draw
    call top_visible
    jc .yield_main
    cmp ax, [cur_win]
    je .draw
    mov [yield_win], ax
    popa
    mov ax, [yield_win]
    call switch_to                  ; вернёмся, когда окно снова станет активным
    jmp pump_iter
.yield_main:
    popa
    call switch_to_main
    jmp pump_iter
.draw:
    call compose
    FAPI FAPI_MOUSE
    test ah, ah
    jz .done
    mov [m_col], cx
    mov [m_row], dx
    mov bl, al
    xor bl, [m_prev]
    and bl, al                      ; нажатые только что
    mov [m_prev], al
    mov [m_new], bl
    ; перетаскивание
    cmp word [drag_win], -1
    je .nodrag
    test al, 1
    jz .drag_end
    push ax
    mov ax, [drag_win]
    call win_ptr
    pop ax
    mov cx, [m_col]
    sub cx, [drag_dx]
    mov dx, [m_row]
    sub dx, [drag_dy]
    push ax
    mov ax, 10
    sub ax, [bx + W_W]
    cmp cx, ax
    jge .cx1
    mov cx, ax
.cx1:
    pop ax
    cmp cx, 79
    jle .cx2
    mov cx, 79
.cx2:
    cmp dx, 0
    jge .dx1
    xor dx, dx
.dx1:
    cmp dx, TBROW - 1
    jle .dx2
    mov dx, TBROW - 1
.dx2:
    mov [bx + W_X], cx
    mov [bx + W_Y], dx
    jmp .done
.drag_end:
    mov word [drag_win], -1
    jmp .done
.nodrag:
    test byte [m_new], 1
    jz .done
    ; клик: панель задач?
    cmp word [m_row], TBROW
    jne .hit
    call tb_click
    jmp .done
.hit:
    call hit_test                   ; -> AX окно, DL зона (0 нет, 1 заголовок, 2 закрыть, 3 свернуть, 4 содержимое); CF нет
    jc .done
    cmp dl, 2
    je .close
    cmp dl, 3
    je .minimize
    cmp dl, 1
    je .title
    ; содержимое: активировать, если не активно
    cmp ax, [cur_win]
    je .done
    call activate
    jmp .done
.title:
    push ax
    call win_ptr
    mov cx, [m_col]
    sub cx, [bx + W_X]
    mov [drag_dx], cx
    mov cx, [m_row]
    sub cx, [bx + W_Y]
    mov [drag_dy], cx
    mov [drag_win], ax
    pop ax
    cmp ax, [cur_win]
    je .done
    call activate
    jmp .done
.close:
    mov [req_win], ax
    mov byte [req], REQ_CLOSE
    cmp word [cur_win], -1
    je .done                        ; мы в главном потоке — он обработает сам
    popa
    jmp switch_to_main
.minimize:
    push ax
    call win_ptr
    mov byte [bx + W_MIN], 1
    call compose                    ; экран без окна
    call anim_minimize              ; окно BX (индекс AX) улетает на панель задач
    pop ax
    cmp ax, [cur_win]
    jne .done
    ; свернули активное — отдать управление следующему
    call top_visible
    jc .to_main
    mov [yield_win], ax
    popa
    mov ax, [yield_win]
    jmp switch_to
.to_main:
    mov byte [req], REQ_NONE
    popa
    jmp switch_to_main
.done:
    popa
    ret

; сделать окно AX активным (поднять и переключиться)
activate:
    call z_raise
    cmp word [cur_win], -1
    jne .sw
    mov [req_win], ax
    mov byte [req], REQ_SHOW        ; из главного потока: он сам переключится
    ret
.sw:
    jmp switch_to                   ; вернёмся, когда окно снова станет активным

; клик по панели задач: восстановить свёрнутое окно
tb_click:
    xor cx, cx
.l:
    mov ax, cx
    call win_ptr
    cmp byte [bx + W_USED], 0
    je .n
    cmp byte [bx + W_MIN], 0
    je .n
    push cx
    mov ax, cx
    call tb_slot_col                ; -> AX столбец кнопки
    mov dx, [m_col]
    sub dx, ax
    pop cx
    cmp dx, 0
    jl .n
    cmp dx, 13
    jg .n
    ; восстановить
    mov ax, cx
    call anim_restore               ; с панели задач — в окно BX
    mov byte [bx + W_MIN], 0
    mov ax, cx
    call activate
    ret
.n:
    inc cx
    cmp cx, MAXWIN
    jb .l
    ret
tb_slot_col:
    push dx
    mov dx, 14
    mul dx
    add ax, 14
    pop dx
    ret

; проверка попадания (m_col, m_row) сверху вниз по z-порядку
hit_test:
    push bx
    push cx
    mov cx, [zcount]
.l:
    jcxz .none
    dec cx
    mov bx, cx
    mov al, [zorder + bx]
    xor ah, ah
    push ax
    call win_ptr
    pop ax
    cmp byte [bx + W_MIN], 0
    jne .l
    mov dx, [m_col]
    sub dx, [bx + W_X]
    cmp dx, 0
    jl .l
    cmp dx, [bx + W_W]
    jge .l
    push dx
    mov dx, [m_row]
    sub dx, [bx + W_Y]
    cmp dx, 0
    jl .nx
    cmp dx, [bx + W_H]
    jg .nx
    test dx, dx
    jnz .content
    pop dx
    ; заголовок: кнопки в столбцах W-3..W-1 (закрыть) и W-6..W-4 (свернуть)
    push ax
    mov ax, [bx + W_W]
    sub ax, 3
    cmp dx, ax
    pop ax
    jge .cls
    push ax
    mov ax, [bx + W_W]
    sub ax, 6
    cmp dx, ax
    pop ax
    jge .min
    mov dl, 1
    jmp .found
.cls:
    mov dl, 2
    jmp .found
.min:
    mov dl, 3
    jmp .found
.content:
    pop dx
    mov dl, 4
.found:
    pop cx
    pop bx
    clc
    ret
.nx:
    pop dx
    jmp .l
.none:
    pop cx
    pop bx
    stc
    ret

;---------------------------------------------------------------- композиция экрана
compose:
    pusha
    push ds
    push es
    ; обои -> back
    push ds
    pop es
    mov si, wall
    mov di, back
    mov cx, 4000
    rep movsw
    ; панель задач
    mov di, back + TBROW * 160
    mov ax, (A_TBAR << 8) | ' '
    mov cx, 80
    rep stosw
    mov di, back + TBROW * 160
    mov si, s_tbname
    mov ah, A_TBAR
    call back_puts
    xor cx, cx
.tb:
    mov ax, cx
    call win_ptr
    cmp byte [bx + W_USED], 0
    je .tbn
    cmp byte [bx + W_MIN], 0
    je .tbn
    mov ax, cx
    call tb_slot_col
    shl ax, 1
    mov di, back + TBROW * 160
    add di, ax
    mov ah, 0x7F
    mov al, '['
    stosw
    lea si, [bx + W_TITLE]
    call back_puts
    mov al, ']'
    stosw
.tbn:
    inc cx
    cmp cx, MAXWIN
    jb .tb
    ; часы HH:MM в правом углу панели
    FAPI FAPI_LOCALTIME
    mov di, back + TBROW * 160 + 75 * 2
    mov al, ch
    call tb_2dig
    mov ax, (A_TBAR << 8) | ':'
    stosw
    mov al, cl
    call tb_2dig
    ; сообщение (если есть)
    cmp byte [tb_msg], 0
    je .nomsg
    mov di, back + TBROW * 160 + 2 * 60
    mov si, tb_msg
    mov ah, 0x74
    call back_puts
    FAPI FAPI_TICKS
    cmp ax, [tb_msg_until]
    jl .nomsg
    mov byte [tb_msg], 0
.nomsg:
    ; окна снизу вверх
    xor cx, cx
.win:
    cmp cx, [zcount]
    jae .cursor
    mov bx, cx
    mov al, [zorder + bx]
    xor ah, ah
    mov [cp_idx], ax
    call win_ptr
    cmp byte [bx + W_MIN], 0
    jne .wn
    mov [cp_rec], bx
    call win_extent                 ; W_CX0/W_CY0/W_W/W_H по содержимому
    cmp byte [bx + W_ANIM], 0
    jne .shown
    cmp word [bx + W_H], 0          ; содержимое появилось — пора показать с анимацией
    je .wn
    mov [anim_pending], bx
    jmp .wn                         ; в этом кадре окно ещё не рисуем
.shown:
    call draw_shadow                ; тень под окном (справа и снизу)
    ; заголовок -> trow
    call build_title
    mov si, trow
    mov dx, [bx + W_Y]
    call blit_row                   ; DS:SI строка -> back строка DX, столбец W_X, W_W ячеек
    ; содержимое
    push ds
    push cx
    mov ax, [bx + W_CY0]
    mov si, 160
    mul si
    mov si, ax
    mov ax, [bx + W_CX0]
    shl ax, 1
    add si, ax
    mov cx, [bx + W_H]
    mov dx, [bx + W_Y]
    inc dx
    mov ds, [bx + W_VSEG]
.crow:
    jcxz .cdone
    cmp dx, TBROW
    jge .cdone
    call blit_row
    add si, 160
    inc dx
    dec cx
    jmp .crow
.cdone:
    pop cx
    pop ds
.wn:
    inc cx
    jmp .win
.cursor:
    ; аппаратный курсор — курсор активного окна
    mov ah, 0x01
    mov cx, 0x2000
    int 0x10
    call top_visible
    jc .copy
    call win_ptr
    cmp byte [bx + W_CVIS], 0
    je .copy
    mov al, [bx + W_CURR]
    xor ah, ah
    sub ax, [bx + W_CY0]
    jl .copy
    cmp ax, [bx + W_H]
    jge .copy
    add ax, [bx + W_Y]
    inc ax
    cmp ax, TBROW
    jge .copy
    mov dh, al
    mov al, [bx + W_CURC]
    xor ah, ah
    sub ax, [bx + W_CX0]
    jl .copy
    cmp ax, [bx + W_W]
    jge .copy
    add ax, [bx + W_X]
    cmp ax, 80
    jae .copy
    mov dl, al
    mov ah, 0x02
    xor bh, bh
    int 0x10
    mov ah, 0x01
    mov cx, 0x0607
    int 0x10
.copy:
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    mov ax, 0xB800
    mov es, ax
    mov si, back
    xor di, di
    mov cx, 4000
    rep movsw
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    mov byte [dirty], 0
    ; окно, ждущее анимации открытия
    mov bx, [anim_pending]
    test bx, bx
    jz .noanim
    mov word [anim_pending], 0
    call anim_open
    mov byte [bx + W_ANIM], 1
    mov byte [dirty], 1
.noanim:
    pop es
    pop ds
    popa
    ret

; две цифры AL -> ES:DI атрибутом A_TBAR
tb_2dig:
    push ax
    push cx
    aam
    xchg al, ah
    add ax, 0x3030
    mov cx, ax
    mov ah, A_TBAR
    mov al, cl
    stosw
    mov al, ch
    stosw
    pop cx
    pop ax
    ret

; тень окна [cp_rec] в back: 2 столбца справа (строки Y+1..Y+H+1) и строка снизу (столбцы X+2..X+W+1)
draw_shadow:
    pusha
    mov bx, [cp_rec]
    mov cx, [bx + W_H]
    inc cx                          ; строки Y+1 .. Y+H+1
    mov dx, [bx + W_Y]
    inc dx
.row:
    jcxz .bottom
    mov ax, [bx + W_X]
    add ax, [bx + W_W]              ; столбец сразу за окном
    call shade_cell
    inc ax
    call shade_cell
    inc dx
    dec cx
    jmp .row
.bottom:
    ; DX = Y + H + 1 — строка под окном
    mov ax, [bx + W_X]
    add ax, 2
    mov cx, [bx + W_W]
.bl:
    call shade_cell
    inc ax
    loop .bl
    popa
    ret

; затемнить ячейку back (строка DX, столбец AX) — с обрезкой
shade_cell:
    push ax
    push di
    cmp dx, 0
    jl .d
    cmp dx, TBROW
    jge .d
    cmp ax, 0
    jl .d
    cmp ax, 80
    jge .d
    push dx
    shl ax, 1
    mov di, ax
    mov ax, dx
    mov dx, 160
    push dx
    mul dx
    pop dx
    add di, ax
    pop dx
    mov byte [back + di + 1], A_SHADOW
.d:
    pop di
    pop ax
    ret

;---------------------------------------------------------------- анимации окон
; Рамка летит от прямоугольника an0 к an1 за ANIM_STEPS шагов поверх текущего экрана.
; Прямоугольники: x, y, w, h (w, h — внешние размеры, включая заголовок/рамку).

; окно BX: рамка из центра окна
anim_open:
    call anim_rect_of_win           ; an1 = окно
    call anim_center_as_an0         ; an0 = точка в центре
    jmp anim_run

; окно BX: схлопнуть к центру
anim_close:
    call anim_rect_of_win
    call anim_center_as_an0
    call anim_swap
    jmp anim_run

; окно BX (индекс AX): улететь на кнопку панели задач
anim_minimize:
    push ax
    call anim_rect_of_win
    call anim_slot_as_an0           ; an0 = кнопка панели (по индексу AX)
    call anim_swap
    call anim_run
    pop ax
    ret

; окно BX (индекс AX): с кнопки панели — в окно
anim_restore:
    push ax
    call anim_rect_of_win
    call anim_slot_as_an0
    call anim_run
    pop ax
    ret

anim_rect_of_win:
    push ax
    mov ax, [bx + W_X]
    mov [an1_x], ax
    mov ax, [bx + W_Y]
    mov [an1_y], ax
    mov ax, [bx + W_W]
    mov [an1_w], ax
    mov ax, [bx + W_H]
    inc ax
    mov [an1_h], ax
    pop ax
    ret

anim_center_as_an0:
    push ax
    mov ax, [an1_w]
    shr ax, 1
    add ax, [an1_x]
    mov [an0_x], ax
    mov ax, [an1_h]
    shr ax, 1
    add ax, [an1_y]
    mov [an0_y], ax
    mov word [an0_w], 2
    mov word [an0_h], 1
    pop ax
    ret

; AX = индекс окна
anim_slot_as_an0:
    push ax
    call tb_slot_col
    mov [an0_x], ax
    mov word [an0_y], TBROW
    mov word [an0_w], 14
    mov word [an0_h], 1
    pop ax
    ret

anim_swap:
    push ax
    push cx
    push si
    mov si, 0
.l: mov ax, [an0_x + si]
    xchg ax, [an1_x + si]
    mov [an0_x + si], ax
    add si, 2
    cmp si, 8
    jb .l
    pop si
    pop cx
    pop ax
    ret

anim_run:
    pusha
    push es
    xor cl, cl
    FAPI FAPI_MOUSESHOW
    mov word [an_step], 1
.step:
    ; cur = an0 + (an1 - an0) * step / ANIM_STEPS
    mov si, 0
.lerp:
    mov ax, [an1_x + si]
    sub ax, [an0_x + si]
    imul word [an_step]
    mov cx, ANIM_STEPS
    idiv cx
    add ax, [an0_x + si]
    mov [anc_x + si], ax
    add si, 2
    cmp si, 8
    jb .lerp
    call anim_restore_screen
    call anim_draw_frame
    mov cx, 3
.dl:
    push cx
    mov cx, 40000
    call pit_delay
    pop cx
    loop .dl
    inc word [an_step]
    cmp word [an_step], ANIM_STEPS
    jb .step
    call anim_restore_screen
    mov cl, 1
    FAPI FAPI_MOUSESHOW
    pop es
    popa
    ret

; back -> экран
anim_restore_screen:
    push ds
    pop es
    mov ax, 0xB800
    mov es, ax
    mov si, back
    xor di, di
    mov cx, 4000
    rep movsw
    ret

; двойная рамка anc_x/anc_y/anc_w/anc_h прямо на экране (ES = B800), с обрезкой
anim_draw_frame:
    mov dx, [anc_y]
    mov cx, [anc_h]
    cmp cx, 1
    jge .h_ok
    mov cx, 1
.h_ok:
    cmp word [anc_w], 2
    jge .w_ok
    mov word [anc_w], 2
.w_ok:
    mov bp, cx                      ; строк осталось
.row:
    mov ax, [anc_x]
    push cx
    mov cx, [anc_w]
    ; левый символ
    mov bl, 0xBA                    ; ║
    cmp bp, [anc_h]
    jne .l1
    mov bl, 0xC9                    ; ╔
.l1:
    cmp bp, 1
    jne .l2
    mov bl, 0xC8                    ; ╚
.l2:
    cmp word [anc_h], 1
    jne .l3
    mov bl, 0xCD
.l3:
    call anim_put
    inc ax
    dec cx
    dec cx
    jle .right
.mid:
    mov bl, ' '
    cmp bp, [anc_h]
    je .m_line
    cmp bp, 1
    jne .m_put
.m_line:
    mov bl, 0xCD                    ; ═
.m_put:
    call anim_put
    inc ax
    loop .mid
.right:
    mov bl, 0xBA
    cmp bp, [anc_h]
    jne .r1
    mov bl, 0xBB                    ; ╗
.r1:
    cmp bp, 1
    jne .r2
    mov bl, 0xBC                    ; ╝
.r2:
    cmp word [anc_h], 1
    jne .r3
    mov bl, 0xCD
.r3:
    call anim_put
    pop cx
    inc dx
    dec bp
    jnz .row
    ret

; символ BL в экран ES (B800): строка DX, столбец AX, атрибут A_ANIM; с обрезкой
anim_put:
    push ax
    push di
    cmp dx, 0
    jl .d
    cmp dx, TBROW
    jge .d
    cmp ax, 0
    jl .d
    cmp ax, 80
    jge .d
    push dx
    shl ax, 1
    mov di, ax
    mov ax, dx
    mov dx, 160
    mul dx
    add di, ax
    pop dx
    mov [es:di], bl
    mov byte [es:di + 1], A_ANIM
.d:
    pop di
    pop ax
    ret

; задержка на CX отсчётов PIT (канал 0, ~0.84 мкс каждый; счётчик уменьшается на 2 за такт в режиме 3)
pit_delay:
    push ax
    push bx
    push dx
    push si
    mov si, 20000                   ; страховка: не более 20000 опросов (если PIT ведёт себя странно)
    call pit_read
    mov bx, ax
.w:
    call pit_read
    mov dx, bx
    sub dx, ax                      ; пройдено (по модулю 65536)
    mov bx, ax
    sub cx, dx
    jbe .d
    dec si
    jnz .w
.d:
    pop si
    pop dx
    pop bx
    pop ax
    ret

pit_read:
    xor al, al
    out 0x43, al                    ; защёлкнуть канал 0
    in al, 0x40
    mov ah, al
    in al, 0x40
    xchg al, ah
    ret

; строка 160 байт DS:SI -> back, строка DX, столбец [cs:cp_rec].W_X (с обрезкой)
blit_row:
    push ax
    push bx
    push cx
    push si
    push di
    cmp dx, 0
    jl .d
    cmp dx, TBROW
    jge .d
    mov bx, [cs:cp_rec]
    mov cx, [cs:bx + W_X]           ; x
    mov ax, dx
    mov bx, 160
    push dx
    mul bx
    pop dx
    mov di, back
    add di, ax
    ; c0 = max(0,-x); c1 = min(80, 80-x)
    mov ax, cx
    neg ax                          ; -x
    cmp ax, 0
    jge .c0
    xor ax, ax
.c0:
    mov bx, 80
    sub bx, cx                      ; 80-x
    push si
    mov si, [cs:cp_rec]
    cmp bx, [cs:si + W_W]
    jle .c1
    mov bx, [cs:si + W_W]
.c1:
    pop si
    sub bx, ax                      ; количество
    jle .d
    push ax
    add ax, cx                      ; sx = c0 + x
    shl ax, 1
    add di, ax
    pop ax
    shl ax, 1
    add si, ax
    mov cx, bx
    rep movsw
.d:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; авторазмер: по виртуальному экрану окна BX найти прямоугольник с содержимым
; (ячейка «пустая», если символ пробел/0 и фон чёрный). Результат в W_CX0/W_CY0/W_W/W_H.
win_extent:
    pusha
    push ds
    mov ds, [bx + W_VSEG]
    mov word [cs:ex_x0], 80
    mov word [cs:ex_x1], -1
    mov word [cs:ex_y0], 25
    mov word [cs:ex_y1], -1
    xor si, si
    xor dx, dx                      ; строка
.row:
    xor cx, cx                      ; столбец
.cell:
    lodsw
    cmp al, ' '
    je .chk_bg
    test al, al
    jz .chk_bg
    jmp .used
.chk_bg:
    test ah, 0x70
    jz .next
.used:
    cmp cx, [cs:ex_x0]
    jge .u1
    mov [cs:ex_x0], cx
.u1:
    cmp cx, [cs:ex_x1]
    jle .u2
    mov [cs:ex_x1], cx
.u2:
    cmp dx, [cs:ex_y0]
    jge .u3
    mov [cs:ex_y0], dx
.u3:
    mov [cs:ex_y1], dx
.next:
    inc cx
    cmp cx, 80
    jb .cell
    inc dx
    cmp dx, 25
    jb .row
    pop ds
    cmp word [ex_y1], 0
    jl .empty
    mov ax, [ex_x1]
    sub ax, [ex_x0]
    inc ax                          ; ширина содержимого
    cmp ax, MINW
    jge .w_ok
    ; расширить до MINW, по возможности влево/вправо в пределах 80
    mov cx, MINW
    sub cx, ax                      ; добавить
    mov ax, [ex_x0]
    sub ax, cx
    jge .w_l
    xor ax, ax
.w_l:
    mov [ex_x0], ax
    mov ax, MINW
.w_ok:
    mov [bx + W_W], ax
    mov ax, [ex_x0]
    mov [bx + W_CX0], ax
    mov ax, [ex_y0]
    mov [bx + W_CY0], ax
    mov ax, [ex_y1]
    sub ax, [ex_y0]
    inc ax
    mov [bx + W_H], ax
    jmp .done
.empty:
    mov word [bx + W_CX0], 0
    mov word [bx + W_CY0], 0
    mov word [bx + W_W], MINW
    mov word [bx + W_H], 0
.done:
    popa
    ret

; заголовок окна BX -> trow (160 байт)
build_title:
    push ax
    push cx
    push si
    push di
    push bx
    mov ah, A_TINA
    mov ax, [cp_idx]
    cmp ax, [cur_win]
    jne .a1
    mov ah, A_TACT
    jmp .a2
.a1:
    ; главный поток: верхнее видимое окно считаем активным
    cmp word [cur_win], -1
    jne .a3
    push ax
    call top_visible
    pop cx
    cmp ax, cx
    jne .a3
    mov ah, A_TACT
    jmp .a2
.a3:
    mov ah, A_TINA
.a2:
    mov [title_attr], ah
    mov di, trow
    mov al, ' '
    mov cx, 80
    rep stosw
    mov di, trow + 2
    mov al, 0xFE
    stosw
    mov al, ' '
    stosw
    lea si, [bx + W_TITLE]
    call back_puts
    mov di, [bx + W_W]
    sub di, 6
    shl di, 1
    add di, trow
    mov si, s_btns
    call back_puts
    mov di, [bx + W_W]
    sub di, 3
    shl di, 1
    add di, trow
    mov ah, A_BTN
    mov si, s_btnx
    call back_puts
    pop bx
    pop di
    pop si
    pop cx
    pop ax
    ret

; DS:SI ASCIIZ -> ES:DI (пары символ/атрибут AH)
back_puts:
    lodsb
    test al, al
    jz .r
    stosw
    jmp back_puts
.r: ret

; сообщение на панели задач на ~3 секунды
tb_message:
    push di
    push cx
    mov di, tb_msg
    mov cx, 19
    call str_copy_n
    FAPI FAPI_TICKS
    add ax, 55
    mov [tb_msg_until], ax
    pop cx
    pop di
    ret

;---------------------------------------------------------------- экран и обои
screen_init:
    mov ax, 0x0003
    int 0x10
    mov ax, 0x1112                  ; шрифт 8x8 -> 50 строк
    xor bl, bl
    int 0x10
    mov ax, 0x1003                  ; отключить мигание: 16 цветов фона
    xor bl, bl
    int 0x10
    mov ah, 0x01
    mov cx, 0x2000
    int 0x10
    ret
screen_restore:
    mov ax, 0x0003
    int 0x10
    ret

; построить обои (wall, 80x50 знакомест) по настройкам
wall_build:
    cmp byte [cfg_wall], 0
    jne .bmp
.tone:
    push ds
    pop es
    mov di, wall
    mov al, [cfg_tone]
    mov ah, al
    shl ah, 1
    shl ah, 1
    shl ah, 1
    shl ah, 1
    or ah, al
    or ah, 0x08                     ; фон = тон, текст = яркий тон
    mov al, 0xB0                    ; узор
    mov cx, 4000
    rep stosw
    ret
.bmp:
    call bmp_wall
    jnc .ok
    mov si, s_badbmp
    call tb_message
    jmp .tone
.ok:
    ret

; обои из BMP: 80x98 «пикселей» (символ DFh: верхняя половина — цвет текста, нижняя — фон)
bmp_wall:
    push es
    push ds
    pop es
    ; заголовок
    mov si, cfg_wall
    mov di, rdbuf
    xor bx, bx
    mov cx, 512
    FAPI FAPI_READAT
    jc .fail
    cmp ax, 54
    jb .fail
    cmp word [rdbuf], 'BM'
    jne .fail
    cmp word [rdbuf + 30], 0        ; без сжатия
    jne .fail
    mov ax, [rdbuf + 10]
    mov [bm_off], ax
    mov ax, [rdbuf + 18]
    mov [bm_w], ax
    mov ax, [rdbuf + 22]
    mov [bm_h], ax
    mov ax, [rdbuf + 28]
    mov [bm_bpp], ax
    cmp ax, 24
    je .bpp_ok
    cmp ax, 8
    jne .fail
    ; палитра: 256 x BGR0 сразу после заголовка (54)
    mov si, rdbuf + 54
    mov di, bm_pal
    mov cx, 458                     ; в первом секторе есть 458 байт палитры
    rep movsb
    mov si, cfg_wall
    mov di, rdbuf
    mov bx, 1
    mov cx, 512
    FAPI FAPI_READAT
    jc .fail
    mov si, rdbuf
    mov di, bm_pal + 458
    mov cx, 1024 - 458
    rep movsb
.bpp_ok:
    ; байт на строку (выравнивание по 4)
    mov ax, [bm_w]
    cmp word [bm_bpp], 24
    jne .rb8
    mov dx, 3
    mul dx
.rb8:
    add ax, 3
    and ax, 0xFFFC
    mov [bm_rowb], ax
    cmp ax, 3500
    ja .fail
    ; по целевым строкам ty = 0..97: исходная y = ty*h/98, строка файла r = h-1-y
    mov word [ty], 0
.ty:
    mov ax, [ty]
    mul word [bm_h]
    mov cx, 98
    div cx                          ; AX = y
    mov cx, [bm_h]
    dec cx
    sub cx, ax                      ; r
    ; смещение строки = off + r*rowb (32 бита)
    mov ax, cx
    mul word [bm_rowb]
    add ax, [bm_off]
    adc dx, 0
    ; сектор = смещение / 512, остаток
    mov cx, ax
    and cx, 511
    mov [bm_rem], cx
    push cx
    mov cl, 9
    shr ax, cl
    mov cl, 7
    shl dx, cl
    or ax, dx                       ; сектор (младшие 16 бит)
    pop cx
    mov bx, ax
    mov cx, [bm_rowb]
    add cx, [bm_rem]
    mov si, cfg_wall
    mov di, rdbuf
    push ds
    pop es
    FAPI FAPI_READAT
    jc .fail
    ; пиксели строки: tx = 0..79, x = tx*w/80
    mov word [tx], 0
.tx:
    mov ax, [tx]
    mul word [bm_w]
    mov cx, 80
    div cx                          ; AX = x
    mov si, rdbuf
    add si, [bm_rem]
    cmp word [bm_bpp], 8
    je .px8
    mov cx, ax
    shl ax, 1
    add ax, cx                      ; x*3
    add si, ax
    mov al, [si]                    ; B
    mov cl, [si + 1]                ; G
    mov ch, [si + 2]                ; R
    jmp .near
.px8:
    add si, ax
    mov al, [si]
    xor ah, ah
    shl ax, 1
    shl ax, 1
    mov si, bm_pal
    add si, ax
    mov al, [si]
    mov cl, [si + 1]
    mov ch, [si + 2]
.near:
    call nearest_color              ; AL=B CL=G CH=R -> AL индекс 0..15
    mov bx, [ty]
    push ax
    mov ax, bx
    mov bl, 80
    mul bl
    add ax, [tx]
    mov bx, ax
    pop ax
    mov [pix + bx], al
    inc word [tx]
    cmp word [tx], 80
    jb .tx
    inc word [ty]
    cmp word [ty], 98
    jb .ty
    ; pix -> wall
    mov si, pix
    mov di, wall
    mov cx, 49 * 80
.cell:
    mov al, [si]                    ; верхний пиксель -> цвет текста
    mov ah, [si + 80]               ; нижний -> фон
    shl ah, 1
    shl ah, 1
    shl ah, 1
    shl ah, 1
    or ah, al
    mov al, 0xDF
    stosw
    inc si
    ; в конце строки перескочить нижнюю строку пикселей
    push ax
    mov ax, si
    sub ax, pix
    push dx
    xor dx, dx
    push cx
    mov cx, 80
    div cx
    pop cx
    test dx, dx
    pop dx
    pop ax
    jnz .cn
    add si, 80
.cn:
    loop .cell
    ; последняя строка (панель задач) — любой фон
    pop es
    clc
    ret
.fail:
    pop es
    stc
    ret

; ближайший из 16 цветов VGA: AL=B, CL=G, CH=R -> AL индекс
nearest_color:
    push bx
    push dx
    push si
    push di
    mov [nc_b], al
    mov [nc_g], cl
    mov [nc_r], ch
    mov si, vga_rgb
    xor bx, bx
    mov di, 0x7FFF
.l:
    xor dx, dx
    mov al, [si]
    sub al, [nc_r]
    jnc .r1
    neg al
.r1:
    xor ah, ah
    add dx, ax
    mov al, [si + 1]
    sub al, [nc_g]
    jnc .g1
    neg al
.g1:
    xor ah, ah
    add dx, ax
    mov al, [si + 2]
    sub al, [nc_b]
    jnc .b1
    neg al
.b1:
    xor ah, ah
    add dx, ax
    cmp dx, di
    jae .n
    mov di, dx
    mov [nc_best], bl
.n:
    add si, 3
    inc bx
    cmp bx, 16
    jb .l
    mov al, [nc_best]
    pop di
    pop si
    pop dx
    pop bx
    ret

;---------------------------------------------------------------- настройки
cfg_load:
    mov byte [cfg_tone], 1
    mov byte [cfg_wall], 0
    mov si, s_cfg
    push ds
    pop es
    mov di, rdbuf
    mov cx, 100
    FAPI FAPI_READFILE
    jc .r
    mov si, rdbuf
    mov byte [rdbuf + 99], 0
    cmp byte [si], 'T'
    jne .w
    mov al, [si + 2]
    sub al, '0'
    cmp al, 7
    ja .r
    mov [cfg_tone], al
    ret
.w:
    cmp byte [si], 'W'
    jne .r
    add si, 2
    mov di, cfg_wall
    mov cx, 79
.cp:
    lodsb
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    test al, al
    jz .end
    stosb
    loop .cp
.end:
    mov byte [di], 0
.r: ret
cfg_save:
    mov di, rdbuf
    cmp byte [cfg_wall], 0
    jne .w
    mov al, 'T'
    stosb
    mov al, ' '
    stosb
    mov al, [cfg_tone]
    add al, '0'
    stosb
    jmp .end
.w:
    mov al, 'W'
    stosb
    mov al, ' '
    stosb
    mov si, cfg_wall
    call str_copy
.end:
    mov al, 13
    stosb
    mov al, 10
    stosb
    mov cx, di
    sub cx, rdbuf
    mov si, s_cfg
    push ds
    pop es
    mov di, rdbuf
    FAPI FAPI_WRITEFILE
    ret

;---------------------------------------------------------------- строки
; AX = смещение (кратно 16) -> AX = сегмент
seg_of:
    push cx
    mov cl, 4
    shr ax, cl
    mov cx, cs
    add ax, cx
    pop cx
    ret
skip_sp:
    cmp byte [si], ' '
    jne .r
    inc si
    jmp skip_sp
.r: ret
; DS:SI -> ES:DI, DI остаётся на 0
str_copy:
    lodsb
    stosb
    test al, al
    jnz str_copy
    dec di
    ret
; не более CX символов + 0
str_copy_n:
    jcxz .z
.l:
    lodsb
    test al, al
    jz .e
    stosb
    loop .l
.e:
    mov byte [di], 0
    ret
.z:
    mov byte [di], 0
    ret
; SI -> после последнего '/'
basename:
    push ax
    push di
    mov di, si
.l:
    mov al, [di]
    test al, al
    jz .d
    inc di
    cmp al, '/'
    jne .l
    mov si, di
    jmp .l
.d:
    pop di
    pop ax
    ret
; AX -> десятичная ASCIIZ в DS:DI
u16_to_str:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.d:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .d
.o:
    pop ax
    add al, '0'
    stosb
    loop .o
    mov byte [di], 0
    pop dx
    pop cx
    pop bx
    pop ax
    ret

;---------------------------------------------------------------- данные
s_fmpath  db "/SYSTEM/SYSAPPS/FM.FAP", 0
s_empty   db 0
s_sysapps db "/SYSTEM/SYSAPPS/", 0
s_slash   db "/", 0
s_fapext  db ".FAP", 0
s_cfg     db "/SYSTEM/GUI.CFG", 0
s_nofm    db "gui: cannot load /SYSTEM/SYSAPPS/FM.FAP", 13, 10, 0
s_usage   db "Usage: gui [-t TONE(0-7) | -w FILE.BMP]", 13, 10, 0
s_nowin   db "No free window", 0
s_badbmp  db "Bad wallpaper BMP", 0
s_pause   db 13, 10, "[ press any key ]", 0
s_tbname  db " Ferrix GUI ", 0
s_btns    db "[_]", 0
s_btnx    db "[x]", 0
vga_rgb:  db 0,0,0, 0,0,170, 0,170,0, 0,170,170, 170,0,0, 170,0,170, 170,85,0, 170,170,170
          db 85,85,85, 85,85,255, 85,255,85, 85,255,255, 255,85,85, 255,85,255, 255,255,85, 255,255,255
; стартовые позиции окон по слотам (x, y)
win_pos   dw 0, 0,  0, 23,  10, 12
ex_x0     dw 0
ex_x1     dw 0
ex_y0     dw 0
ex_y1     dw 0

cur_win   dw -1
cur_rec   dw 0
cur_ctx   dw main_ctx
main_ctx  dw 0, 0
main_sp_init dw 0
req       db REQ_NONE
req_win   dw 0
req_path  times 80 db 0
req_args  times 128 db 0
rc_tok    times 14 db 0
rc_rest   dw 0
rc_cmd    dw 0
rc_pause  db 0
ret_fl    dw 0
dirty     db 1
anim_pending dw 0
sh_savecur   dw 0
sh_saveseg   dw 0
an_step   dw 0
an0_x     dw 0
an0_y     dw 0
an0_w     dw 0
an0_h     dw 0
an1_x     dw 0
an1_y     dw 0
an1_w     dw 0
an1_h     dw 0
anc_x     dw 0
anc_y     dw 0
anc_w     dw 0
anc_h     dw 0
zcount    dw 0
zorder    db 0, 0, 0, 0
sp_win    dw 0
cp_idx    dw 0
cp_rec    dw 0
title_attr db 0
m_col     dw 0
m_row     dw 0
m_prev    db 0
m_new     db 0
drag_win  dw -1
yield_win dw 0
drag_dx   dw 0
drag_dy   dw 0
tb_msg    times 20 db 0
tb_msg_until dw 0
tmpnum    times 8 db 0
cfg_tone  db 1
cfg_wall  times 80 db 0
bm_off    dw 0
bm_w      dw 0
bm_h      dw 0
bm_bpp    dw 0
bm_rowb   dw 0
bm_rem    dw 0
tx        dw 0
ty        dw 0
nc_best   db 0
nc_r      db 0
nc_g      db 0
nc_b      db 0

windows:
    ; слот 0
    db 0, 0
    dw 0x5000, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0
    dw 0
    times W_SIZE - 22 db 0
    db 0, 0
    dw 0x7000, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0
    dw 0
    times W_SIZE - 22 db 0
    db 0, 0
    dw 0x8000, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0
    dw 0
    times W_SIZE - 22 db 0

section .bss                        ; буферы вне файла (сразу за образом в сегменте)
trow      resb 160
pix       resb 80 * 98
bm_pal    resb 1024
rdbuf     resb 4096
wall      resb 8000
back      resb 8000
    alignb 16
vscr0     resb 4000
    alignb 16
vscr1     resb 4000
    alignb 16
vscr2     resb 4000
