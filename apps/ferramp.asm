;======================================
; File name: apps/ferramp.asm
; Project: FERRIX-OS
; Description: ferramp — музыкальный плеер (WAV + SNG)
;======================================
; Запуск: ferramp [FILE.WAV]
;   без аргумента — список .WAV текущего каталога (если пусто — корня);
;   с файлом — список каталога файла, файл сразу воспроизводится.
; Клавиши: Up/Down выбор, Enter/Space играть, N/P следующий/предыдущий,
;          A автопереход (вкл/выкл), R обновить список, Esc выход. Мышь: клик по строке — играть.
; Воспроизведение делает ядро (команда play: SB16 / HD Audio); любая клавиша останавливает трек.
; Файлы .SNG (записи синтезатора) ядро передаёт в synth -p: играет и возвращается.
; Сборка: nasm -f bin -I. apps/ferramp.asm -o FERRAMP.FAP

%include "fapi.inc"

    FAPI_HEADER

MAXF     equ 64                     ; максимум файлов в списке
ROWS_L   equ 14                     ; строк списка на экране
LIST_Y   equ 6                      ; первая строка списка
STAT_Y   equ 21                     ; строка вывода ядра (Playing: ...)
A_FRAME  equ 0x1B
A_TITLE  equ 0x1E
A_TEXT   equ 0x1F
A_SEL    equ 0x3F
A_DIM    equ 0x19
A_HELP   equ 0x70
A_STAT   equ 0x07

; запись списка: 13 байт имя (8.3 ASCIIZ) + dd размер + dw секунд + db rate(kHz*?) -> 24 байта
F_NAME   equ 0
F_SIZE   equ 13
F_SEC    equ 17
F_RATE   equ 19
F_CHAN   equ 21
F_BITS   equ 22
F_SIZE_R equ 24

start:
    cld
    mov cx, 0x2000
    FAPI FAPI_CURSOR
    ; --- каталог и стартовый файл из аргумента ---
    mov byte [dir], 0
    mov byte [startf], 0
    mov si, 0x80
    call skip_sp
    cmp byte [si], 0
    je .nodirarg
    ; аргумент: путь к файлу -> dir = всё до последнего '/', startf = имя
    mov di, argbuf
    call str_copy
    mov si, argbuf
    xor bx, bx                      ; позиция последнего '/'
    mov di, si
.sl:
    lodsb
    test al, al
    jz .sl_done
    cmp al, '/'
    jne .sl
    mov bx, si                      ; после '/'
    jmp .sl
.sl_done:
    test bx, bx
    jz .only_name
    ; каталог = argbuf[0 .. bx-1)
    mov si, argbuf
    mov di, dir
    mov cx, bx
    sub cx, si
    dec cx                          ; без '/'
    jz .root_dir
    rep movsb
    mov byte [di], 0
    jmp .copy_name
.root_dir:
    mov word [dir], '/'             ; "/" + 0
.copy_name:
    mov si, bx
    mov di, startf
    call str_copy
    jmp .scan
.only_name:
    mov si, argbuf
    mov di, startf
    call str_copy
    ; каталог = текущий
.nodirarg:
    cmp byte [dir], 0
    jne .scan
    mov di, dir
    FAPI FAPI_GETCWD
.scan:
    call scan_dir
    cmp word [count], 0
    jne .have
    ; пусто — попробовать корень
    cmp word [dir], '/'
    je .have
    mov word [dir], '/'
    call scan_dir
.have:
    mov word [sel], 0
    mov word [top], 0
    mov byte [autoplay], 1
    mov word [playing], -1
    call clear_stat
    ; стартовый файл -> выбрать и играть
    cmp byte [startf], 0
    je .ui
    call find_start
    jc .ui
    mov [sel], ax
    call draw_all
    call play_sel
.ui:
main_loop:
    call draw_all
.wait:
    FAPI FAPI_KEYHIT
    jnz .key
    call mouse_poll
    jc main_loop
    hlt
    jmp .wait
.key:
    FAPI FAPI_GETKEY
    cmp al, 27
    je quit
    cmp al, 13
    je .play
    cmp al, ' '
    je .play
    cmp al, 'r'
    je .rescan
    cmp al, 'R'
    je .rescan
    cmp al, 'a'
    je .auto
    cmp al, 'A'
    je .auto
    cmp al, 'n'
    je .next
    cmp al, 'N'
    je .next
    cmp al, 'p'
    je .prev
    cmp al, 'P'
    je .prev
    test al, al
    jz .ext
    cmp al, 0xE0
    jne main_loop
.ext:
    cmp ah, 0x48
    je .up
    cmp ah, 0x50
    je .down
    cmp ah, 0x47
    je .home
    cmp ah, 0x4F
    je .end
    cmp ah, 0x49
    je .pgup
    cmp ah, 0x51
    je .pgdn
    jmp main_loop
.up:
    cmp word [sel], 0
    je main_loop
    dec word [sel]
    jmp main_loop
.down:
    mov ax, [sel]
    inc ax
    cmp ax, [count]
    jae main_loop
    mov [sel], ax
    jmp main_loop
.home:
    mov word [sel], 0
    jmp main_loop
.end:
    mov ax, [count]
    test ax, ax
    jz main_loop
    dec ax
    mov [sel], ax
    jmp main_loop
.pgup:
    sub word [sel], ROWS_L
    jns main_loop
    mov word [sel], 0
    jmp main_loop
.pgdn:
    mov ax, [sel]
    add ax, ROWS_L
    cmp ax, [count]
    jb .pg_ok
    mov ax, [count]
    dec ax
    js main_loop
.pg_ok:
    mov [sel], ax
    jmp main_loop
.rescan:
    call scan_dir
    mov word [sel], 0
    mov word [top], 0
    jmp main_loop
.auto:
    xor byte [autoplay], 1
    jmp main_loop
.next:
    call next_track
    jc main_loop
    call draw_all
    call play_sel
    jmp main_loop
.prev:
    cmp word [sel], 0
    je main_loop
    dec word [sel]
    call draw_all
    call play_sel
    jmp main_loop
.play:
    call play_sel
    jmp main_loop

quit:
    FAPI FAPI_UIREDRAW
    FAPI_QUIT

; выбрать следующий трек; CF=1 если это был последний
next_track:
    mov ax, [sel]
    inc ax
    cmp ax, [count]
    jae .last
    mov [sel], ax
    clc
    ret
.last:
    stc
    ret

;---------------------------------------------------------------- воспроизведение
; играть [sel]; при автопереходе — цепочкой, пока трек доигрывает до конца
play_sel:
    cmp word [count], 0
    je .r
.again:
    mov ax, [sel]
    mov [playing], ax
    call draw_all
    call sel_rec
    cmp byte [bx + F_CHAN], 0xFF
    je .sng
    ; команда "play DIR/NAME"
    mov di, cmdbuf
    mov si, s_play
    call str_copy
    call sel_path                   ; -> путь в DI (дописывает)
    jmp .go
.sng:
    ; .SNG: программу из программы ядро не запускает -> FAPI_EXEC "synth DIR/NAME -p":
    ; ferramp выходит, synth играет песню, затем ferramp перезапускается с тем же каталогом
    ; (аргумент "DIR/" — каталог без стартового файла, чтобы песня не играла по кругу)
    mov di, cmdbuf
    mov si, s_synth
    call str_copy
    call sel_path
    mov si, s_autop
    call str_copy
    mov di, 0x80
    mov si, dir
    call str_copy
    cmp word [dir], '/'
    je .sng_x
    mov al, '/'
    stosb
    mov byte [di], 0
.sng_x:
    mov si, cmdbuf
    xor dl, dl
    FAPI FAPI_EXEC
    jmp quit
.go:
    ; очистить строку состояния и поставить туда курсор ядра
    call clear_stat
    mov dh, STAT_Y
    mov dl, 2
    FAPI FAPI_SETCUR
    FAPI FAPI_TICKS
    mov [t0], ax
    mov si, cmdbuf
    FAPI FAPI_SHELL
    ; доиграл до конца? (прошло >= длительности - 1 с и клавиша не нажималась)
    FAPI FAPI_TICKS
    sub ax, [t0]                    ; тиков
    push ax
    call sel_rec                    ; BX -> запись
    pop ax
    mov cx, [bx + F_SEC]
    push ax
    mov ax, 18
    mul cx                          ; AX = длительность в тиках
    sub ax, 9                       ; допуск полсекунды
    jns .dur_ok
    xor ax, ax
.dur_ok:
    mov cx, ax
    pop ax
    cmp ax, cx
    jb .stopped
    cmp byte [autoplay], 0
    je .stopped
    call next_track
    jnc .again
.stopped:
    mov word [playing], -1
.r: ret

; очистить строки вывода ядра (STAT_Y, STAT_Y+1)
clear_stat:
    mov dh, STAT_Y
    xor dl, dl
    mov ch, 2
    mov cl, 80
    mov al, ' '
    mov bl, A_STAT
    FAPI FAPI_FILLRECT
    ret

; путь выбранного файла -> ES:DI (ASCIIZ, DI после)
sel_path:
    push si
    mov si, dir
    call str_copy
    cmp word [dir], '/'             ; корень "/" — без второго слэша
    je .nm
    mov al, '/'
    stosb
.nm:
    call sel_rec
    lea si, [bx + F_NAME]
    call str_copy
    pop si
    ret

; BX -> запись выбранного
sel_rec:
    mov ax, [sel]
    mov bx, F_SIZE_R
    mul bx
    add ax, files
    mov bx, ax
    ret

;---------------------------------------------------------------- список
; прочитать каталог [dir], оставить .WAV, заполнить files/count
scan_dir:
    push es
    push ds
    pop es
    mov si, dir
    mov di, dirbuf
    mov cx, 224
    FAPI FAPI_READDIR
    jnc .ok
    xor ax, ax
.ok:
    mov cx, ax
    mov word [count], 0
    mov si, dirbuf
    mov di, files
.e:
    jcxz .done
    push cx
    test byte [si + 11], 0x18       ; каталог/метка — мимо
    jnz .skip
    cmp word [si + 8], 'WA'
    jne .sng
    cmp byte [si + 10], 'V'
    je .take
.sng:
    cmp word [si + 8], 'SN'         ; .SNG — песня синтезатора (играет synth -p)
    jne .skip
    cmp byte [si + 10], 'G'
    jne .skip
.take:
    cmp word [count], MAXF
    jae .skip
    ; имя 8.3 -> ASCIIZ
    push si
    push di
    mov cx, 8
.n8:
    lodsb
    cmp al, ' '
    je .n8e
    stosb
.n8e:
    loop .n8
    mov al, '.'
    stosb
    mov cx, 3
.n3:
    lodsb
    cmp al, ' '
    je .n3e
    stosb
.n3e:
    loop .n3
    xor al, al
    stosb
    pop di
    pop si
    mov ax, [si + 28]
    mov [di + F_SIZE], ax
    mov ax, [si + 30]
    mov [di + F_SIZE + 2], ax
    mov word [di + F_SEC], 0
    mov word [di + F_RATE], 0
    mov byte [di + F_CHAN], 0
    mov byte [di + F_BITS], 0
    inc word [count]
    add di, F_SIZE_R
.skip:
    pop cx
    add si, 32
    dec cx
    jmp .e
.done:
    pop es
    ; длительности: прочитать заголовок каждого файла
    xor cx, cx
.dur:
    cmp cx, [count]
    jae .dd
    push cx
    mov [sel_tmp], cx
    mov ax, cx
    mov bx, F_SIZE_R
    mul bx
    add ax, files
    mov bx, ax
    call wav_info
    pop cx
    inc cx
    jmp .dur
.dd:
    ret

; BX -> запись: прочитать 512 байт файла, заполнить частоту/каналы/биты/секунды
wav_info:
    push bx
    mov di, cmdbuf
    mov si, dir
    call str_copy
    cmp word [dir], '/'
    je .nm
    mov al, '/'
    stosb
.nm:
    lea si, [bx + F_NAME]
    call str_copy
    push ds
    pop es
    mov si, cmdbuf
    mov di, hdr
    xor bx, bx
    mov cx, 512
    FAPI FAPI_READAT
    pop bx
    jc .r
    cmp word [hdr], 'FS'
    jne .notsng
    cmp word [hdr + 2], 'NG'
    jne .notsng
    ; песня: F_CHAN = 0xFF (признак), длительность = время последнего события / 24000
    mov byte [bx + F_CHAN], 0xFF
    mov cx, [hdr + 4]               ; число событий
    test cx, cx
    jz .sr
    cmp cx, 2000
    ja .sr
    dec cx
    shl cx, 3
    add cx, 8                       ; смещение последнего события
    push cx
    shr cx, 9                       ; сектор
    push bx
    mov bx, cx
    mov si, cmdbuf
    mov di, hdr
    mov cx, 512
    push ds
    pop es
    FAPI FAPI_READAT
    pop bx
    pop si
    jc .sr
    and si, 511
    mov ax, [hdr + si]
    mov dx, [hdr + si + 2]
    mov cx, 24000
    cmp dx, cx
    jae .sr
    div cx
    inc ax                          ; + хвост затухания
    mov [bx + F_SEC], ax
.sr: ret
.notsng:
    cmp ax, 44
    jb .r
    cmp word [hdr], 'RI'
    jne .r
    ; найти chunk "fmt "
    mov si, hdr + 12
.ch:
    cmp si, hdr + 480
    ja .r
    cmp word [si], 'fm'
    jne .nx
    cmp word [si + 2], 't '
    je .fmt
.nx:
    mov ax, [si + 4]
    add si, 8
    add si, ax
    jmp .ch
.fmt:
    mov ax, [si + 10]               ; каналы
    mov [bx + F_CHAN], al
    mov ax, [si + 12]               ; частота
    mov [bx + F_RATE], ax
    mov ax, [si + 22]               ; бит
    mov [bx + F_BITS], al
    ; байт/с = rate * chan * bits/8
    mov ax, [si + 16]               ; byte rate из заголовка
    test ax, ax
    jz .r
    mov cx, ax
    ; секунды = размер файла / byterate (размер данных ~ размер файла)
    mov dx, [bx + F_SIZE + 2]
    mov ax, [bx + F_SIZE]
    cmp dx, cx
    jae .r                          ; слишком длинный — не считаем
    div cx
    mov [bx + F_SEC], ax
.r: ret

; найти [startf] в списке -> AX индекс; CF=1 нет
find_start:
    xor cx, cx
.l:
    cmp cx, [count]
    jae .no
    mov ax, cx
    mov bx, F_SIZE_R
    mul bx
    add ax, files
    mov si, ax
    mov di, startf
    call str_ieq
    jc .yes
    inc cx
    jmp .l
.yes:
    mov ax, cx
    clc
    ret
.no:
    stc
    ret

; DS:SI == DS:DI без учёта регистра -> CF=1 равны
str_ieq:
    push si
    push di
.l:
    lodsb
    mov ah, [di]
    inc di
    call upc
    xchg al, ah
    call upc
    cmp al, ah
    jne .ne
    test al, al
    jnz .l
    pop di
    pop si
    stc
    ret
.ne:
    pop di
    pop si
    clc
    ret
upc:
    cmp al, 'a'
    jb .r
    cmp al, 'z'
    ja .r
    sub al, 0x20
.r: ret

;---------------------------------------------------------------- рисование
draw_all:
    ; подогнать окно прокрутки
    mov ax, [sel]
    cmp ax, [top]
    jae .t1
    mov [top], ax
.t1:
    mov ax, [sel]
    sub ax, ROWS_L - 1
    cmp ax, [top]
    jle .t2
    mov [top], ax
.t2:
    ; фон (строки STAT_Y..STAT_Y+1 — вывод ядра, не трогаем)
    xor dx, dx
    mov ch, STAT_Y
    mov cl, 80
    mov al, ' '
    mov bl, A_TEXT
    FAPI FAPI_FILLRECT
    mov dh, STAT_Y + 2
    mov ch, 25 - STAT_Y - 2
    FAPI FAPI_FILLRECT
    ; рамка
    xor dx, dx
    mov ch, 1
    mov cl, 80
    mov al, 0xCD
    mov bl, A_FRAME
    FAPI FAPI_FILLRECT
    mov dh, 24
    FAPI FAPI_FILLRECT
    mov dh, LIST_Y - 1
    FAPI FAPI_FILLRECT
    mov dh, STAT_Y - 1
    FAPI FAPI_FILLRECT
    FAPI_PUTSAT 0, 2, s_title, A_TITLE
    ; текущий трек
    FAPI_PUTSAT 1, 2, s_now, A_DIM
    cmp word [playing], -1
    je .nonow
    mov ax, [playing]
    call rec_of
    push bx
    lea si, [bx + F_NAME]
    FAPI_PUTSAT 1, 12, si, A_TITLE
    pop bx
    call draw_info                  ; строка 2: частота/каналы/биты/длительность
    jmp .list_hdr
.nonow:
    FAPI_PUTSAT 1, 12, s_none, A_TEXT
    FAPI_PUTSAT 2, 2, s_hint, A_DIM
.list_hdr:
    ; каталог и счётчик
    FAPI_PUTSAT 3, 2, s_dir, A_DIM
    FAPI_PUTSAT 3, 12, dir, A_TEXT
    FAPI_PUTSAT 4, 2, s_tracks, A_DIM
    mov byte [row_attr], A_TEXT
    mov ax, [count]
    mov dh, 4
    mov dl, 12
    call put_num
    FAPI_PUTSAT 4, 40, s_auto, A_DIM
    mov si, s_on
    cmp byte [autoplay], 0
    jne .ao
    mov si, s_off
.ao:
    FAPI_PUTSAT 4, 51, si, A_TEXT
    ; список
    xor cx, cx
.row:
    cmp cx, ROWS_L
    jae .help
    mov ax, [top]
    add ax, cx
    cmp ax, [count]
    jae .help
    push cx
    push ax
    call rec_of                     ; BX
    pop ax
    mov bl, A_TEXT
    cmp ax, [sel]
    jne .na
    mov bl, A_SEL
.na:
    mov [row_attr], bl
    pop cx
    push cx
    mov dh, LIST_Y
    add dh, cl
    ; полоса выделения
    push ax
    mov dl, 1
    mov ch, 1
    mov cl, 78
    mov al, ' '
    mov bl, [row_attr]
    FAPI FAPI_FILLRECT
    pop ax
    ; маркер играющего
    push ax
    mov si, s_sp
    cmp ax, [playing]
    jne .m
    mov si, s_playmark
.m:
    mov dl, 2
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop ax
    push dx
    call rec_of
    pop dx
    lea si, [bx + F_NAME]
    mov dl, 4
    push bx
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop bx
    ; размер
    push bx
    mov ax, [bx + F_SIZE]
    mov bx, [bx + F_SIZE + 2]
    mov dl, 20
    call put_num32
    pop bx
    ; длительность m:ss
    mov ax, [bx + F_SEC]
    mov dl, 34
    call put_time_at
    ; частота (или пометка SNG)
    cmp byte [bx + F_CHAN], 0xFF
    jne .ishz
    mov si, s_sngrow
    mov dl, 42
    push bx
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop bx
    jmp .nr
.ishz:
    mov ax, [bx + F_RATE]
    test ax, ax
    jz .nr
    mov dl, 42
    call put_num
    mov dl, 48
    mov si, s_hz
    push bx
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop bx
    mov si, s_mono
    cmp byte [bx + F_CHAN], 1
    je .ch
    mov si, s_stereo
.ch:
    mov dl, 52
    push bx
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop bx
.nr:
    pop cx
    inc cx
    jmp .row
.help:
    FAPI_PUTSAT 24, 2, s_help, A_FRAME
    ret

; AX индекс -> BX запись
rec_of:
    push dx
    mov bx, F_SIZE_R
    mul bx
    add ax, files
    mov bx, ax
    pop dx
    ret

; строка 2: параметры играющего трека (BX)
draw_info:
    push bx
    mov byte [row_attr], A_TEXT
    mov dh, 2
    mov dl, 2
    cmp byte [bx + F_CHAN], 0xFF
    jne .wav
    mov si, s_sng
    call puts_cur
    add dl, 40
    mov ax, [bx + F_SEC]
    call put_time_at
    pop bx
    ret
.wav:
    mov ax, [bx + F_RATE]
    call put_num
    inc dl
    mov si, s_hz
    call puts_cur
    add dl, 3
    mov si, s_mono
    cmp byte [bx + F_CHAN], 1
    je .c
    mov si, s_stereo
.c:
    call puts_cur
    add dl, 8
    mov al, [bx + F_BITS]
    xor ah, ah
    call put_num
    inc dl
    mov si, s_bit
    call puts_cur
    add dl, 5
    mov ax, [bx + F_SEC]
    call put_time_at
    pop bx
    ret

; DS:SI в позицию DH,DL атрибутом [row_attr] (регистры сохраняются)
puts_cur:
    push ax
    push bx
    push dx
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop dx
    pop bx
    pop ax
    ret

; AX секунд -> "m:ss" в DH,DL
put_time_at:
    push ax
    push bx
    push cx
    push dx
    xor dx, dx
    mov cx, 60
    div cx                          ; AX мин, DX сек
    mov cx, dx
    pop dx
    call put_num                    ; минуты, DL сдвинут
    mov al, ':'
    push bx
    mov bl, [row_attr]
    FAPI FAPI_PUTAT
    pop bx
    inc dl
    mov ax, cx
    cmp ax, 10
    jae .two
    mov al, '0'
    push bx
    mov bl, [row_attr]
    FAPI FAPI_PUTAT
    pop bx
    inc dl
    mov ax, cx
.two:
    call put_num
    pop cx
    pop bx
    pop ax
    ret

; AX -> десятичная строка в позиции DH,DL (атрибут [row_attr]); DL += длина
put_num:
    push ax
    push bx
    push cx
    xor bx, bx
    call itoa32
    jmp put_num_out
; BX:AX (32 бита) -> десятичная строка
put_num32:
    push ax
    push bx
    push cx
    call itoa32
put_num_out:
    mov si, numbuf
    push dx
    mov bl, [row_attr]
    FAPI FAPI_PUTSAT
    pop dx
    call num_len
    add dl, al
    pop cx
    pop bx
    pop ax
    ret

; BX:AX -> numbuf ASCIIZ
itoa32:
    push ax
    push bx
    push cx
    push dx
    push di
    mov di, numbuf + 11
    mov byte [di], 0
    mov cx, 10
.l:
    ; (BX:AX) / 10
    push ax
    mov ax, bx
    xor dx, dx
    div cx                          ; AX = старшее частное, DX = остаток
    mov bx, ax
    pop ax
    div cx                          ; AX = младшее частное, DX = цифра
    add dl, '0'
    dec di
    mov [di], dl
    mov dx, ax
    or dx, bx
    jnz .l
    ; сдвинуть в начало numbuf
    mov si, di
    mov di, numbuf
.c:
    lodsb
    stosb
    test al, al
    jnz .c
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; длина строки numbuf -> AL
num_len:
    push si
    mov si, numbuf
    xor al, al
.l:
    cmp byte [si], 0
    je .d
    inc si
    inc al
    jmp .l
.d:
    pop si
    ret

;---------------------------------------------------------------- мышь
; CF=1 — было действие
mouse_poll:
    FAPI FAPI_MOUSE
    test ah, ah
    jz .no
    test al, 1
    jz .rel
    cmp byte [m_down], 0
    jne .no
    mov byte [m_down], 1
    ; клик: строка списка?
    cmp dx, LIST_Y
    jb .no
    cmp dx, LIST_Y + ROWS_L
    jae .no
    sub dx, LIST_Y
    add dx, [top]
    cmp dx, [count]
    jae .no
    mov [sel], dx
    call draw_all
    call play_sel
    stc
    ret
.rel:
    mov byte [m_down], 0
.no:
    clc
    ret

;---------------------------------------------------------------- утилиты
skip_sp:
    cmp byte [si], ' '
    jne .r
    inc si
    jmp skip_sp
.r: ret

; DS:SI -> ES:DI ASCIIZ (DI после текста, на нуле)
str_copy:
    lodsb
    stosb
    test al, al
    jnz str_copy
    dec di
    ret

;---------------------------------------------------------------- данные
s_title     db " FERRAMP  WAV/SNG player ", 0
s_now       db "Playing: ", 0
s_none      db "-", 0
s_hint      db "Enter - play selected track", 0
s_dir       db "Folder:  ", 0
s_tracks    db "Tracks:  ", 0
s_auto      db "Autoplay: ", 0
s_on        db "ON ", 0
s_off       db "OFF", 0
s_help      db " Enter/Space play  N next  P prev  A autoplay  R rescan  any key stops  Esc exit ", 0
s_playmark  db 16, 0
s_sp        db " ", 0
s_hz        db "Hz", 0
s_sng       db "synth song (SNG), 24000 Hz 16 bit mono", 0
s_sngrow    db "SNG  synth", 0
s_mono      db "mono", 0
s_stereo    db "stereo", 0
s_bit       db "bit", 0
s_play      db "play ", 0
s_synth     db "synth ", 0
s_autop     db " -p", 0

sel         dw 0
top         dw 0
count       dw 0
playing     dw -1
autoplay    db 1
m_down      db 0
row_attr    db A_TEXT
t0          dw 0
sel_tmp     dw 0
numbuf      times 12 db 0
dir         times 82 db 0
startf      times 14 db 0
argbuf      times 128 db 0
cmdbuf      times 128 db 0
hdr         times 512 db 0
files       times MAXF * F_SIZE_R db 0
dirbuf:
