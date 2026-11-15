;======================================
; File name: fapi.inc
; Project: FERRIX-OS
; Description: Ferrix App Image (.FAP) — заголовок и системные вызовы
;======================================
; Программа — плоский 16-битный образ (tiny-модель, как .COM):
;   CS = DS = ES = SS = сегмент программы, стек растёт от FFFEh.
;   0000h  dw  версия API ядра            0080h  ASCIIZ аргументы (DS:SI при входе)
;   0100h  заголовок FAPI (16 байт), сразу за ним код.
; Выход: FAPI_EXIT (int 80h / AH=0) или retf.
; Сборка:  nasm -f bin -I. apps/prog.asm -o PROG.FAP

%ifndef FAPI_INC
%define FAPI_INC

API_INT         equ 0x80

FAPI_EXIT       equ 0x00    ; завершить программу
FAPI_PUTC       equ 0x01    ; AL = символ
FAPI_PUTS       equ 0x02    ; DS:SI = ASCIIZ
FAPI_GETKEY     equ 0x03    ; -> AX (AL = ASCII, 0/E0 = расширенная; AH = скан-код)
FAPI_KEYHIT     equ 0x04    ; -> AX (0 = нет клавиши), ZF=1 если нет
FAPI_SETCUR     equ 0x05    ; DH = строка, DL = столбец
FAPI_GETCUR     equ 0x06    ; -> DH, DL
FAPI_CLS        equ 0x07    ; очистить экран
FAPI_READFILE   equ 0x08    ; DS:SI путь, ES:DI буфер, CX макс -> AX длина; CF=1: AX=1 нет, 2 велик, 3 диск
FAPI_WRITEFILE  equ 0x09    ; DS:SI путь, ES:DI данные, CX длина -> CF=1 ошибка
FAPI_TICKS      equ 0x0A    ; -> DX:AX тики таймера (18.2 Гц)
FAPI_PRINTDEC   equ 0x0B    ; DX = число (AH занят номером функции)
FAPI_GETCWD     equ 0x0C    ; ES:DI <- ASCIIZ текущий каталог ("/" для корня)
FAPI_SLEEP      equ 0x0D    ; CX = тиков
FAPI_UIREDRAW   equ 0x0E    ; очистить экран и нарисовать баннер оболочки
FAPI_RAND       equ 0x0F    ; -> AX случайное 0..65535
FAPI_CURSOR     equ 0x10    ; CX = 2000h спрятать, 0607h показать
FAPI_LOCALTIME  equ 0x11    ; -> CH час, CL мин, DH сек, DL день месяца
FAPI_USERNAME   equ 0x12    ; ES:DI <- ASCIIZ имя пользователя
FAPI_BEEP       equ 0x13    ; короткий сигнал PC-спикером
FAPI_KBFLUSH    equ 0x14    ; очистить буфер клавиатуры
FAPI_PUTAT      equ 0x15    ; DH строка, DL столбец, AL символ, BL атрибут
FAPI_FILLRECT   equ 0x16    ; DH,DL угол; CH высота, CL ширина; AL символ, BL атрибут
FAPI_PUTSAT     equ 0x17    ; DH,DL позиция, DS:SI ASCIIZ, BL атрибут
; --- API версии 3 ---
FAPI_READDIR    equ 0x18    ; DS:SI путь ("" = текущий), ES:DI буфер, CX макс записей -> AX записей (32 байта FAT)
FAPI_SHELL      equ 0x19    ; DS:SI строка команды оболочки (mkdir/rm/cp/mv/rename/...); вывод с позиции курсора
FAPI_EXEC       equ 0x1A    ; DS:SI команда (DL=1: потом ждать клавишу): выполнится после выхода, затем программа перезапустится
FAPI_STAT       equ 0x1B    ; DS:SI путь -> DX:AX размер, CL атрибут; CF=1 нет
FAPI_READAT     equ 0x1C    ; DS:SI путь, ES:DI буфер, BX сектор файла (512 байт), CX макс -> AX прочитано (0 = конец)
FAPI_APPEND     equ 0x1D    ; DS:SI путь, ES:DI данные, CX длина -> дописать (создаёт файл); CF=1 ошибка
FAPI_MOUSE      equ 0x1E    ; -> CX столбец, DX строка, AL кнопки (bit0 левая, bit1 правая), AH=1 мышь есть
FAPI_MOUSESHOW  equ 0x1F    ; CL = 1 показать курсор мыши / 0 спрятать
FAPI_CHDIR      equ 0x20    ; DS:SI путь -> сменить текущий каталог; CF=1 ошибка
FAPI_WM         equ 0x21    ; оконный менеджер (GUI.FAP): AL=0 установить обработчик (DX смещение, CL строк экрана),
                            ;   AL=1 снять, AL=2 загрузить программу (DS:SI путь, DX сегмент, CX видеосегмент, ES:DI аргументы) -> AX вход,
                            ;   AL=3 сегмент консольного вывода ядра (CX, 0 = B800h) -> AX прежний
FAPI_AUDIO      equ 0x22    ; PCM-поток через HDA: AL=0 открыть (ES:DI буфер 2 половины, CX размер половины, BX формат SDFMT),
                            ;   AL=1 опрос -> AL играющая половина, DX позиция в ней; AL=2 закрыть. CF=1 нет HDA
FAPI_DATE       equ 0x23    ; -> CX год, DH месяц, DL день, AL день недели (0 = воскресенье)
; Слово по адресу 0010h сегмента программы — сегмент видеопамяти (B800h, под GUI — виртуальный экран окна):
; программы, пишущие в видеопамять напрямую, должны брать сегмент оттуда.

; Заголовок: ставится первой строкой программы, затем идёт код.
%macro FAPI_HEADER 0
    [bits 16]
    [org 0x0100]
    db "FAPI"               ; сигнатура
    db 1                    ; версия формата
    db 0                    ; флаги
    dw %%entry              ; точка входа
    times 8 db 0            ; резерв
%%entry:
%endmacro

; Удобные обёртки
%macro FAPI 1
    mov ah, %1
    int API_INT
%endmacro

%macro FAPI_PRINT 1         ; FAPI_PRINT метка_строки
    mov si, %1
    mov ah, FAPI_PUTS
    int API_INT
%endmacro

%macro FAPI_PUTSAT 4        ; строка, столбец, метка, атрибут
    mov dh, %1
    mov dl, %2
    mov si, %3
    mov bl, %4
    mov ah, FAPI_PUTSAT
    int API_INT
%endmacro

%macro FAPI_QUIT 0
    mov ah, FAPI_EXIT
    int API_INT
%endmacro

%endif
