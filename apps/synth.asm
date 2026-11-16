;======================================
; File name: apps/synth.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: Synth — полифонический синтезатор на Intel HDA (.FAP).
;              Клавиатура-пианино (2,5 октавы), 4 волны, ADSR-пресеты, эхо,
;              запись/воспроизведение сыгранного и сохранение в .SNG
;======================================
; Запуск: synth [FILE.SNG]   (по умолчанию /SONG.SNG — для F9/F10)
; Нужен 386+ и контроллер HDA (как для play ... hda). Звук: 24 кГц, 16 бит, моно,
; через FAPI_AUDIO — программа сама заполняет буфер из двух половин по 1024 сэмпла (43 мс).
; Клавиши читаются прямо с контроллера клавиатуры (перехват IRQ1), поэтому есть
; настоящие нажатие/отпускание — до 8 голосов одновременно.
;
;   нижний ряд  Z S X D C V G B H N J M , L . ; /   — октава N (C..E следующей)
;   верхний ряд Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P   — октава N+1
;   F1..F4 волна (синус/прямоугольник/пила/треугольник)   F5/F6 октава -/+
;   F7 эхо вкл/выкл   F8 огибающая (пианино/орган/пад/щипок)
;   Space запись старт/стоп   Enter воспроизвести   F9 сохранить   F10 загрузить
;   Backspace очистить запись   Esc выход

%include "fapi.inc"

    FAPI_HEADER

cpu 386

SR        equ 24000
HALF      equ 1024                  ; сэмплов в половине буфера
NVOICE    equ 8
V_SIZE    equ 20
V_PHASE   equ 0                     ; dd фаза (индекс в таблице = старшие 8 бит)
V_STEP    equ 4                     ; dd шаг
V_WAVE    equ 8                     ; dw смещение таблицы волны
V_ENV     equ 10                    ; dw уровень огибающей 0..32767
V_STATE   equ 12                    ; db 0 свободен, 1 атака, 2 спад, 3 удержание, 4 затухание
V_NOTE    equ 13                    ; db нота (0 = C0) 
V_AGE     equ 14                    ; dw возраст (для вытеснения)
ECHO_LEN  equ 8192                  ; сэмплов задержки (341 мс)
EV_MAX    equ 2000
EV_SIZE   equ 8                     ; dd время (сэмплов), db вид (1 on/0 off), db нота, db волна, db пресет
KB_RING   equ 64

A_TITLE   equ 0x1F
A_TEXT    equ 0x07
A_KEY     equ 0x70                  ; белая клавиша
A_KEYON   equ 0x2F                  ; нажатая
A_BLACK   equ 0x08                  ; чёрная клавиша
A_BLACKON equ 0x2A
A_HELP    equ 0x08
A_VAL     equ 0x0E
A_REC     equ 0x4F

start:
    cld
    ; имя файла из аргументов
    mov si, 0x80
    call skip_sp
    cmp byte [si], 0
    je .noarg
    mov di, fname
    mov cx, 63
.cp: lodsb
    cmp al, ' '
    jbe .cpd
    stosb
    loop .cp
.cpd:
    mov byte [di], 0
    ; ключ -p: проиграть файл и выйти (используется play X.SNG и ferramp)
    call skip_sp
    cmp byte [si], '-'
    jne .noarg
    mov al, [si + 1]
    or al, 0x20
    cmp al, 'p'
    jne .noarg
    mov byte [autoplay], 1
.noarg:
    ; таблицы волн
    call build_waves
    ; голоса
    mov di, voices
    mov cx, NVOICE * V_SIZE
    xor al, al
    rep stosb
    call set_preset
    ; звук
    push ds
    pop es
    mov di, abuf
    mov cx, HALF * 2
    mov bx, 0x0110                  ; 24 кГц (48/2), 16 бит, моно
    xor al, al
    FAPI FAPI_AUDIO
    jc no_audio
    ; клавиатура: перехват IRQ1
    call kb_hook
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    call draw_screen
    mov byte [cur_half], 0
    cmp byte [autoplay], 0
    je main_loop
    ; --- режим -p: загрузить и сразу играть ---
    FAPI_PUTSAT 10, 2, msg_auto, A_HELP
    call load_song
    cmp byte [fmsg], 3
    jne .auto_err
    call start_play
    jmp main_loop
.auto_err:
    mov al, 2
    FAPI FAPI_AUDIO
    call kb_unhook
    FAPI FAPI_KBFLUSH
    FAPI FAPI_CLS
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI_PRINT msg_autoerr
    FAPI_QUIT
    ; обе половины — тишина в начале (буфер обнулён .bss)
main_loop:
    ; --- клавиши ---
    call kb_poll
    ; --- заполнить свободную половину, когда играющая сменилась ---
    mov al, 1
    FAPI FAPI_AUDIO
    cmp al, [cur_half]
    je .idle
    ; играет AL, значит [cur_half] доиграла -> заполнить её
    mov bl, [cur_half]
    mov [cur_half], al
    mov di, abuf
    test bl, bl
    jz .f0
    add di, HALF * 2
.f0:
    call render
    call draw_status
    ; режим -p: песня доиграла -> ещё ~1 с хвоста (затухание) и выход
    cmp byte [autoplay], 0
    je main_loop
    cmp byte [playing], 0
    jne main_loop
    inc byte [auto_tail]
    cmp byte [auto_tail], 24
    jb main_loop
    jmp quit
.idle:
    FAPI FAPI_KEYHIT                ; под gui это даёт оболочке перерисовать экран и опросить мышь
    hlt                             ; до следующего прерывания (таймер/клавиатура)
    jmp main_loop

quit:
    mov al, 2
    FAPI FAPI_AUDIO
    call kb_unhook
    FAPI FAPI_KBFLUSH
    FAPI FAPI_CLS
    mov cx, 0x0607
    FAPI FAPI_CURSOR
    FAPI_QUIT

no_audio:
    FAPI_PRINT msg_noaudio
    FAPI_QUIT

;---------------------------------------------------------------- рендер HALF сэмплов в DS:DI
render:
    pusha
    mov cx, HALF
.s:
    push cx
    push di
    ; событие воспроизведения?
    cmp byte [playing], 0
    je .noplay
.evchk:
    mov bx, [play_idx]
    cmp bx, [nev]
    jae .playdone
    shl bx, 3
    mov eax, [events + bx]
    add eax, [play_base]
    cmp eax, [stime]
    ja .noplay
    ; сработало
    mov al, [events + bx + 5]       ; нота
    mov ah, [events + bx + 4]       ; вид
    push bx
    test ah, ah
    jz .evoff
    mov cl, [events + bx + 6]
    mov ch, [events + bx + 7]
    call note_on_wp
    jmp .evnext
.evoff:
    call note_off
.evnext:
    pop bx
    inc word [play_idx]
    jmp .evchk
.playdone:
    mov byte [playing], 0
    mov byte [redraw], 1
.noplay:
    ; --- микс голосов ---
    xor edx, edx                    ; аккумулятор
    mov si, voices
    mov cx, NVOICE
.v:
    cmp byte [si + V_STATE], 0
    je .vnext
    mov eax, [si + V_PHASE]
    add eax, [si + V_STEP]
    mov [si + V_PHASE], eax
    shr eax, 24
    mov bx, [si + V_WAVE]
    shl ax, 1
    add bx, ax
    movsx eax, word [bx]
    movzx ebx, word [si + V_ENV]
    imul eax, ebx
    sar eax, 15
    add edx, eax
    ; огибающая
    call env_step
.vnext:
    add si, V_SIZE
    loop .v
    ; --- эхо ---
    cmp byte [echo_on], 0
    je .noecho
    mov bx, [echo_pos]
    shl bx, 1
    movsx eax, word [echo + bx]
    imul eax, 3
    sar eax, 3                      ; 3/8
    add edx, eax
    mov eax, edx
    call clamp16
    mov [echo + bx], ax
    mov bx, [echo_pos]
    inc bx
    cmp bx, ECHO_LEN
    jb .ep
    xor bx, bx
.ep:
    mov [echo_pos], bx
.noecho:
    mov eax, edx
    call clamp16
    pop di
    pop cx
    stosw
    inc dword [stime]
    dec cx
    jnz .s
    popa
    ret

; EAX -> AX с насыщением до int16
clamp16:
    push ebx
    movsx ebx, ax
    cmp ebx, eax
    je .ok
    mov ax, 0x7FFF
    test eax, eax
    jns .ok
    mov ax, 0x8000
.ok: pop ebx
    ret

; огибающая голоса SI (один шаг)
env_step:
    mov al, [si + V_STATE]
    mov bx, [si + V_ENV]
    cmp al, 1
    je .att
    cmp al, 2
    je .dec
    cmp al, 4
    je .rel
    ret                             ; 3: удержание — без изменений
.att:
    add bx, [e_attack]
    cmp bx, 32767
    jb .st
    mov bx, 32767
    mov byte [si + V_STATE], 2
    jmp .st
.dec:
    sub bx, [e_decay]
    jc .dsus
    cmp bx, [e_sustain]
    ja .st
.dsus:
    mov bx, [e_sustain]
    mov byte [si + V_STATE], 3
    jmp .st
.rel:
    sub bx, [e_release]
    ja .st
    xor bx, bx
    mov byte [si + V_STATE], 0
.st:
    mov [si + V_ENV], bx
    ret

;---------------------------------------------------------------- ноты
; AL = нота (полутоны от C0); волна/пресет — текущие
note_on:
    mov cl, [wave]
    mov ch, [preset]
; AL нота, CL волна, CH пресет (для воспроизведения записи)
note_on_wp:
    pusha
    push ax
    ; уже звучит (автоповтор)? — ничего
    mov si, voices
    mov dx, NVOICE
.chk:
    cmp byte [si + V_STATE], 0
    je .chn
    cmp byte [si + V_STATE], 4
    je .chn
    cmp [si + V_NOTE], al
    je .busy
.chn:
    add si, V_SIZE
    dec dx
    jnz .chk
    ; свободный голос, иначе самый старый
    mov si, voices
    mov dx, NVOICE
    mov di, voices
    mov bx, 0
.fr:
    cmp byte [si + V_STATE], 0
    je .got
    cmp [si + V_AGE], bx
    jb .fn
    mov bx, [si + V_AGE]
    mov di, si
.fn:
    add si, V_SIZE
    dec dx
    jnz .fr
    mov si, di
.got:
    ; состарить все
    mov di, voices
    mov dx, NVOICE
.ag:
    inc word [di + V_AGE]
    add di, V_SIZE
    dec dx
    jnz .ag
    mov word [si + V_AGE], 0
    mov [si + V_NOTE], al
    mov byte [si + V_STATE], 1
    mov word [si + V_ENV], 0
    mov dword [si + V_PHASE], 0
    ; волна
    mov bl, cl
    xor bh, bh
    shl bx, 9                       ; * 512
    add bx, waves
    mov [si + V_WAVE], bx
    ; шаг: нота = октава*12 + полутон; таблица для 4-й октавы
    xor ah, ah
    mov bl, 12
    div bl                          ; AL октава, AH полутон
    mov bl, ah
    xor bh, bh
    shl bx, 2
    mov edx, [steps + bx]
    mov cl, 4
    sub cl, al
    jbe .up
    shr edx, cl
    jmp .sts
.up:
    neg cl
    shl edx, cl
.sts:
    mov [si + V_STEP], edx
    pop ax
    popa
    ret
.busy:
    pop ax
    popa
    ret

; AL = нота -> затухание
note_off:
    pusha
    mov si, voices
    mov cx, NVOICE
.l:
    cmp byte [si + V_STATE], 0
    je .n
    cmp byte [si + V_STATE], 4
    je .n
    cmp [si + V_NOTE], al
    jne .n
    mov byte [si + V_STATE], 4
.n: add si, V_SIZE
    loop .l
    popa
    ret

all_off:
    mov si, voices
    mov cx, NVOICE
.l: cmp byte [si + V_STATE], 0
    je .n
    mov byte [si + V_STATE], 4
.n: add si, V_SIZE
    loop .l
    ret

; текущий пресет -> e_attack..e_release
set_preset:
    mov bl, [preset]
    xor bh, bh
    shl bx, 3
    mov ax, [presets + bx]
    mov [e_attack], ax
    mov ax, [presets + bx + 2]
    mov [e_decay], ax
    mov ax, [presets + bx + 4]
    mov [e_sustain], ax
    mov ax, [presets + bx + 6]
    mov [e_release], ax
    ret

;---------------------------------------------------------------- клавиатура (IRQ1)
kb_hook:
    push es
    xor ax, ax
    mov es, ax
    cli
    mov ax, [es:0x24]
    mov [old9], ax
    mov ax, [es:0x26]
    mov [old9 + 2], ax
    mov word [es:0x24], kb_isr
    mov [es:0x26], cs
    sti
    pop es
    ret

kb_unhook:
    push es
    xor ax, ax
    mov es, ax
    cli
    mov ax, [old9]
    mov [es:0x24], ax
    mov ax, [old9 + 2]
    mov [es:0x26], ax
    sti
    pop es
    ret

kb_isr:
    push ax
    push bx
    push ds
    mov ax, cs
    mov ds, ax
    in al, 0x60
    cmp al, 0xE0                    ; префикс расширенных — пропускаем
    je .d
    mov bx, [kb_wr]
    mov [kbring + bx], al
    inc bx
    and bx, KB_RING - 1
    cmp bx, [kb_rd]
    je .d                           ; переполнение — потерять
    mov [kb_wr], bx
.d:
    pop ds
    pop bx
    pop ax
    jmp far [cs:old9]

; обработать накопленные скан-коды
kb_poll:
    FAPI FAPI_KBFLUSH               ; BIOS-буфер нам не нужен
.l:
    mov bx, [kb_rd]
    cmp bx, [kb_wr]
    je .d
    mov al, [kbring + bx]
    inc bx
    and bx, KB_RING - 1
    mov [kb_rd], bx
    call kb_event
    jmp .l
.d: ret

; AL = скан-код (бит 7 = отпускание)
kb_event:
    mov ah, al
    and al, 0x7F
    test ah, 0x80
    jnz .release
    ; --- нажатие ---
    cmp al, 0x01
    je .esc
    cmp byte [autoplay], 0
    jne .esc                        ; в режиме -p любая клавиша = стоп
    cmp al, 0x3B                    ; F1..F10
    jb .note
    cmp al, 0x44
    ja .note
    sub al, 0x3B
    cmp al, 4
    jb .setwave
    cmp al, 4
    je .octdn
    cmp al, 5
    je .octup
    cmp al, 6
    je .echo
    cmp al, 7
    je .preset
    cmp al, 8
    je .save
    jmp load_song
.esc:
    pop ax                          ; адрес возврата kb_poll
    jmp quit
.setwave:
    mov [wave], al
    jmp .rd
.octdn:
    cmp byte [octave], 1
    jbe .r
    dec byte [octave]
    jmp .rd
.octup:
    cmp byte [octave], 6
    jae .r
    inc byte [octave]
    jmp .rd
.echo:
    xor byte [echo_on], 1
    jmp .rd
.preset:
    inc byte [preset]
    and byte [preset], 3
    call set_preset
    jmp .rd
.save:
    jmp save_song
.note:
    cmp al, 0x39                    ; Space — запись
    je .rec
    cmp al, 0x1C                    ; Enter — воспроизвести
    je .play
    cmp al, 0x0E                    ; Backspace — очистить
    je .clear
    call scan_to_note
    jc .r
    push ax
    call note_on
    pop ax
    mov ah, 1
    call record_ev
    ret
.release:
    call scan_to_note
    jc .r
    push ax
    call note_off
    pop ax
    xor ah, ah
    call record_ev
.r: ret
.rd:
    mov byte [redraw], 1
    ret
.rec:
    xor byte [recording], 1
    cmp byte [recording], 0
    je .rd
    mov byte [playing], 0
    mov word [nev], 0
    call now_time
    mov [rec_base], eax
    jmp .rd
.play:
    call start_play
    jmp .rd
.clear:
    mov word [nev], 0
    mov byte [recording], 0
    mov byte [playing], 0
    jmp .rd

; запустить воспроизведение записанных событий
start_play:
    cmp word [nev], 0
    je .r
    mov byte [recording], 0
    call all_off
    mov word [play_idx], 0
    call now_time
    add eax, SR / 10
    mov [play_base], eax
    mov byte [playing], 1
.r: ret

; текущее время в сэмплах (уже отрендеренное + позиция в играющей половине)
now_time:
    push dx
    mov al, 1
    FAPI FAPI_AUDIO
    shr dx, 1
    movzx eax, dx
    add eax, [stime]
    sub eax, HALF                   ; stime указывает на конец заполненной половины
    pop dx
    ret

; записать событие: AL нота, AH вид
record_ev:
    cmp byte [recording], 0
    je .r
    mov bx, [nev]
    cmp bx, EV_MAX
    jae .r
    push ax
    shl bx, 3
    call now_time
    sub eax, [rec_base]
    mov [events + bx], eax
    pop ax
    mov [events + bx + 4], ah
    mov [events + bx + 5], al
    mov al, [wave]
    mov [events + bx + 6], al
    mov al, [preset]
    mov [events + bx + 7], al
    inc word [nev]
    mov byte [redraw], 1
.r: ret

; AL скан-код -> AL нота (с учётом октавы); CF=1 не нота
scan_to_note:
    push bx
    push cx
    mov bx, keymap
    xor cx, cx
.l:
    cmp byte [bx], 0
    je .no
    cmp [bx], al
    je .f
    inc bx
    inc cx
    jmp .l
.f:
    cmp cx, 17
    jb .lo
    sub cx, 5                       ; верхний ряд (индексы 17..33) = нижний + 12 полутонов
.lo:
    mov al, [octave]
    mov ah, 12
    mul ah
    add ax, cx
    pop cx
    pop bx
    clc
    ret
.no:
    pop cx
    pop bx
    stc
    ret

;---------------------------------------------------------------- файлы .SNG
save_song:
    mov word [sng_hdr + 4], 0
    mov ax, [nev]
    mov [sng_hdr + 4], ax
    ; заголовок + события подряд: события лежат сразу за sng_hdr? нет — соберём размер
    push ds
    pop es
    mov si, fname
    mov di, sng_hdr
    mov cx, 8
    FAPI FAPI_WRITEFILE
    jc .err
    mov ax, [nev]
    shl ax, 3
    mov cx, ax
    jcxz .ok
    mov si, fname
    mov di, events
    FAPI FAPI_APPEND
    jc .err
.ok:
    mov byte [fmsg], 1
    mov byte [redraw], 1
    ret
.err:
    mov byte [fmsg], 2
    mov byte [redraw], 1
    ret

load_song:
    push ds
    pop es
    mov si, fname
    mov di, ldbuf
    mov cx, 8 + EV_MAX * EV_SIZE
    FAPI FAPI_READFILE
    jc .err
    cmp ax, 8
    jb .err
    cmp dword [ldbuf], 'FSNG'
    jne .err
    mov cx, [ldbuf + 4]
    cmp cx, EV_MAX
    ja .err
    mov [nev], cx
    shl cx, 2
    mov si, ldbuf + 8
    mov di, events
    rep movsw
    mov byte [fmsg], 3
    mov byte [redraw], 1
    ret
.err:
    mov byte [fmsg], 2
    mov byte [redraw], 1
    ret

;---------------------------------------------------------------- волны
build_waves:
    ; 0: синус — из таблицы
    mov si, sine
    mov di, waves
    mov cx, 256
    rep movsw
    ; 1: прямоугольник
    mov cx, 128
    mov ax, 9000
    rep stosw
    mov cx, 128
    mov ax, -9000
    rep stosw
    ; 2: пила -12000..12000
    mov cx, 256
    mov ax, -12000
.saw:
    stosw
    add ax, 94
    loop .saw
    ; 3: треугольник
    mov cx, 128
    mov ax, -12000
.t1:
    stosw
    add ax, 188
    loop .t1
    mov cx, 128
.t2:
    stosw
    sub ax, 188
    loop .t2
    ret

;---------------------------------------------------------------- экран
draw_screen:
    FAPI FAPI_CLS
    FAPI_PUTSAT 0, 0, msg_title, A_TITLE
    ; заголовок на всю строку
    mov dh, 0
    mov dl, 0
    mov ch, 1
    mov cl, 80
    mov al, ' '
    mov bl, A_TITLE
    FAPI FAPI_FILLRECT
    FAPI_PUTSAT 0, 2, msg_title, A_TITLE
    FAPI_PUTSAT 2, 2, msg_help1, A_HELP
    FAPI_PUTSAT 3, 2, msg_help2, A_HELP
    FAPI_PUTSAT 4, 2, msg_help3, A_HELP
    FAPI_PUTSAT 6, 2, lbl_wave, A_TEXT
    FAPI_PUTSAT 7, 2, lbl_oct, A_TEXT
    FAPI_PUTSAT 8, 2, lbl_env, A_TEXT
    FAPI_PUTSAT 9, 2, lbl_echo, A_TEXT
    FAPI_PUTSAT 6, 40, lbl_rec, A_TEXT
    FAPI_PUTSAT 7, 40, lbl_file, A_TEXT
    FAPI_PUTSAT 7, 48, fname, A_VAL
    FAPI_PUTSAT 22, 2, msg_rows, A_HELP
    mov byte [redraw], 1
    call draw_status
    call draw_keys
    ret

draw_status:
    cmp byte [redraw], 0
    jne .go
    ; клавиши перерисовываются всегда (состояние голосов меняется)
    jmp draw_keys
.go:
    mov byte [redraw], 0
    mov al, [wave]
    mov si, wave_names
    call name_at6
    FAPI_PUTSAT 6, 14, si, A_VAL
    mov dh, 7
    mov dl, 14
    mov ax, [octave]
    xor ah, ah
    mov bl, A_VAL
    mov cl, 3
    call num_at
    mov al, [preset]
    mov si, env_names
    call name_at6
    FAPI_PUTSAT 8, 14, si, A_VAL
    mov si, s_off
    cmp byte [echo_on], 0
    je .e
    mov si, s_on
.e: FAPI_PUTSAT 9, 14, si, A_VAL
    ; запись
    mov si, s_idle
    mov bl, A_VAL
    cmp byte [recording], 0
    je .nr
    mov si, s_recording
    mov bl, A_REC
.nr:
    cmp byte [playing], 0
    je .np
    mov si, s_playing
    mov bl, 0x2F
.np:
    mov dh, 6
    mov dl, 48
    FAPI FAPI_PUTSAT
    mov dh, 6
    mov dl, 62
    mov ax, [nev]
    mov bl, A_VAL
    mov cl, 5
    call num_at
    FAPI_PUTSAT 6, 68, s_events, A_TEXT
    ; сообщение файла
    mov si, s_blank
    cmp byte [fmsg], 1
    jne .f2
    mov si, s_saved
.f2:
    cmp byte [fmsg], 2
    jne .f3
    mov si, s_ferr
.f3:
    cmp byte [fmsg], 3
    jne .f4
    mov si, s_loaded
.f4:
    FAPI_PUTSAT 8, 40, si, A_VAL
    jmp draw_keys

; AL индекс, SI таблица имён по 6 байт -> SI
name_at6:
    xor ah, ah
    mov bl, 6
    mul bl
    add si, ax
    ret

; клавиатура: белые клавиши 3 знака, чёрные над ними. Строки 12..20
draw_keys:
    ; верхняя октава (ряд Q), нижняя (ряд Z) — рисуем 2 ряда по 17 клавиш
    mov byte [krow], 12
    mov byte [koct], 1              ; +1 октава
    mov si, keylab_q
    call draw_row
    mov byte [krow], 17
    mov byte [koct], 0
    mov si, keylab_z
    call draw_row
    ret

; один ряд: SI -> 17 букв клавиш; [krow], [koct]
draw_row:
    mov cx, 17
    xor bx, bx                      ; индекс полутона 0..16
.k:
    push cx
    push si
    push bx
    ; состояние: звучит ли нота
    mov al, [octave]
    add al, [koct]
    mov ah, 12
    mul ah
    add ax, bx
    call note_active                ; -> ZF=0 если звучит
    pushf
    ; чёрная или белая? маска полутонов (C# D# F# G# A#) = бит 1,3,6,8,10, 13,15
    mov ax, bx
    push bx
    xor dx, dx
    mov cl, 12
    div cl                          ; AH полутон в октаве
    mov cl, ah
    mov ax, 0x054A                  ; биты 1,3,6,8,10
    shr ax, cl
    pop bx
    test al, 1
    jnz .black
    ; белая: колонка = 4 + белый_индекс*4, высота 4 (строки krow+1..krow+4)
    call white_index                ; BX -> AL индекс белой
    mov dl, al
    shl dl, 2
    add dl, 4
    mov dh, [krow]
    inc dh
    mov ch, 4
    mov cl, 3
    popf
    mov bl, A_KEY
    jz .wdraw
    mov bl, A_KEYON
.wdraw:
    mov [kattr], bl
    mov al, ' '
    FAPI FAPI_FILLRECT
    mov dh, [krow]
    add dh, 4
    inc dl
    pop bx
    push bx
    mov al, [si + bx]
    mov bl, [kattr]                 ; буква тем же цветом, что клавиша (FILLRECT портит BX)
    FAPI FAPI_PUTAT
    jmp .next
.black:
    ; чёрная: между белыми — колонка = 4 + белый_индекс(предыдущей)*4 + 3, строки krow+1..krow+2
    call white_index
    mov dl, al
    shl dl, 2
    add dl, 6
    mov dh, [krow]
    inc dh
    mov ch, 2
    mov cl, 3
    popf
    mov bl, A_BLACK
    jz .bdraw
    mov bl, A_BLACKON
.bdraw:
    mov al, 0xDB
    FAPI FAPI_FILLRECT
    mov dh, [krow]
    pop bx
    push bx
    mov al, [si + bx]
    inc dl
    mov bl, A_TEXT
    FAPI FAPI_PUTAT
.next:
    pop bx
    pop si
    pop cx
    inc bx
    dec cx
    jz .d
    jmp .k
.d: ret

; BX полутон 0..16 -> AL номер белой клавиши слева (для чёрной — предыдущей белой)
white_index:
    push bx
    push cx
    xor al, al
    mov cx, bx
    jcxz .d
    mov bx, whites
.l: add al, [bx]
    inc bx
    loop .l
.d: pop cx
    pop bx
    ret
whites: db 1,0,1,0,1,1,0,1,0,1,0,1, 1,0,1,0,1   ; сколько белых добавляет переход к следующему полутону

; AX нота -> ZF=0 если звучит (не в затухании)
note_active:
    push si
    push cx
    mov si, voices
    mov cx, NVOICE
.l:
    cmp byte [si + V_STATE], 0
    je .n
    cmp byte [si + V_STATE], 4
    je .n
    cmp [si + V_NOTE], al
    je .yes
.n: add si, V_SIZE
    loop .l
    xor cx, cx                      ; ZF=1
    pop cx
    pop si
    ret
.yes:
    or cx, 1                        ; ZF=0 (cx >= 1 здесь)
    pop cx
    pop si
    ret

; AX число в DH,DL атрибутом BL, CL знаков с пробелами
num_at:
    push ax
    push cx
    push dx
    push di
    mov [tmpdx], dx
    mov di, numbuf + 5
    mov byte [di], 0
    mov ch, 0
.c:
    dec di
    xor dx, dx
    push cx
    mov cx, 10
    div cx
    pop cx
    add dl, '0'
    mov [di], dl
    inc ch
    test ax, ax
    jnz .c
    mov dx, [tmpdx]
.pad:
    cmp ch, cl
    jae .p
    dec di
    mov byte [di], ' '
    inc ch
    jmp .pad
.p:
    mov si, di
    FAPI FAPI_PUTSAT
    pop di
    pop dx
    pop cx
    pop ax
    ret

skip_sp:
    cmp byte [si], ' '
    jne .d
    inc si
    jmp skip_sp
.d: ret

;---------------------------------------------------------------- данные
msg_title   db "SYNTH - Ferrix HDA synthesizer", 0
msg_noaudio db "synth: HDA audio not available (need 386+ and Intel HDA; try 'play x.wav hda')", 13, 10, 0
msg_help1   db "Lower row Z..M,./ = notes, upper row Q..P = one octave up (black keys above)", 0
msg_help2   db "F1-F4 wave   F5/F6 octave   F7 echo   F8 envelope   Esc quit", 0
msg_help3   db "Space record on/off   Enter play   Backspace clear   F9 save   F10 load", 0
lbl_wave    db "Wave:     ", 0
lbl_oct     db "Octave:   ", 0
lbl_env     db "Envelope: ", 0
lbl_echo    db "Echo:     ", 0
lbl_rec     db "Record: ", 0
lbl_file    db "File:   ", 0
msg_rows    db "8 voices, 24 kHz, Intel HDA", 0
msg_auto    db "Playing song file - press any key to stop", 0
msg_autoerr db "synth: cannot load song file (not FSNG or too big)", 13, 10, 0
wave_names  db "sine ", 0, "squar", 0, "saw  ", 0, "tri  ", 0
env_names   db "piano", 0, "organ", 0, "pad  ", 0, "pluck", 0
s_on        db "on ", 0
s_off       db "off", 0
s_idle      db "idle         ", 0
s_recording db " RECORDING   ", 0
s_playing   db " PLAYING     ", 0
s_events    db "events", 0
s_blank     db "                 ", 0
s_saved     db "saved            ", 0
s_loaded    db "loaded           ", 0
s_ferr      db "file error       ", 0
fname       db "/SONG.SNG", 0
            times 64 - 10 db 0
sng_hdr     db "FSNG"
            dw 0, 0
; скан-коды нижнего ряда: C C# D D# E F F# G G# A A# B C C# D D# E
keymap      db 0x2C,0x1F,0x2D,0x20,0x2E,0x2F,0x22,0x30,0x23,0x31,0x24,0x32,0x33,0x26,0x34,0x27,0x35
            db 0x10,0x03,0x11,0x04,0x12,0x13,0x06,0x14,0x07,0x15,0x08,0x16,0x17,0x0A,0x18,0x0B,0x19
            db 0
kattr       db 0
keylab_z    db "ZSXDCVGBHNJM,L.;/"
keylab_q    db "Q2W3ER5T6Y7UI9O0P"
; пресеты ADSR: атака, спад, удержание, затухание (приращения уровня за сэмпл)
presets     dw 400, 2, 9000, 2      ; piano
            dw 600, 0, 32767, 400   ; organ
            dw 6, 0, 32767, 4       ; pad
            dw 3000, 8, 0, 8        ; pluck
; шаги фазы для 4-й октавы (C4..B4), 2^32 * f / 24000
steps:
%include "synth_t.inc"
wave        db 0
preset      db 0
octave      db 3
echo_on     db 1
recording   db 0
playing     db 0
autoplay    db 0
auto_tail   db 0
redraw      db 0
fmsg        db 0
cur_half    db 0
krow        db 0
koct        db 0
e_attack    dw 0
e_decay     dw 0
e_sustain   dw 0
e_release   dw 0
nev         dw 0
play_idx    dw 0
kb_rd       dw 0
kb_wr       dw 0
echo_pos    dw 0
old9        dd 0
stime       dd 0
rec_base    dd 0
play_base   dd 0

section .bss
numbuf      resb 8
tmpdx       resw 1
kbring      resb KB_RING
voices      resb NVOICE * V_SIZE
waves       resb 4 * 512
abuf        resb HALF * 4
echo        resb ECHO_LEN * 2
events      resb EV_MAX * EV_SIZE
ldbuf       resb 8 + EV_MAX * EV_SIZE
