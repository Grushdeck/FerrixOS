;======================================
; File name: apps/matrix.asm
; Project: FERRIX-OS
; Author: Copyright (c) 2026 Grushdeck
; Description: matrix — «цифровой дождь» волнами (MATRIX.FAP); любая клавиша — выход
;======================================
; Тот же эффект, что и заставка ядра (saver matrix), но отдельной программой.
%include "fapi.inc"
    FAPI_HEADER
start:
    mov ax, [0x0010]                ; сегмент видеопамяти (под GUI — окно)
    mov es, ax
    FAPI FAPI_CLS
    FAPI FAPI_TICKS
    mov [mx_seed], ax
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
    FAPI FAPI_CLS
    FAPI_QUIT

; LCG -> AX
mx_rand:
    push bx
    push dx
    mov ax, [mx_seed]
    mov bx, 25173
    mul bx
    add ax, 13849
    mov [mx_seed], ax
    pop dx
    pop bx
    ret

mx_sine: db 0,1,3,4,5,7,8,9,10,11,12,12,13,13,14,14,14,14,14,13,13,12,12,11,10,9,8,7,5,4,3,1,0,-1,-3,-4,-5,-7,-8,-9,-10,-11,-12,-12,-13,-13,-14,-14,-14,-14,-14,-13,-13,-12,-12,-11,-10,-9,-8,-7,-5,-4,-3,-1
mx_h:    times 80 db 0
mx_t1:   dw 0
mx_t2:   dw 0
mx_t3:   dw 0
mx_seed: dw 0x1234
