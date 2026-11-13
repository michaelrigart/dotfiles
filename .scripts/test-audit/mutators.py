"""Code mutants for the test audit: shell (bash, zsh, sh) and Python. Stdlib only.

A Mutant is a dict: id, kind, file, op, line (1-based, informational), context (the original
line, or block), occurrence (index of context among identical contexts in the file), col and
before/after (the offset of `before` in `context`, and its replacement).
"""
import ast
import hashlib
import re
import subprocess
import warnings
from concurrent.futures import ThreadPoolExecutor

OPS = ("negate", "delete", "exit", "andor", "compare")
SHELLS = ("bash", "zsh", "sh")

KEYWORDS = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
            "esac", "in", "function", "select", "{", "}", "time", "coproc"}
HEREDOC_RE = re.compile(r"<<(?!<)(-?)[ \t]*(['\"\\]?)([A-Za-z_][A-Za-z0-9_]*)\2")
FUNC_HEADER_RE = re.compile(r"^[\w:.@+-]+\s*\(\s*\)")
CASE_ARM_RE = re.compile(r"^\(?[^\s()=]+(?:\|[^\s()=]+)*\)")
EXIT_RE = re.compile(r"(?<![\w$./-])(exit|return)(?:[ \t]+(\d+))?(?=[ \t]*(?:[;&|)}]|#|$))")
ANDOR_RE = re.compile(r"(?<![&|])(&&|\|\|)(?![&|])")
READ_COND_RE = re.compile(r"(?:[A-Za-z_][A-Za-z0-9_]*=\S*[ \t]+)*read\b")
NEGATE_RE = re.compile(r"(?<![\w$./-])(if|elif|while|until)(?=[ \t])[ \t]*")
BRACKET2_RE = re.compile(r"(?<![\w$\[])\[\[[ \t](.*?)[ \t]\]\](?![\w\]])")
BRACKET1_RE = re.compile(r"(?<![\w$\[])\[(?=[ \t])(.*?)(?<=[ \t])\](?![\w\]])")
ARITH_RE = re.compile(r"(?<![\w$(])\(\((.*?)\)\)")
TEST_WORDS = {"-eq": "-ne", "-ne": "-eq", "-lt": "-ge", "-ge": "-lt", "-gt": "-le", "-le": "-gt",
              "=": "!=", "==": "!=", "!=": "=", "-z": "-n", "-n": "-z"}
ARITH_OPS = {"<": ">=", ">=": "<", ">": "<=", "<=": ">", "==": "!=", "!=": "=="}
ARITH_TOKEN_RE = re.compile(r"<<=?|>>=?|<=|>=|==|!=|<|>")


def make_mutant(kind, file, op, context, occurrence, col, before, after, line):
    key = "\0".join([kind, file, op, context, str(occurrence), str(col), before, after])
    return {"id": hashlib.sha1(key.encode()).hexdigest()[:12], "kind": kind, "file": file,
            "op": op, "line": line, "context": context, "occurrence": occurrence,
            "col": col, "before": before, "after": after}


def find_block(text, context, occurrence):
    """Offset of the occurrence-th line-aligned copy of context in text, or -1."""
    start, seen = 0, 0
    while True:
        i = text.find(context, start)
        if i < 0:
            return -1
        end = i + len(context)
        if (i == 0 or text[i - 1] == "\n") and (end == len(text) or text[end] == "\n"):
            if seen == occurrence:
                return i
            seen += 1
        start = i + 1


def apply(text, mutant):
    """The mutated text, or None when the context or the `before` text is gone (stale)."""
    i = find_block(text, mutant["context"], mutant["occurrence"])
    if i < 0:
        return None
    at = i + mutant["col"]
    if text[at:at + len(mutant["before"])] != mutant["before"]:
        return None
    return text[:at] + mutant["after"] + text[at + len(mutant["before"]):]


def occurrence_of(text, context, offset):
    """Index of the block at `offset` among the line-aligned copies of context."""
    n = 0
    while True:
        i = find_block(text, context, n)
        if i < 0 or i >= offset:
            return n if i == offset else -1
        n += 1


def lex_line(line, quote):
    """(mask, comment_index, quote at end): mask[i] is True inside quotes or after a backslash."""
    n = len(line)
    mask = [quote is not None] * n
    i = 0
    while i < n:
        c = line[i]
        if quote is None:
            if c == "\\":
                mask[i] = True
                if i + 1 < n:
                    mask[i + 1] = True
                i += 2
                continue
            if c in "'\"":
                quote = c
                mask[i] = True
            elif c == "#" and (i == 0 or line[i - 1].isspace()):
                return mask, i, None
        else:
            mask[i] = True
            if c == "\\" and quote == '"' and i + 1 < n:
                mask[i + 1] = True
                i += 2
                continue
            if c == quote:
                quote = None
        i += 1
    return mask, n, quote


def shell_lines(lines):
    """Per line: None when it is a comment, a heredoc body or inside a multi-line string, else
    (mask, comment_index, opens_heredoc, quote_open_at_end). A quote left open at the end of
    the file means the lexer lost track, so the lines are then lexed one by one."""
    for carry in (True, False):
        out, quote, heredocs = [], None, []
        for line in lines:
            if heredocs:
                delim, strip = heredocs[0]
                if (line.lstrip("\t") if strip else line) == delim:
                    heredocs.pop(0)
                out.append(None)
                continue
            mask, comment, end_quote = lex_line(line, quote)
            if quote is not None or line.strip().startswith("#"):
                out.append(None)
                quote = end_quote if carry else None
                continue
            opened = False
            if "((" not in line:
                for m in HEREDOC_RE.finditer(line):
                    if m.start() < comment and not mask[m.start()]:
                        heredocs.append((m.group(3), m.group(1) == "-"))
                        opened = True
            out.append((mask, comment, opened, end_quote is not None))
            quote = end_quote if carry else None
        if quote is None and not heredocs:
            return out
    return out


def command_position(line, idx):
    prefix = line[:idx].rstrip()
    if not prefix or prefix[-1] in ";&|({":
        return True
    if re.search(r"(?:^|[\s;&|({])(?:then|else|do)$", prefix):
        return True
    return bool(CASE_ARM_RE.fullmatch(prefix.strip()))


def shell_candidates(lines):
    """(line index, op, col, before, after) for every syntactic candidate, unchecked."""
    info = shell_lines(lines)
    out = []
    for n, line in enumerate(lines):
        if info[n] is None:
            continue
        mask, comment, heredoc, open_quote = info[n]
        code = line[:comment]
        for m in NEGATE_RE.finditer(code):
            if mask[m.start()] or not command_position(code, m.start()):
                continue
            kw, rest = m.group(1), code[m.end():]
            if kw in ("while", "until") and READ_COND_RE.match(rest):
                continue
            if rest.startswith("! "):
                out.append((n, "negate", m.start(), line[m.start():m.end() + 2], kw + " "))
            else:
                out.append((n, "negate", m.start(), line[m.start():m.end()], kw + " ! "))
        stripped = code.strip()
        if stripped:
            lead = len(line) - len(line.lstrip())
            if deletable(lines, info, n, line, stripped, heredoc, open_quote):
                out.append((n, "delete", lead, line[lead:], ":"))
        for m in EXIT_RE.finditer(code):
            if mask[m.start()] or not command_position(code, m.start()):
                continue
            kw, num = m.group(1), m.group(2)
            new = "0" if num not in (None, "0") else "1"
            out.append((n, "exit", m.start(), m.group(0), f"{kw} {new}"))
        for m in ANDOR_RE.finditer(code):
            if not mask[m.start()]:
                out.append((n, "andor", m.start(), m.group(1), "||" if m.group(1) == "&&" else "&&"))
        out.extend((n, "compare", *c) for c in compare_candidates(code, mask))
    return out


def deletable(lines, info, n, line, stripped, heredoc, open_quote):
    if heredoc or open_quote or stripped == ":":
        return False
    first = re.match(r"[^\s;|&()<>]*", stripped).group(0)
    if first in KEYWORDS or stripped[0] in "}){" or stripped.startswith((";;", ";&", "&&", "||", "|")):
        return False
    if FUNC_HEADER_RE.match(stripped) or CASE_ARM_RE.match(stripped):
        return False
    if re.search(r"(\\|&&|\|\||\||\{|\(|;;|\bthen|\bdo|\belse)$", stripped):
        return False
    if n > 0 and info[n - 1] is not None:
        before = lines[n - 1].rstrip()
        if re.search(r"(\\|&&|\|\||\|)$", before):
            return False
    return True


def compare_candidates(code, mask):
    out = []
    taken = []
    for regex, kind in ((BRACKET2_RE, "[["), (BRACKET1_RE, "["), (ARITH_RE, "((")):
        for m in regex.finditer(code):
            if mask[m.start()] or any(a <= m.start() < b for a, b in taken):
                continue
            taken.append((m.start(), m.end()))
            body, base = m.group(1), m.start(1)
            if kind == "((":
                for t in ARITH_TOKEN_RE.finditer(body):
                    if t.group(0) in ARITH_OPS and not mask[base + t.start()]:
                        out.append((base + t.start(), t.group(0), ARITH_OPS[t.group(0)]))
            else:
                for t in re.finditer(r"\S+", body):
                    if t.group(0) in TEST_WORDS and not mask[base + t.start()]:
                        out.append((base + t.start(), t.group(0), TEST_WORDS[t.group(0)]))
    return out


def syntax_ok(lang, text):
    try:
        if lang == "py":
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                compile(text, "<mutant>", "exec")
            return True
        cmd = {"bash": ["bash", "-n"], "zsh": ["zsh", "-f", "-n"], "sh": ["sh", "-n"]}[lang]
        return subprocess.run(cmd, input=text.encode(), capture_output=True, timeout=30).returncode == 0
    except (SyntaxError, ValueError, subprocess.TimeoutExpired):
        return False


def python_candidates(text, lines):
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(text)
    except SyntaxError:
        return []
    out = []

    def span(node):
        """(line index, start col, end col) in characters, for a one-line node."""
        if getattr(node, "end_lineno", None) != node.lineno:
            return None
        line = lines[node.lineno - 1]
        lo = len(line.encode()[:node.col_offset].decode(errors="ignore"))
        hi = len(line.encode()[:node.end_col_offset].decode(errors="ignore"))
        return node.lineno - 1, lo, hi

    per_line = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.stmt):
            per_line[node.lineno] = per_line.get(node.lineno, 0) + 1
    simple = (ast.Expr, ast.Assign, ast.AugAssign, ast.AnnAssign, ast.Delete, ast.Raise, ast.Assert,
              ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal, ast.Return, ast.Break, ast.Continue)
    for node in ast.walk(tree):
        if isinstance(node, (ast.If, ast.While)):
            s = span(node.test)
            if s:
                n, lo, hi = s
                src = lines[n][lo:hi]
                out.append((n, "negate", lo, src, f"not ({src})"))
        if isinstance(node, simple) and per_line.get(node.lineno) == 1 and node.end_lineno == node.lineno:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                pass
            else:
                n = node.lineno - 1
                lead = len(lines[n]) - len(lines[n].lstrip())
                out.append((n, "delete", lead, lines[n][lead:], "pass"))
        if isinstance(node, ast.Return) and isinstance(node.value, ast.Constant):
            v, s = node.value.value, span(node)
            if s and (isinstance(v, bool) or v in (0, 1) and isinstance(v, int)):
                n, lo, hi = s
                src = lines[n][lo:hi]
                new = "return " + ("False" if v is True else "True" if v is False else str(1 - v))
                out.append((n, "exit", lo, src, new))
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "exit"
                and isinstance(node.func.value, ast.Name) and node.func.value.id == "sys"
                and len(node.args) == 1 and isinstance(node.args[0], ast.Constant)
                and type(node.args[0].value) is int and node.args[0].value in (0, 1)):
            s = span(node)
            if s:
                n, lo, hi = s
                out.append((n, "exit", lo, lines[n][lo:hi], f"sys.exit({1 - node.args[0].value})"))
        if isinstance(node, ast.BoolOp):
            word, other = ("and", "or") if isinstance(node.op, ast.And) else ("or", "and")
            for a, b in zip(node.values, node.values[1:]):
                gap = gap_between(lines, a, b)
                m = gap and re.search(rf"\b{word}\b", gap[0])
                if m:
                    out.append((gap[1], "andor", gap[2] + m.start(), word, other))
        if isinstance(node, ast.Compare):
            operands = [node.left, *node.comparators]
            for op, a, b in zip(node.ops, operands, operands[1:]):
                gap = gap_between(lines, a, b)
                rule = COMPARE_PY.get(type(op))
                m = gap and rule and re.search(rule[0], gap[0])
                if m:
                    out.append((gap[1], "compare", gap[2] + m.start(), m.group(0), rule[1]))
    return [c for c in out if lines[c[0]][c[2]:c[2] + len(c[3])] == c[3]]


COMPARE_PY = {
    ast.Eq: (r"==", "!="), ast.NotEq: (r"!=", "=="), ast.Lt: (r"<(?!=)", ">="),
    ast.LtE: (r"<=", ">"), ast.Gt: (r">(?!=)", "<="), ast.GtE: (r">=", "<"),
    ast.In: (r"\bin\b", "not in"), ast.NotIn: (r"\bnot\s+in\b", "in"),
    ast.Is: (r"\bis\b(?!\s+not)", "is not"), ast.IsNot: (r"\bis\s+not\b", "is"),
}


def gap_between(lines, a, b):
    """(text between two one-line operands, line index, column of the gap) or None."""
    if a.end_lineno != b.lineno:
        return None
    line = lines[b.lineno - 1]
    lo = len(line.encode()[:a.end_col_offset].decode(errors="ignore"))
    hi = len(line.encode()[:b.col_offset].decode(errors="ignore"))
    return line[lo:hi], b.lineno - 1, lo


def code_mutants(file, text, lang):
    """Every valid code mutant of text, ordered by line, column and operator."""
    if lang not in SHELLS and lang != "py":
        return []
    if not syntax_ok(lang, text):
        return []
    lines = text.split("\n")
    raw = python_candidates(text, lines) if lang == "py" else shell_candidates(lines)
    seen, cands = set(), []
    for n, op, col, before, after in sorted(raw, key=lambda c: (c[0], c[2], OPS.index(c[1]))):
        key = (n, op, col, before, after)
        if key in seen or before == after:
            continue
        seen.add(key)
        mutated = lines[n][:col] + after + lines[n][col + len(before):]
        cands.append((n, op, col, before, after, "\n".join(lines[:n] + [mutated] + lines[n + 1:])))
    with ThreadPoolExecutor(max_workers=8) as pool:
        valid = list(pool.map(lambda c: syntax_ok(lang, c[5]), cands))
    rows = []
    seen_lines, occurrence = {}, []
    for line in lines:
        occurrence.append(seen_lines.get(line, 0))
        seen_lines[line] = seen_lines.get(line, 0) + 1
    for (n, op, col, before, after, _), ok in zip(cands, valid):
        if ok:
            rows.append(make_mutant("code", file, op, lines[n], occurrence[n], col, before, after, n + 1))
    return rows


def targeted_mutant(file, text, find, replace, line=None):
    """(mutant, count): the targeted mutant for a find that occurs exactly once in text, or exactly
    once on the 1-based `line` when given. mutant is None when count is not 1."""
    starts, at = [], text.find(find) if find else -1
    while at >= 0:
        starts.append(at)
        at = text.find(find, at + 1)
    if line is not None:
        starts = [i for i in starts if text.count("\n", 0, i) + 1 == line]
    if len(starts) != 1:
        return None, len(starts)
    pos = starts[0]
    lo = text.rfind("\n", 0, pos) + 1
    hi = text.find("\n", pos + len(find))
    hi = len(text) if hi < 0 else hi
    context = text[lo:hi]
    return make_mutant("targeted", file, "targeted", context, occurrence_of(text, context, lo),
                       pos - lo, find, replace, text.count("\n", 0, pos) + 1), 1
