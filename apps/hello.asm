;======================================
; File name: apps/hello.asm
; Project: FERRIX-OS
; Description: минимальный пример программы .FAP
;======================================
; Запуск: hello [ТЕКСТ]  — печатает приветствие, аргументы, текущий каталог
; и ждёт клавишу. Сборка: nasm -f bin -I. apps/hello.asm -o HELLO.FAP

%include "fapi.inc"

    FAPI_HEADER

start:
    FAPI_PRINT msg_hello
    cmp byte [si], 0                ; DS:SI = аргументы
    je .no_args
    FAPI_PRINT msg_args
    mov si, 0x80
    FAPI FAPI_PUTS
    FAPI_PRINT crlf
.no_args:
    FAPI_PRINT msg_cwd
    mov di, buf
    FAPI FAPI_GETCWD
    mov si, buf
    FAPI FAPI_PUTS
    FAPI_PRINT crlf
    FAPI_PRINT msg_key
    FAPI FAPI_GETKEY
    push ax
    FAPI_PRINT msg_code
    pop ax
    mov dl, al                      ; DX = код клавиши
    xor dh, dh
    FAPI FAPI_PRINTDEC
    FAPI_PRINT crlf
    FAPI_QUIT

msg_hello   db "Hello from a FAPI program!", 13,10, 0
msg_args    db "Args: ", 0
msg_cwd     db "Cwd:  ", 0
msg_key     db "Press any key... ", 0
msg_code    db "code ", 0
crlf        db 13,10, 0
buf         times 80 db 0
