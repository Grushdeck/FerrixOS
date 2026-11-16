#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#======================================
# File name: tools/fpy.py
# Project: FERRIX-OS
# Author: Copyright (c) 2026 Grushdeck
# Description: ferpy — компилятор Python-подобного языка в frasm (ассемблер iron / nasm -f bin)
#======================================
# Использование:  python3 tools/fpy.py prog.fpy [-o PROG.ASM] [--nasm]
# Результат — исходник на frasm с заголовком .FAP; собирается командой
#   iron /PROG.ASM /PROG.FAP          (в Ferrix)
#   nasm -f bin PROG.ASM -o PROG.FAP  (на хосте)
# Описание языка: docs/FERPY.md
import sys, re, os

VERSION = "1.0"

# ----------------------------------------------------------------- ошибки
class CompileError(Exception):
    def __init__(self, line, msg):
        super().__init__(msg)
        self.line = line
        self.msg = msg

# ----------------------------------------------------------------- лексер
KEYWORDS = {"def", "if", "elif", "else", "while", "for", "in", "range", "break", "continue",
            "return", "pass", "global", "and", "or", "not", "True", "False", "None"}
OPERATORS = ["<<=", ">>=", "//=", "**", "<<", ">>", "//", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=",
             "%=", "&=", "|=", "^=", "->", "+", "-", "*", "/", "%", "&", "|", "^", "~", "<", ">", "=",
             "(", ")", "[", "]", ",", ":", "."]

class Tok:
    __slots__ = ("kind", "val", "line")
    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line
    def __repr__(self):
        return "%s(%r)@%d" % (self.kind, self.val, self.line)

def unescape(s, line):
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 1
            if i >= len(s):
                raise CompileError(line, "незавершённая escape-последовательность")
            e = s[i]
            m = {"n": 10, "r": 13, "t": 9, "0": 0, "\\": 92, "'": 39, '"': 34, "a": 7, "b": 8, "e": 27}
            if e in m:
                out.append(m[e])
            elif e == "x":
                h = s[i + 1:i + 3]
                if not re.fullmatch(r"[0-9a-fA-F]{2}", h):
                    raise CompileError(line, "ожидается \\xHH")
                out.append(int(h, 16))
                i += 2
            else:
                raise CompileError(line, "неизвестная escape-последовательность \\%s" % e)
        else:
            try:
                out += c.encode("cp437")
            except UnicodeEncodeError:
                raise CompileError(line, "символ %r нельзя показать стандартным шрифтом VGA (cp437); "
                                         "используйте латиницу или \\xHH" % c)
        i += 1
    return bytes(out)

def tokenize(src):
    toks = []
    indent = [0]
    depth = 0
    lines = src.split("\n")
    for ln, raw in enumerate(lines, 1):
        line = raw.rstrip("\r")
        # отступ
        if depth == 0:
            stripped = line.lstrip(" \t")
            if stripped == "" or stripped.startswith("#"):
                continue
            ind = 0
            for ch in line[:len(line) - len(stripped)]:
                ind = ind + 1 if ch == " " else (ind // 8 + 1) * 8
            if ind > indent[-1]:
                indent.append(ind)
                toks.append(Tok("INDENT", None, ln))
            else:
                while ind < indent[-1]:
                    indent.pop()
                    toks.append(Tok("DEDENT", None, ln))
                if ind != indent[-1]:
                    raise CompileError(ln, "несогласованный отступ")
        i = 0
        n = len(line)
        while i < n:
            c = line[i]
            if c in " \t":
                i += 1
                continue
            if c == "#":
                break
            if c.isdigit():
                m = re.match(r"0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*", line[i:])
                txt = m.group(0).replace("_", "")
                v = int(txt, 0) if txt[:2].lower() in ("0x", "0b") else int(txt)
                toks.append(Tok("NUM", v, ln))
                i += m.end()
                continue
            if c.isalpha() or c == "_":
                m = re.match(r"[A-Za-z_][A-Za-z_0-9]*", line[i:])
                w = m.group(0)
                toks.append(Tok("KW" if w in KEYWORDS else "NAME", w, ln))
                i += m.end()
                continue
            if c in "\"'":
                j = i + 1
                buf = ""
                while j < n and line[j] != c:
                    if line[j] == "\\":
                        buf += line[j:j + 2]
                        j += 2
                    else:
                        buf += line[j]
                        j += 1
                if j >= n:
                    raise CompileError(ln, "незакрытая строка")
                toks.append(Tok("STR", unescape(buf, ln), ln))
                i = j + 1
                continue
            for op in OPERATORS:
                if line.startswith(op, i):
                    toks.append(Tok("OP", op, ln))
                    if op in "([":
                        depth += 1
                    elif op in ")]":
                        depth = max(0, depth - 1)
                    i += len(op)
                    break
            else:
                raise CompileError(ln, "недопустимый символ %r" % c)
        if depth == 0:
            toks.append(Tok("NEWLINE", None, ln))
    while len(indent) > 1:
        indent.pop()
        toks.append(Tok("DEDENT", None, len(lines)))
    toks.append(Tok("EOF", None, len(lines)))
    return toks

# ----------------------------------------------------------------- AST
class Node:
    def __init__(self, kind, line, **kw):
        self.kind = kind
        self.line = line
        self.__dict__.update(kw)
    def __repr__(self):
        return "<%s %s>" % (self.kind, {k: v for k, v in self.__dict__.items() if k not in ("kind", "line")})

# ----------------------------------------------------------------- парсер
BINPREC = [  # от низкого приоритета к высокому
    ("or",), ("and",), ("not",),
    ("==", "!=", "<", "<=", ">", ">="),
    ("|",), ("^",), ("&",), ("<<", ">>"), ("+", "-"), ("*", "/", "//", "%"),
]

class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.p = 0

    def peek(self, k=0):
        return self.toks[self.p + k]

    def next(self):
        t = self.toks[self.p]
        self.p += 1
        return t

    def at(self, kind, val=None):
        t = self.peek()
        return t.kind == kind and (val is None or t.val == val)

    def accept(self, kind, val=None):
        if self.at(kind, val):
            return self.next()
        return None

    def expect(self, kind, val=None):
        t = self.peek()
        if not self.at(kind, val):
            want = val if val is not None else kind
            got = t.val if t.val is not None else t.kind
            raise CompileError(t.line, "ожидается %r, найдено %r" % (want, got))
        return self.next()

    def parse_program(self):
        body = []
        while not self.at("EOF"):
            body.append(self.parse_stmt())
        return body

    def parse_block(self):
        self.expect("OP", ":")
        if not self.at("NEWLINE"):
            # однострочный блок: if x: return
            st = self.parse_simple()
            self.expect("NEWLINE")
            return [st]
        self.expect("NEWLINE")
        self.expect("INDENT")
        body = []
        while not self.at("DEDENT"):
            body.append(self.parse_stmt())
        self.expect("DEDENT")
        return body

    def parse_stmt(self):
        t = self.peek()
        if t.kind == "KW":
            if t.val == "def":
                return self.parse_def()
            if t.val == "if":
                return self.parse_if()
            if t.val == "while":
                self.next()
                cond = self.parse_expr()
                body = self.parse_block()
                orelse = self.parse_block() if self.accept("KW", "else") else []
                return Node("while", t.line, cond=cond, body=body, orelse=orelse)
            if t.val == "for":
                return self.parse_for()
        st = self.parse_simple()
        self.expect("NEWLINE")
        return st

    def parse_def(self):
        t = self.expect("KW", "def")
        name = self.expect("NAME").val
        self.expect("OP", "(")
        params = []
        while not self.at("OP", ")"):
            pn = self.expect("NAME").val
            ptype = "int"
            if self.accept("OP", ":"):
                ptype = self.parse_type()
            params.append((pn, ptype))
            if not self.accept("OP", ","):
                break
        self.expect("OP", ")")
        rtype = "int"
        if self.accept("OP", "->"):
            rtype = self.parse_type()
        body = self.parse_block()
        return Node("def", t.line, name=name, params=params, rtype=rtype, body=body)

    def parse_type(self):
        t = self.next()
        if t.kind == "NAME" and t.val in ("int", "str", "bytes", "array", "bool"):
            return "int" if t.val == "bool" else t.val
        if t.kind == "KW" and t.val == "None":
            return "none"
        raise CompileError(t.line, "неизвестный тип %r" % t.val)

    def parse_if(self):
        t = self.next()  # if / elif
        cond = self.parse_expr()
        body = self.parse_block()
        orelse = []
        if self.at("KW", "elif"):
            orelse = [self.parse_if()]
        elif self.accept("KW", "else"):
            orelse = self.parse_block()
        return Node("if", t.line, cond=cond, body=body, orelse=orelse)

    def parse_for(self):
        t = self.expect("KW", "for")
        var = self.expect("NAME").val
        self.expect("KW", "in")
        self.expect("KW", "range")
        self.expect("OP", "(")
        args = [self.parse_expr()]
        while self.accept("OP", ","):
            args.append(self.parse_expr())
        self.expect("OP", ")")
        if len(args) > 3:
            raise CompileError(t.line, "range принимает 1..3 аргумента")
        body = self.parse_block()
        orelse = self.parse_block() if self.accept("KW", "else") else []
        return Node("for", t.line, var=var, args=args, body=body, orelse=orelse)

    def parse_simple(self):
        t = self.peek()
        if t.kind == "KW":
            if t.val == "pass":
                self.next()
                return Node("pass", t.line)
            if t.val in ("break", "continue"):
                self.next()
                return Node(t.val, t.line)
            if t.val == "return":
                self.next()
                val = None if self.at("NEWLINE") else self.parse_expr()
                return Node("return", t.line, value=val)
            if t.val == "global":
                self.next()
                names = [self.expect("NAME").val]
                while self.accept("OP", ","):
                    names.append(self.expect("NAME").val)
                return Node("global", t.line, names=names)
        e = self.parse_expr()
        if self.at("OP") and self.peek().val in ("=", "+=", "-=", "*=", "/=", "//=", "%=", "&=", "|=", "^=", "<<=", ">>="):
            op = self.next().val
            if e.kind not in ("name", "index"):
                raise CompileError(t.line, "слева от присваивания должна быть переменная или элемент")
            rhs = self.parse_expr()
            if op != "=":
                rhs = Node("bin", t.line, op=op[:-1], l=e, r=rhs)
            return Node("assign", t.line, target=e, value=rhs)
        return Node("expr", t.line, value=e)

    # выражения
    def parse_expr(self, level=0):
        if level >= len(BINPREC):
            return self.parse_unary()
        ops = BINPREC[level]
        if ops == ("not",):
            if self.accept("KW", "not"):
                line = self.peek().line
                return Node("not", line, e=self.parse_expr(level))
            return self.parse_expr(level + 1)
        left = self.parse_expr(level + 1)
        while True:
            t = self.peek()
            if (t.kind == "OP" or t.kind == "KW") and t.val in ops:
                self.next()
                right = self.parse_expr(level + 1)
                if t.val in ("and", "or"):
                    left = Node(t.val, t.line, l=left, r=right)
                else:
                    if t.val in ("==", "!=", "<", "<=", ">", ">=") and self.at("OP") and self.peek().val in BINPREC[3]:
                        raise CompileError(t.line, "цепочки сравнений (a < b < c) не поддерживаются")
                    left = Node("bin", t.line, op=t.val, l=left, r=right)
            else:
                return left

    def parse_unary(self):
        t = self.peek()
        if t.kind == "OP" and t.val in ("-", "~", "+"):
            self.next()
            e = self.parse_unary()
            if t.val == "+":
                return e
            if e.kind == "num":                      # свёртка -5, ~0 при разборе
                v = -e.v if t.val == "-" else ~e.v
                return Node("num", t.line, v=v)
            return Node("unary", t.line, op=t.val, e=e)
        return self.parse_postfix()

    def parse_postfix(self):
        e = self.parse_atom()
        while True:
            t = self.peek()
            if self.accept("OP", "("):
                args = []
                kwargs = {}
                while not self.at("OP", ")"):
                    if self.at("NAME") and self.peek(1).kind == "OP" and self.peek(1).val == "=":
                        k = self.next().val
                        self.next()
                        kwargs[k] = self.parse_expr()
                    else:
                        if kwargs:
                            raise CompileError(t.line, "позиционный аргумент после именованного")
                        args.append(self.parse_expr())
                    if not self.accept("OP", ","):
                        break
                self.expect("OP", ")")
                if e.kind != "name":
                    raise CompileError(t.line, "вызывать можно только функцию по имени")
                e = Node("call", t.line, name=e.name, args=args, kwargs=kwargs)
            elif self.accept("OP", "["):
                idx = self.parse_expr()
                self.expect("OP", "]")
                e = Node("index", t.line, base=e, idx=idx)
            else:
                return e

    def parse_atom(self):
        t = self.next()
        if t.kind == "NUM":
            return Node("num", t.line, v=t.val)
        if t.kind == "STR":
            return Node("str", t.line, v=t.val)
        if t.kind == "NAME":
            return Node("name", t.line, name=t.val)
        if t.kind == "KW":
            if t.val == "True":
                return Node("num", t.line, v=1)
            if t.val == "False":
                return Node("num", t.line, v=0)
            if t.val == "None":
                return Node("num", t.line, v=0)
        if t.kind == "OP" and t.val == "(":
            e = self.parse_expr()
            self.expect("OP", ")")
            return e
        raise CompileError(t.line, "неожиданный элемент %r" % (t.val if t.val is not None else t.kind))

# ----------------------------------------------------------------- встроенные функции
# имя: (типы аргументов | None = любой int, тип результата, генератор)
# генератор получает (cg, node, argtypes) и обязан оставить результат в AX
FAPI = dict(EXIT=0, PUTC=1, PUTS=2, GETKEY=3, KEYHIT=4, SETCUR=5, GETCUR=6, CLS=7, READFILE=8,
            WRITEFILE=9, TICKS=0x0A, PRINTDEC=0x0B, GETCWD=0x0C, SLEEP=0x0D, UIREDRAW=0x0E,
            RAND=0x0F, CURSOR=0x10, LOCALTIME=0x11, USERNAME=0x12, BEEP=0x13, KBFLUSH=0x14,
            PUTAT=0x15, FILLRECT=0x16, PUTSAT=0x17, READDIR=0x18, SHELL=0x19, EXEC=0x1A,
            STAT=0x1B, READAT=0x1C, APPEND=0x1D, MOUSE=0x1E, MOUSESHOW=0x1F, CHDIR=0x20)

# ----------------------------------------------------------------- кодогенератор
class Func:
    def __init__(self, name, params, rtype, node):
        self.name = name
        self.params = params          # [(name, type)]
        self.rtype = rtype
        self.node = node
        self.locals = {}              # name -> (slot, type)
        self.globals_decl = set()
        self.label = "f_" + name

class CodeGen:
    def __init__(self, src_name):
        self.src_name = src_name
        self.out = []                 # код
        self.data = []                # .data
        self.bss = []                 # .bss
        self.strings = {}             # bytes -> метка
        self.globals = {}             # name -> (label, type, size)
        self.funcs = {}               # name -> Func
        self.cur = None               # текущая функция (None = верхний уровень)
        self.nlabel = 0
        self.loops = []               # стек (break_label, continue_label)
        self.rt_used = set()
        self.ptypes = {}              # имя функции -> типы параметров (для проверки)
        self.max_locals = 0

    # --- утилиты вывода
    def emit(self, s):
        self.out.append("    " + s)

    def label(self, l):
        self.out.append(l + ":")

    def newlabel(self, base="L"):
        self.nlabel += 1
        return "%s_%d" % (base, self.nlabel)

    def strlit(self, b):
        if b not in self.strings:
            self.strings[b] = "s_%d" % len(self.strings)
        return self.strings[b]

    def rt(self, name):
        self.rt_used.add(name)
        deps = RT_DEPS.get(name, ())
        for d in deps:
            self.rt(d)
        return "rt_" + name

    def err(self, node, msg):
        raise CompileError(node.line, msg)

    # --- переменные
    def var_info(self, name, node, for_write=False):
        """-> (операнд памяти, тип, kind) kind: 'local'/'global'"""
        f = self.cur
        if f is not None:
            if name in f.locals:
                slot, t = f.locals[name]
                return (slot, t, "local")
            if name not in f.globals_decl and for_write:
                return None
        if name in self.globals:
            lab, t, size = self.globals[name]
            return ("[" + lab + "]", t, "global")
        return None

    def declare(self, name, typ, node):
        f = self.cur
        if f is not None and name not in f.globals_decl:
            if name in [p for p, _ in f.params]:
                self.err(node, "параметр %r нельзя переопределить другим типом" % name)
            idx = len([1 for v in f.locals.values() if v[0].startswith("[bp-")])
            slot = "[bp-%d]" % (2 * (idx + 1))
            f.locals[name] = (slot, typ)
            self.max_locals = max(self.max_locals, idx + 1)
            return (slot, typ, "local")
        if name in self.funcs or name in BUILTINS:
            self.err(node, "имя %r уже занято функцией" % name)
        lab = "g_" + name
        self.globals[name] = (lab, typ, 2)
        self.data.append("%s dw 0" % lab)
        return ("[" + lab + "]", typ, "global")

    # --- типы выражений
    def typeof(self, e):
        k = e.kind
        if k == "num":
            return "int"
        if k == "str":
            return "str"
        if k == "name":
            vi = self.var_info(e.name, e)
            if vi is None:
                self.err(e, "неизвестная переменная %r" % e.name)
            return vi[1]
        if k == "index":
            bt = self.typeof(e.base)
            if bt not in ("str", "bytes", "array"):
                self.err(e, "индексировать можно только str/bytes/array")
            return "int"
        if k == "bin":
            if e.op in ("+", "-"):
                lt = self.typeof(e.l)
                if lt in ("str", "bytes", "array") and self.typeof(e.r) == "int":
                    return lt
            return "int"
        if k in ("unary", "not", "and", "or"):
            return "int"
        if k == "call":
            if e.name in self.funcs:
                return self.funcs[e.name].rtype
            if e.name in BUILTINS:
                return BUILTINS[e.name][1]
            self.err(e, "неизвестная функция %r" % e.name)
        self.err(e, "непонятное выражение")

    # --- выражения -> AX
    def expr(self, e):
        k = e.kind
        if k == "num":
            v = e.v
            if v < -32768 or v > 65535:
                self.err(e, "число %d не помещается в 16 бит" % v)
            v &= 0xFFFF
            if v == 0:
                self.emit("xor ax, ax")
            else:
                self.emit("mov ax, %d" % v)
            return "int"
        if k == "str":
            self.emit("mov ax, %s" % self.strlit(e.v))
            return "str"
        if k == "name":
            vi = self.var_info(e.name, e)
            if vi is None:
                if e.name in self.globals_pending:
                    self.err(e, "переменная %r используется до присваивания" % e.name)
                self.err(e, "неизвестная переменная %r" % e.name)
            op, t, kind = vi
            if t in ("bytes", "array") and kind == "global":
                self.emit("mov ax, %s" % op[1:-1])       # адрес буфера
            else:
                self.emit("mov ax, %s" % op)
            return t
        if k == "index":
            bt = self.typeof(e.base)
            self.index_addr(e)                           # -> BX
            if bt == "array":
                self.emit("mov ax, [bx]")
            else:
                self.emit("mov al, [bx]")
                self.emit("xor ah, ah")
            return "int"
        if k == "unary":
            t = self.expr(e.e)
            if t != "int":
                self.err(e, "унарный %s применим только к int" % e.op)
            self.emit("neg ax" if e.op == "-" else "not ax")
            return "int"
        if k == "not":
            t = self.expr(e.e)
            self.emit("test ax, ax")
            self.emit("mov ax, 0")
            l = self.newlabel()
            self.emit("jnz %s" % l)
            self.emit("inc ax")
            self.label(l)
            return "int"
        if k in ("and", "or"):
            lf = self.newlabel()
            le = self.newlabel()
            self.expr(e.l)
            self.emit("test ax, ax")
            self.emit(("jz %s" if k == "and" else "jnz %s") % lf)
            self.expr(e.r)
            self.emit("test ax, ax")
            self.emit(("jz %s" if k == "and" else "jnz %s") % lf)
            self.emit("mov ax, %d" % (1 if k == "and" else 0))
            self.emit("jmp %s" % le)
            self.label(lf)
            self.emit("mov ax, %d" % (0 if k == "and" else 1))
            self.label(le)
            return "int"
        if k == "bin":
            return self.binop(e)
        if k == "call":
            return self.call(e)
        self.err(e, "непонятное выражение")

    def index_addr(self, e):
        """адрес элемента -> BX (AX портится)"""
        bt = self.typeof(e.base)
        if e.idx.kind == "num" and e.base.kind == "name":
            # константный индекс
            self.expr(e.base)
            off = e.idx.v * (2 if bt == "array" else 1)
            self.emit("mov bx, ax")
            if off:
                self.emit("add bx, %d" % off)
            return
        self.expr(e.base)
        self.emit("push ax")
        t = self.expr(e.idx)
        if t != "int":
            self.err(e, "индекс должен быть int")
        if bt == "array":
            self.emit("shl ax, 1")
        self.emit("pop bx")
        self.emit("add bx, ax")

    def binop(self, e):
        op = e.op
        lt = self.typeof(e.l)
        rt = self.typeof(e.r)
        if op in ("==", "!=") and lt in ("str", "bytes") and rt in ("str", "bytes"):
            self.push_args([e.l, e.r])
            self.emit("call %s" % self.rt("streq"))
            self.emit("add sp, 4")
            if op == "!=":
                self.emit("xor ax, 1")
            return "int"
        result = "int"
        if lt != "int" or rt != "int":
            if op in ("==", "!=", "<", "<=", ">", ">=") and lt != "int" and rt != "int":
                pass  # сравнение адресов
            elif op in ("+", "-") and lt in ("str", "bytes", "array") and rt == "int":
                result = lt  # сдвиг указателя: s + 3 — строка без первых трёх символов
            else:
                self.err(e, "оператор %s требует int (слева %s, справа %s)" % (op, lt, rt))
        # константа справа — без push/pop
        if e.r.kind == "num" and op in ("+", "-", "&", "|", "^", "<<", ">>", "==", "!=", "<", "<=", ">", ">=", "*"):
            self.expr(e.l)
            v = e.r.v & 0xFFFF
            if op == "*":
                if v == 0:
                    self.emit("xor ax, ax")
                elif v == 1:
                    pass
                elif v & (v - 1) == 0:
                    self.emit("shl ax, %d" % (v.bit_length() - 1))
                else:
                    self.emit("mov cx, %d" % v)
                    self.emit("imul cx")
                return "int"
            if op in ("<<", ">>"):
                self.emit(("shl ax, %d" if op == "<<" else "sar ax, %d") % (v & 15))
                return "int"
            if op in ("+", "-", "&", "|", "^"):
                mn = {"+": "add", "-": "sub", "&": "and", "|": "or", "^": "xor"}[op]
                if v or op in ("&",):
                    self.emit("%s ax, %d" % (mn, v))
                return result
            self.emit("cmp ax, %d" % v)
            self.setcc(op)
            return "int"
        self.operands_cx(e.l, e.r)
        if op in ("+", "-", "&", "|", "^"):
            self.emit("%s ax, cx" % {"+": "add", "-": "sub", "&": "and", "|": "or", "^": "xor"}[op])
            return result
        elif op == "*":
            self.emit("imul cx")
        elif op in ("/", "//", "%"):
            self.emit("call %s" % self.rt("divmod"))
            if op == "%":
                self.emit("mov ax, dx")
        elif op == "<<":
            self.emit("shl ax, cl")
        elif op == ">>":
            self.emit("sar ax, cl")
        else:
            self.emit("cmp ax, cx")
            self.setcc(op)
        return "int"

    def simple_operand(self, e):
        """скалярная переменная или константа -> операнд, иначе None"""
        if e.kind == "num":
            return str(e.v & 0xFFFF)
        if e.kind == "name":
            vi = self.var_info(e.name, e)
            if vi is not None and vi[1] in ("int", "str"):
                return vi[0]
        return None

    def operands_cx(self, l, r):
        """левый операнд -> AX, правый -> CX"""
        so = self.simple_operand(r)
        if so is not None:
            self.expr(l)
            self.emit("mov cx, %s" % so)
            return
        self.expr(l)
        self.emit("push ax")
        self.expr(r)
        self.emit("mov cx, ax")
        self.emit("pop ax")

    CC = {"==": "e", "!=": "ne", "<": "l", "<=": "le", ">": "g", ">=": "ge"}
    NCC = {"==": "ne", "!=": "e", "<": "ge", "<=": "g", ">": "le", ">=": "l"}

    def setcc(self, op):
        l = self.newlabel()
        self.emit("mov ax, 1")
        self.emit("j%s %s" % (self.CC[op], l))
        self.emit("dec ax")
        self.label(l)

    # --- условие: переход на lfalse, если ложно
    def cond(self, e, lfalse):
        k = e.kind
        if k == "not":
            lt = self.newlabel()
            self.cond(e.e, lt)
            self.emit("jmp %s" % lfalse)
            self.label(lt)
            return
        if k == "and":
            self.cond(e.l, lfalse)
            self.cond(e.r, lfalse)
            return
        if k == "or":
            lt = self.newlabel()
            lf2 = self.newlabel()
            self.cond(e.l, lf2)
            self.emit("jmp %s" % lt)
            self.label(lf2)
            self.cond(e.r, lfalse)
            self.label(lt)
            return
        if k == "bin" and e.op in self.CC:
            lt_, rt_ = self.typeof(e.l), self.typeof(e.r)
            if not (lt_ in ("str", "bytes") and rt_ in ("str", "bytes")):
                if e.r.kind == "num":
                    self.expr(e.l)
                    self.emit("cmp ax, %d" % (e.r.v & 0xFFFF))
                else:
                    self.operands_cx(e.l, e.r)
                    self.emit("cmp ax, cx")
                self.emit("j%s %s" % (self.NCC[e.op], lfalse))
                return
        if k == "num":
            if e.v == 0:
                self.emit("jmp %s" % lfalse)
            return
        self.expr(e)
        self.emit("test ax, ax")
        self.emit("jz %s" % lfalse)

    # --- вызовы
    def push_args(self, args):
        types = []
        for a in args:
            types.append(self.expr(a))
            self.emit("push ax")
        return types

    def call(self, e):
        name = e.name
        if name in self.funcs:
            f = self.funcs[name]
            if e.kwargs:
                self.err(e, "именованные аргументы допустимы только у print")
            if len(e.args) != len(f.params):
                self.err(e, "функция %s ожидает %d аргументов, передано %d" % (name, len(f.params), len(e.args)))
            for a, (pn, pt) in zip(e.args, f.params):
                at = self.typeof(a)
                if not type_ok(pt, at):
                    self.err(a, "аргумент %r функции %s: ожидается %s, передан %s" % (pn, name, pt, at))
            self.push_args(e.args)
            self.emit("call %s" % f.label)
            if f.params:
                self.emit("add sp, %d" % (2 * len(f.params)))
            return f.rtype
        if name in BUILTINS:
            argt, rtype, gen = BUILTINS[name]
            if e.kwargs and name != "print":
                self.err(e, "именованные аргументы допустимы только у print")
            if argt is not None:
                if len(e.args) not in ([len(argt)] if isinstance(argt, tuple) else argt):
                    self.err(e, "функция %s: неверное число аргументов (%d)" % (name, len(e.args)))
                if isinstance(argt, tuple):
                    for a, want in zip(e.args, argt):
                        got = self.typeof(a)
                        if not type_ok(want, got):
                            self.err(a, "функция %s: ожидается %s, передан %s" % (name, want, got))
            gen(self, e)
            return rtype
        self.err(e, "неизвестная функция %r" % name)

    # --- операторы
    def stmt(self, s):
        k = s.kind
        if k == "expr":
            if s.value.kind == "call":
                self.call(s.value)
            elif s.value.kind == "str":
                pass  # строка-документация
            else:
                self.err(s, "выражение без эффекта")
        elif k == "assign":
            self.assign(s)
        elif k == "pass":
            pass
        elif k == "if":
            lelse = self.newlabel("else")
            lend = self.newlabel("endif")
            self.cond(s.cond, lelse)
            self.block(s.body)
            if s.orelse:
                self.emit("jmp %s" % lend)
            self.label(lelse)
            if s.orelse:
                self.block(s.orelse)
                self.label(lend)
        elif k == "while":
            ltop = self.newlabel("while")
            lbrk = self.newlabel("wend")
            lelse = self.newlabel("welse")
            self.label(ltop)
            self.cond(s.cond, lelse)
            self.loops.append((lbrk, ltop))
            self.block(s.body)
            self.loops.pop()
            self.emit("jmp %s" % ltop)
            self.label(lelse)
            self.block(s.orelse)
            self.label(lbrk)
        elif k == "for":
            self.for_stmt(s)
        elif k == "break":
            if not self.loops:
                self.err(s, "break вне цикла")
            self.emit("jmp %s" % self.loops[-1][0])
        elif k == "continue":
            if not self.loops:
                self.err(s, "continue вне цикла")
            self.emit("jmp %s" % self.loops[-1][1])
        elif k == "return":
            if self.cur is None:
                self.err(s, "return вне функции")
            if s.value is not None:
                t = self.expr(s.value)
                if self.cur.rtype == "none":
                    self.err(s, "функция %s ничего не возвращает (-> None)" % self.cur.name)
                if not type_ok(self.cur.rtype, t):
                    self.err(s, "return: ожидается %s, получен %s" % (self.cur.rtype, t))
            self.emit("jmp %s" % self.cur.ret_label)
        elif k == "global":
            if self.cur is None:
                self.err(s, "global вне функции")
            for n in s.names:
                if n in self.cur.locals:
                    self.err(s, "%r уже используется как локальная" % n)
                self.cur.globals_decl.add(n)
        elif k == "def":
            if self.cur is not None:
                self.err(s, "вложенные функции не поддерживаются")
            # тело генерируется отдельно
        else:
            self.err(s, "неизвестный оператор %s" % k)

    def block(self, body):
        for s in body:
            self.stmt(s)

    def assign(self, s):
        tgt = s.target
        val = s.value
        if tgt.kind == "index":
            bt = self.typeof(tgt.base)
            vt = self.typeof(val)
            if vt != "int":
                self.err(s, "в элемент можно записать только int")
            self.expr(val)
            self.emit("push ax")
            self.index_addr(tgt)
            self.emit("pop ax")
            self.emit("mov [bx], ax" if bt == "array" else "mov [bx], al")
            return
        name = tgt.name
        # буферы: только глобально
        if val.kind == "call" and val.name in ("bytes", "array"):
            if self.cur is not None:
                self.err(s, "bytes()/array() можно создавать только на верхнем уровне")
            if len(val.args) != 1 or val.args[0].kind != "num":
                self.err(s, "%s(N): N — константа" % val.name)
            n = val.args[0].v
            if n <= 0 or n > 65000:
                self.err(s, "недопустимый размер буфера")
            if name in self.globals:
                self.err(s, "буфер %r уже объявлен" % name)
            lab = "g_" + name
            size = n * (2 if val.name == "array" else 1)
            self.globals[name] = (lab, val.name, size)
            self.bss.append("%s %s %d" % (lab, "resw" if val.name == "array" else "resb", n))
            # обнуление при старте
            self.emit("mov di, %s" % lab)
            self.emit("mov cx, %d" % size)
            self.emit("call %s" % self.rt("zero"))
            return
        vt = self.typeof(val)
        if vt == "none":
            self.err(s, "функция ничего не возвращает")
        vi = self.var_info(name, s, for_write=True)
        if vi is None:
            if self.cur is None and name in self.globals_pending:
                pass
            vi = self.declare(name, vt, s)
        op, t, kind = vi
        if t in ("bytes", "array"):
            self.err(s, "буфер %r нельзя переприсвоить" % name)
        if not type_ok(t, vt):
            self.err(s, "переменная %r имеет тип %s, присваивается %s" % (name, t, vt))
        self.expr(val)
        self.emit("mov %s, ax" % op)

    def for_stmt(self, s):
        args = s.args
        if len(args) == 1:
            start, stop, step = Node("num", s.line, v=0), args[0], None
        elif len(args) == 2:
            start, stop, step = args[0], args[1], None
        else:
            start, stop, step = args
            if step.kind != "num" or step.v == 0:
                self.err(s, "шаг range должен быть ненулевой константой")
        for a in (start, stop):
            if self.typeof(a) != "int":
                self.err(s, "границы range должны быть int")
        vi = self.var_info(s.var, s, for_write=True)
        if vi is None:
            vi = self.declare(s.var, "int", s)
        if vi[1] != "int":
            self.err(s, "переменная цикла %r должна быть int" % s.var)
        var = vi[0]
        # предел — во временную переменную (локальная или глобальная)
        lim = self.temp_slot()
        self.expr(stop)
        self.emit("mov %s, ax" % lim)
        self.expr(start)
        self.emit("mov %s, ax" % var)
        ltop = self.newlabel("for")
        lnext = self.newlabel("fnext")
        lbrk = self.newlabel("fend")
        lelse = self.newlabel("felse")
        stepv = 1 if step is None else step.v
        self.label(ltop)
        self.emit("mov ax, %s" % var)
        self.emit("cmp ax, %s" % lim)
        self.emit(("jge %s" if stepv > 0 else "jle %s") % lelse)
        self.loops.append((lbrk, lnext))
        self.block(s.body)
        self.loops.pop()
        self.label(lnext)
        if stepv == 1:
            self.emit("inc word %s" % var)
        elif stepv == -1:
            self.emit("dec word %s" % var)
        else:
            self.emit("add word %s, %d" % (var, stepv & 0xFFFF))
        self.emit("jmp %s" % ltop)
        self.label(lelse)
        self.block(s.orelse)
        self.label(lbrk)

    def temp_slot(self):
        if self.cur is None:
            self.ntemp = getattr(self, "ntemp", 0) + 1
            lab = "g_tmp%d" % self.ntemp
            self.data.append("%s dw 0" % lab)
            return "[" + lab + "]"
        f = self.cur
        idx = len(f.locals)
        f.locals["$tmp%d" % idx] = ("[bp-%d]" % (2 * (idx + 1)), "int")
        self.max_locals = max(self.max_locals, idx + 1)
        return "[bp-%d]" % (2 * (idx + 1))

    # --- функции
    def gen_func(self, f):
        self.cur = f
        self.max_locals = 0
        f.locals = {}
        n = len(f.params)
        for i, (pn, pt) in enumerate(f.params):
            f.locals[pn] = ("[bp+%d]" % (4 + 2 * (n - 1 - i)), pt)
        f.ret_label = f.label + "_ret"
        start = len(self.out)
        self.label(f.label)
        self.emit("push bp")
        self.emit("mov bp, sp")
        sub_pos = len(self.out)
        self.emit("")  # место под sub sp
        self.block(f.node.body)
        self.emit("xor ax, ax")
        self.label(f.ret_label)
        if self.max_locals:
            self.out[sub_pos] = "    sub sp, %d" % (2 * self.max_locals)
            self.emit("mov sp, bp")
        else:
            del self.out[sub_pos]
        self.emit("pop bp")
        self.emit("ret")
        self.cur = None

    # --- программа
    def compile(self, prog):
        # регистрируем функции
        for s in prog:
            if s.kind == "def":
                if s.name in self.funcs or s.name in BUILTINS:
                    self.err(s, "функция %r уже определена" % s.name)
                self.funcs[s.name] = Func(s.name, s.params, s.rtype, s)
        self.globals_pending = set()
        self.label("start")
        self.emit("cld")
        self.block([s for s in prog if s.kind != "def"])
        self.emit("mov ah, 0")
        self.emit("int 0x80")
        for f in self.funcs.values():
            self.gen_func(f)
        return self.render()

    def render(self):
        L = []
        L.append("; сгенерировано ferpy %s из %s" % (VERSION, os.path.basename(self.src_name)))
        L.append("    org 0x100")
        L.append("    db \"FAPI\", 1, 0")
        L.append("    dw start")
        L.append("    times 8 db 0")
        L.extend(self.out)
        # runtime
        for name in sorted(self.rt_used):
            L.append("")
            L.extend(RT[name].strip("\n").split("\n"))
        L.append("")
        L.append("section .data")
        for b, lab in self.strings.items():
            L.append("%s db %s" % (lab, fmt_bytes(b)))
        L.extend(self.data)
        if "input" in self.rt_used:
            L.append("rt_inbuf times 81 db 0")
        if "print_int" in self.rt_used or "itoa" in self.rt_used:
            L.append("rt_numbuf times 8 db 0")
        if self.bss:
            L.append("")
            L.append("section .bss")
            L.extend(self.bss)
        return "\n".join(L) + "\n"

def type_ok(want, got):
    if want == got:
        return True
    if want == "str" and got == "bytes":
        return True
    if want == "bytes" and got == "str":
        return True
    return False

def fmt_bytes(b):
    parts = []
    run = ""
    for c in b + b"\0":
        if 32 <= c < 127 and c != 34:
            run += chr(c)
        else:
            if run:
                parts.append('"%s"' % run)
                run = ""
            parts.append(str(c))
    if run:
        parts.append('"%s"' % run)
    return ", ".join(parts)

# ----------------------------------------------------------------- встроенные
def b_fapi(fn, setup=None, result=None, nargs=0, argtypes=None):
    """простая обёртка над int 80h: аргументы -> регистры по списку setup"""
    def gen(cg, e):
        regs = setup or []
        if len(e.args) > 1:
            cg.push_args(e.args)
            for i, r in reversed(list(enumerate(regs))):
                cg.emit("pop %s" % r)
        elif len(e.args) == 1:
            cg.expr(e.args[0])
            if regs[0] != "ax":
                cg.emit("mov %s, ax" % regs[0])
        cg.emit("mov ah, %d" % FAPI[fn])
        cg.emit("int 0x80")
        if result:
            for ins in result:
                cg.emit(ins)
    return gen

def gen_print(cg, e):
    sep = b" "
    end = b"\r\n"
    for k, v in e.kwargs.items():
        if v.kind != "str":
            cg.err(e, "print: sep/end должны быть строковыми константами")
        if k == "sep":
            sep = v.v
        elif k == "end":
            end = v.v
        else:
            cg.err(e, "print: неизвестный параметр %r" % k)
    for i, a in enumerate(e.args):
        if i and sep:
            cg.emit("mov si, %s" % cg.strlit(sep))
            cg.emit("mov ah, 2")
            cg.emit("int 0x80")
        t = cg.expr(a)
        if t == "int":
            cg.emit("call %s" % cg.rt("print_int"))
        elif t in ("str", "bytes"):
            cg.emit("mov si, ax")
            cg.emit("mov ah, 2")
            cg.emit("int 0x80")
        else:
            cg.err(a, "print не умеет печатать %s" % t)
    if end:
        cg.emit("mov si, %s" % cg.strlit(end))
        cg.emit("mov ah, 2")
        cg.emit("int 0x80")

def gen_sizeof(cg, e):
    a = e.args[0]
    t = cg.typeof(a)
    if t in ("array", "bytes") and a.kind == "name":
        lab, tt, size = cg.globals[a.name]
        cg.emit("mov ax, %d" % (size // (2 if tt == "array" else 1)))
        return
    cg.err(e, "sizeof применим только к имени буфера bytes/array")

def gen_len(cg, e):
    a = e.args[0]
    t = cg.typeof(a)
    if t == "array":
        return gen_sizeof(cg, e)
    if t in ("str", "bytes"):
        cg.expr(a)
        cg.emit("call %s" % cg.rt("strlen"))
        return
    cg.err(e, "len применим к str/bytes/array")

def gen_rtcall(name, nargs):
    def gen(cg, e):
        cg.push_args(e.args)
        cg.emit("call %s" % cg.rt(name))
        if nargs:
            cg.emit("add sp, %d" % (2 * nargs))
    return gen

def gen_ord(cg, e):
    a = e.args[0]
    if a.kind == "str":
        cg.emit("mov ax, %d" % (a.v[0] if a.v else 0))
        return
    cg.expr(a)
    cg.emit("mov bx, ax")
    cg.emit("mov al, [bx]")
    cg.emit("xor ah, ah")

def gen_minmax(which):
    def gen(cg, e):
        cg.expr(e.args[0])
        cg.emit("push ax")
        cg.expr(e.args[1])
        cg.emit("pop cx")
        cg.emit("cmp cx, ax")
        l = cg.newlabel()
        cg.emit(("jle %s" if which == "min" else "jge %s") % l)
        cg.emit("mov cx, ax")
        cg.label(l)
        cg.emit("mov ax, cx")
    return gen

def gen_abs(cg, e):
    cg.expr(e.args[0])
    l = cg.newlabel()
    cg.emit("test ax, ax")
    cg.emit("jns %s" % l)
    cg.emit("neg ax")
    cg.label(l)

def gen_peek(size):
    def gen(cg, e):
        cg.push_args(e.args)
        cg.emit("pop bx")
        cg.emit("pop es")
        if size == 1:
            cg.emit("mov al, [es:bx]")
            cg.emit("xor ah, ah")
        else:
            cg.emit("mov ax, [es:bx]")
        cg.emit("push ds")
        cg.emit("pop es")
    return gen

def gen_poke(size):
    def gen(cg, e):
        cg.push_args(e.args)
        cg.emit("pop ax")
        cg.emit("pop bx")
        cg.emit("pop es")
        cg.emit("mov [es:bx], al" if size == 1 else "mov [es:bx], ax")
        cg.emit("push ds")
        cg.emit("pop es")
    return gen

def gen_inp(cg, e):
    cg.expr(e.args[0])
    cg.emit("mov dx, ax")
    cg.emit("in al, dx")
    cg.emit("xor ah, ah")

def gen_outp(cg, e):
    cg.push_args(e.args)
    cg.emit("pop ax")
    cg.emit("pop dx")
    cg.emit("out dx, al")

def gen_vseg(cg, e):
    cg.emit("mov ax, [0x10]")          # сегмент экрана от gui (0 = обычная консоль)
    cg.emit("test ax, ax")
    l = cg.newlabel()
    cg.emit("jnz %s" % l)
    cg.emit("mov ax, 0xB800")
    cg.label(l)

def gen_dataseg(cg, e):
    cg.emit("mov ax, ds")

def gen_exit(cg, e):
    cg.emit("mov ah, 0")
    cg.emit("int 0x80")

def gen_args(cg, e):
    cg.emit("mov ax, 0x80")
    cg.emit("call %s" % cg.rt("skipsp"))

def gen_getcur(which):
    def gen(cg, e):
        cg.emit("mov ah, 6")
        cg.emit("int 0x80")
        cg.emit("mov al, dh" if which == "row" else "mov al, dl")
        cg.emit("xor ah, ah")
    return gen

def gen_time(reg):
    def gen(cg, e):
        cg.emit("mov ah, 0x11")
        cg.emit("int 0x80")
        cg.emit("mov al, %s" % reg)
        cg.emit("xor ah, ah")
    return gen

def gen_mouse(which):
    def gen(cg, e):
        cg.emit("mov ah, 0x1E")
        cg.emit("int 0x80")
        if which == "x":
            cg.emit("mov ax, cx")
        elif which == "y":
            cg.emit("mov ax, dx")
        else:
            cg.emit("xor ah, ah")
    return gen

def gen_readfile(cg, e):
    cg.push_args(e.args)
    cg.emit("pop cx")
    cg.emit("pop di")
    cg.emit("pop si")
    cg.emit("mov ah, 8")
    cg.emit("int 0x80")
    l = cg.newlabel()
    cg.emit("jnc %s" % l)
    cg.emit("mov ax, -1")
    cg.label(l)

def gen_cf_bool(fn, regs):
    """вызов, возвращающий 1 при успехе (CF=0)"""
    def gen(cg, e):
        cg.push_args(e.args)
        for r in reversed(regs):
            cg.emit("pop %s" % r)
        cg.emit("mov ah, %d" % FAPI[fn])
        cg.emit("int 0x80")
        cg.emit("mov ax, 0")
        l = cg.newlabel()
        cg.emit("jc %s" % l)
        cg.emit("inc ax")
        cg.label(l)
    return gen

def gen_stat(cg, e):
    cg.expr(e.args[0])
    cg.emit("mov si, ax")
    cg.emit("mov ah, 0x1B")
    cg.emit("int 0x80")
    l = cg.newlabel()
    cg.emit("jnc %s" % l)
    cg.emit("mov ax, -1")
    cg.label(l)

def gen_buf(cg, e):
    cg.err(e, "%s() допустим только в присваивании на верхнем уровне: name = %s(N)" % (e.name, e.name))

BUILTINS = {
    # имя: (типы аргументов (кортеж) | список допустимых количеств | None, тип результата, генератор)
    "print":     (None, "none", gen_print),
    "input":     ((), "str", lambda cg, e: cg.emit("call %s" % cg.rt("input"))),
    "len":       ([1], "int", gen_len),
    "sizeof":    ([1], "int", gen_sizeof),
    "ord":       ([1], "int", gen_ord),
    "abs":       (("int",), "int", gen_abs),
    "min":       (("int", "int"), "int", gen_minmax("min")),
    "max":       (("int", "int"), "int", gen_minmax("max")),
    "int":       (("str",), "int", gen_rtcall("atoi", 1)),
    "str":       (("int",), "str", gen_rtcall("itoa", 1)),
    "bytes":     (None, "bytes", gen_buf),
    "array":     (None, "array", gen_buf),
    "exit":      ((), "none", gen_exit),
    "vseg":      ((), "int", gen_vseg),
    "dataseg":   ((), "int", gen_dataseg),
    "args":      ((), "str", gen_args),
    # консоль
    "putc":      (("int",), "none", b_fapi("PUTC", ["ax"])),
    "puts":      (("str",), "none", b_fapi("PUTS", ["si"])),
    "getkey":    ((), "int", b_fapi("GETKEY")),
    "keyhit":    ((), "int", b_fapi("KEYHIT")),
    "cls":       ((), "none", b_fapi("CLS")),
    "setcur":    (("int", "int"), "none", b_fapi("SETCUR", ["dh_", "dl_"])),
    "currow":    ((), "int", gen_getcur("row")),
    "curcol":    ((), "int", gen_getcur("col")),
    "cursor":    (("int",), "none", None),
    "putat":     (("int", "int", "int", "int"), "none", None),
    "putsat":    (("int", "int", "str", "int"), "none", None),
    "fillrect":  (("int", "int", "int", "int", "int", "int"), "none", None),
    "beep":      ((), "none", b_fapi("BEEP")),
    "kbflush":   ((), "none", b_fapi("KBFLUSH")),
    # время, случайные числа
    "ticks":     ((), "int", b_fapi("TICKS")),
    "sleep":     (("int",), "none", b_fapi("SLEEP", ["cx"])),
    "rand":      ((), "int", b_fapi("RAND", None, ["and ax, 0x7FFF"])),
    "hour":      ((), "int", gen_time("ch")),
    "minute":    ((), "int", gen_time("cl")),
    "second":    ((), "int", gen_time("dh")),
    # файлы и система
    "readfile":  (("str", "bytes", "int"), "int", gen_readfile),
    "writefile": (("str", "bytes", "int"), "int", gen_cf_bool("WRITEFILE", ["si", "di", "cx"])),
    "appendfile": (("str", "bytes", "int"), "int", gen_cf_bool("APPEND", ["si", "di", "cx"])),
    "stat":      (("str",), "int", gen_stat),
    "getcwd":    (("bytes",), "none", b_fapi("GETCWD", ["di"])),
    "chdir":     (("str",), "int", gen_cf_bool("CHDIR", ["si"])),
    "shell":     (("str",), "none", b_fapi("SHELL", ["si"])),
    "exec":      (("str",), "none", b_fapi("EXEC", ["si"], None)),
    "username":  (("bytes",), "none", b_fapi("USERNAME", ["di"])),
    # мышь
    "mousex":    ((), "int", gen_mouse("x")),
    "mousey":    ((), "int", gen_mouse("y")),
    "mousebtn":  ((), "int", gen_mouse("b")),
    "mouseshow": (("int",), "none", b_fapi("MOUSESHOW", ["cx"])),
    # память и порты
    "peekb":     (("int", "int"), "int", gen_peek(1)),
    "peekw":     (("int", "int"), "int", gen_peek(2)),
    "pokeb":     (("int", "int", "int"), "none", gen_poke(1)),
    "pokew":     (("int", "int", "int"), "none", gen_poke(2)),
    "inp":       (("int",), "int", gen_inp),
    "outp":      (("int", "int"), "none", gen_outp),
    # строки
    "strcpy":    (("bytes", "str"), "none", gen_rtcall("strcpy", 2)),
    "strcat":    (("bytes", "str"), "none", gen_rtcall("strcat", 2)),
    "strcmp":    (("str", "str"), "int", gen_rtcall("strcmp", 2)),
    "upper":     (("bytes",), "none", gen_rtcall("upper", 1)),
    "find":      (("str", "int"), "int", gen_rtcall("find", 2)),
}

# особые обёртки с байтовыми регистрами
def gen_setcur(cg, e):
    cg.push_args(e.args)
    cg.emit("pop ax")          # столбец
    cg.emit("pop dx")          # строка
    cg.emit("mov dh, dl")
    cg.emit("mov dl, al")
    cg.emit("mov ah, 5")
    cg.emit("int 0x80")
BUILTINS["setcur"] = (("int", "int"), "none", gen_setcur)

def gen_cursor(cg, e):
    cg.expr(e.args[0])
    cg.emit("test ax, ax")
    cg.emit("mov cx, 0x2000")
    l = cg.newlabel()
    cg.emit("jz %s" % l)
    cg.emit("mov cx, 0x0607")
    cg.label(l)
    cg.emit("mov ah, 0x10")
    cg.emit("int 0x80")
BUILTINS["cursor"] = (("int",), "none", gen_cursor)

def gen_putat(cg, e):
    cg.push_args(e.args)       # row col ch attr
    cg.emit("pop bx")          # attr -> bl
    cg.emit("pop ax")          # ch
    cg.emit("pop dx")          # col
    cg.emit("pop cx")          # row
    cg.emit("mov dh, cl")
    cg.emit("mov ah, 0x15")
    cg.emit("int 0x80")
BUILTINS["putat"] = (("int", "int", "int", "int"), "none", gen_putat)

def gen_putsat(cg, e):
    cg.push_args(e.args)       # row col str attr
    cg.emit("pop bx")
    cg.emit("pop si")
    cg.emit("pop dx")
    cg.emit("pop cx")
    cg.emit("mov dh, cl")
    cg.emit("mov ah, 0x17")
    cg.emit("int 0x80")
BUILTINS["putsat"] = (("int", "int", "str", "int"), "none", gen_putsat)

def gen_fillrect3(cg, e):
    # row col h w ch attr -> DH,DL CH,CL AL BL
    cg.push_args(e.args)
    cg.emit("pop bx")          # BL = attr
    cg.emit("pop ax")          # AL = ch
    cg.emit("pop cx")          # CL = w
    cg.emit("pop dx")          # DL = h
    cg.emit("mov ch, dl")      # CH = h
    cg.emit("pop dx")          # DL = col
    cg.emit("pop si")          # SI = row
    cg.emit("xchg ax, si")     # AX = row, SI = ch
    cg.emit("mov dh, al")      # DH = row
    cg.emit("xchg ax, si")     # AX = ch
    cg.emit("mov ah, 0x16")
    cg.emit("int 0x80")
BUILTINS["fillrect"] = (("int", "int", "int", "int", "int", "int"), "none", gen_fillrect3)

# ----------------------------------------------------------------- runtime (frasm)
RT_DEPS = {"print_int": ("itoa",), "input": (), "strcat": ("strlen",), "str": ("itoa",)}
RT = {
"zero": """
; DI буфер, CX байт -> обнулить
rt_zero:
    push ax
    push di
    push cx
    xor al, al
    rep stosb
    pop cx
    pop di
    pop ax
    ret
""",
"itoa": """
; AX (со знаком) -> ASCIIZ в rt_numbuf, AX = адрес строки
rt_itoa:
    push bx
    push cx
    push dx
    push si
    mov bx, rt_numbuf + 7
    mov byte [bx], 0
    mov cx, 10
    xor si, si
    test ax, ax
    jns rt_itoa_l
    neg ax
    inc si
rt_itoa_l:
    xor dx, dx
    div cx
    add dl, '0'
    dec bx
    mov [bx], dl
    test ax, ax
    jnz rt_itoa_l
    test si, si
    jz rt_itoa_d
    dec bx
    mov byte [bx], '-'
rt_itoa_d:
    mov ax, bx
    pop si
    pop dx
    pop cx
    pop bx
    ret
""",
"divmod": """
; AX / CX (со знаком, округление вниз, как в Python) -> AX частное, DX остаток
rt_divmod:
    cwd
    idiv cx
    test dx, dx
    jz rt_divmod_d
    push dx
    xor dx, cx
    pop dx
    jns rt_divmod_d                 ; знаки делимого и делителя совпадают
    dec ax
    add dx, cx
rt_divmod_d:
    ret
""",
"print_int": """
; AX -> печать числа со знаком
rt_print_int:
    push si
    call rt_itoa
    mov si, ax
    mov ah, 2
    int 0x80
    pop si
    ret
""",
"strlen": """
; AX строка -> AX длина
rt_strlen:
    push bx
    mov bx, ax
rt_strlen_l:
    cmp byte [bx], 0
    je rt_strlen_d
    inc bx
    jmp rt_strlen_l
rt_strlen_d:
    sub bx, ax
    mov ax, bx
    pop bx
    ret
""",
"streq": """
; (a, b) в стеке -> AX = 1 если строки равны
rt_streq:
    push bp
    mov bp, sp
    push si
    push di
    mov si, [bp + 6]
    mov di, [bp + 4]
rt_streq_l:
    mov al, [si]
    cmp al, [di]
    jne rt_streq_no
    test al, al
    jz rt_streq_yes
    inc si
    inc di
    jmp rt_streq_l
rt_streq_no:
    xor ax, ax
    jmp rt_streq_d
rt_streq_yes:
    mov ax, 1
rt_streq_d:
    pop di
    pop si
    pop bp
    ret
""",
"strcmp": """
; (a, b) -> AX = -1 / 0 / 1
rt_strcmp:
    push bp
    mov bp, sp
    push si
    push di
    mov si, [bp + 6]
    mov di, [bp + 4]
rt_strcmp_l:
    mov al, [si]
    cmp al, [di]
    jb rt_strcmp_lt
    ja rt_strcmp_gt
    test al, al
    jz rt_strcmp_eq
    inc si
    inc di
    jmp rt_strcmp_l
rt_strcmp_lt:
    mov ax, -1
    jmp rt_strcmp_d
rt_strcmp_gt:
    mov ax, 1
    jmp rt_strcmp_d
rt_strcmp_eq:
    xor ax, ax
rt_strcmp_d:
    pop di
    pop si
    pop bp
    ret
""",
"strcpy": """
; (dst, src) -> копировать ASCIIZ
rt_strcpy:
    push bp
    mov bp, sp
    push si
    push di
    mov di, [bp + 6]
    mov si, [bp + 4]
rt_strcpy_l:
    lodsb
    stosb
    test al, al
    jnz rt_strcpy_l
    pop di
    pop si
    pop bp
    ret
""",
"strcat": """
; (dst, src) -> дописать src в конец dst
rt_strcat:
    push bp
    mov bp, sp
    push si
    push di
    mov ax, [bp + 6]
    call rt_strlen
    mov di, [bp + 6]
    add di, ax
    mov si, [bp + 4]
rt_strcat_l:
    lodsb
    stosb
    test al, al
    jnz rt_strcat_l
    pop di
    pop si
    pop bp
    ret
""",
"upper": """
; (s) -> перевести строку в верхний регистр на месте
rt_upper:
    push bp
    mov bp, sp
    push bx
    mov bx, [bp + 4]
rt_upper_l:
    mov al, [bx]
    test al, al
    jz rt_upper_d
    cmp al, 'a'
    jb rt_upper_n
    cmp al, 'z'
    ja rt_upper_n
    sub al, 0x20
    mov [bx], al
rt_upper_n:
    inc bx
    jmp rt_upper_l
rt_upper_d:
    pop bx
    pop bp
    ret
""",
"find": """
; (s, ch) -> AX индекс первого символа ch или -1
rt_find:
    push bp
    mov bp, sp
    push bx
    push cx
    mov bx, [bp + 6]
    mov cx, [bp + 4]
    xor ax, ax
rt_find_l:
    mov ch, [bx]
    cmp ch, cl
    je rt_find_d
    test ch, ch
    jz rt_find_no
    inc bx
    inc ax
    jmp rt_find_l
rt_find_no:
    mov ax, -1
rt_find_d:
    pop cx
    pop bx
    pop bp
    ret
""",
"atoi": """
; (s) -> AX число (десятичное, со знаком; пробелы в начале пропускаются)
rt_atoi:
    push bp
    mov bp, sp
    push bx
    push cx
    push dx
    push si
    mov si, [bp + 4]
    xor bx, bx
    xor cx, cx
rt_atoi_sp:
    cmp byte [si], ' '
    jne rt_atoi_sg
    inc si
    jmp rt_atoi_sp
rt_atoi_sg:
    cmp byte [si], '-'
    jne rt_atoi_l
    inc si
    inc cx
rt_atoi_l:
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja rt_atoi_e
    xor ah, ah
    mov dx, ax
    mov ax, bx
    shl ax, 1
    shl ax, 1
    add ax, bx
    shl ax, 1
    add ax, dx
    mov bx, ax
    inc si
    jmp rt_atoi_l
rt_atoi_e:
    mov ax, bx
    test cx, cx
    jz rt_atoi_d
    neg ax
rt_atoi_d:
    pop si
    pop dx
    pop cx
    pop bx
    pop bp
    ret
""",
"skipsp": """
; AX строка -> AX без начальных пробелов
rt_skipsp:
    push bx
    mov bx, ax
rt_skipsp_l:
    cmp byte [bx], ' '
    jne rt_skipsp_d
    inc bx
    jmp rt_skipsp_l
rt_skipsp_d:
    mov ax, bx
    pop bx
    ret
""",
"input": """
; строка с клавиатуры (до 80 символов, Backspace, Enter) -> AX адрес rt_inbuf
rt_input:
    push bx
    push cx
    push si
    mov bx, rt_inbuf
    xor cx, cx
rt_input_l:
    mov ah, 3
    int 0x80
    cmp al, 13
    je rt_input_e
    cmp al, 8
    je rt_input_bs
    cmp al, 32
    jb rt_input_l
    cmp cx, 80
    jae rt_input_l
    mov [bx], al
    inc bx
    inc cx
    mov ah, 1
    int 0x80
    jmp rt_input_l
rt_input_bs:
    test cx, cx
    jz rt_input_l
    dec bx
    dec cx
    mov si, rt_input_bss
    mov ah, 2
    int 0x80
    jmp rt_input_l
rt_input_e:
    mov byte [bx], 0
    mov si, rt_input_nl
    mov ah, 2
    int 0x80
    mov ax, rt_inbuf
    pop si
    pop cx
    pop bx
    ret
rt_input_bss db 8, ' ', 8, 0
rt_input_nl db 13, 10, 0
""",
}

# ----------------------------------------------------------------- главная
def compile_source(src, name):
    toks = tokenize(src)
    prog = Parser(toks).parse_program()
    cg = CodeGen(name)
    return cg.compile(prog)

def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print("ferpy %s — компилятор Python-подобного языка в frasm\n"
              "использование: fpy.py prog.fpy [-o PROG.ASM]" % VERSION)
        return 2
    src_path = argv[1]
    out_path = None
    if "-o" in argv:
        out_path = argv[argv.index("-o") + 1]
    if out_path is None:
        base = os.path.splitext(os.path.basename(src_path))[0]
        out_path = os.path.join(os.path.dirname(src_path), base.upper()[:8] + ".ASM")
    with open(src_path, encoding="utf-8") as f:
        src = f.read()
    try:
        asm = compile_source(src, src_path)
    except CompileError as e:
        sys.stderr.write("%s:%d: ошибка: %s\n" % (src_path, e.line, e.msg))
        return 1
    with open(out_path, "w", encoding="cp866", errors="replace", newline="\r\n") as f:
        f.write(asm)
    print("%s -> %s (%d строк)" % (src_path, out_path, asm.count("\n")))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
