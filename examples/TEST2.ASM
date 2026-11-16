; second test: more instructions
    org 0x100
    db "FAPI",1,0
    dw main
    times 8 db 0
main:
    push ds
    pop es
    mov ax, 0x1234
    mov [val], ax
    mov bl, [val+1]
    add byte [val], 5
    sub word [bx+si], 0x10
    cmp al, 'A'
    jne .skip
    inc word [val]
.skip:
    xor cx, cx
    shl ax, 1
    shr bl, cl
    rol dx, 1
    mul bx
    div cl
    lea si, [val]
    mov es, ax
    mov ax, cs
    rep movsb
    lodsb
    stosw
    int 0x80
    jmp far_lbl
    call near .skip
    jcxz .skip
    in al, 0x60
    out dx, al
    test al, 0x80
    not ax
    neg byte [val]
    xchg ax, bx
    xchg bx, ax
    push 5
    ret
far_lbl:
    retf
    iret
    cbw
    cwd
    hlt
val dw 0
    align 4
    resb 3
buf times 5 db 'x'
