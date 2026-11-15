; TEST.ASM - frasm demo for iron
; iron /TEST.ASM /T.FAP
    bits 16
    org 0x100
API_INT   equ 0x80
F_PUTS    equ 2
F_GETKEY  equ 3
F_PRINTDEC equ 0Bh

    db "FAPI", 1, 0
    dw start
    times 8 db 0

start:
    mov si, msg
    call puts
    ; sum 1..10 in loop
    xor ax, ax
    mov cx, 10
.lp:
    add ax, cx
    loop .lp
    mov dx, ax
    mov ah, F_PRINTDEC
    int API_INT
    mov si, crlf
    call puts
    ; table walk with [bx+si+2]
    mov bx, table
    xor si, si
.tw:
    mov al, [bx+si+2]
    test al, al
    jz .done
    mov ah, 1
    int API_INT              ; putchar
    inc si
    jmp short .tw
.done:
    mov si, crlf
    call puts
    mov ah, F_GETKEY
    int API_INT
    mov ah, 0
    int 0x80

puts:
    mov ah, F_PUTS
    int API_INT
    ret

msg     db "Hello from frasm! sum(1..10)=", 0
crlf    db 13, 10, 0
table   db 0, 0, 'I', 'R', 'O', 'N', 0
pad     times 4 dw 0xABCD
end_mark db $ - start
