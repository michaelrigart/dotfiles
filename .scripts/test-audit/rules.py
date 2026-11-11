"""Rule mutants and pin extraction for the test audit. Stdlib only.

A rule is a pinned piece of prose (an anchor). Its mutants weaken or delete the sentences the
anchor touches, inside the block (bullet or paragraph) that holds it. A Mutant is the dict of
mutators.make_mutant, with `context` the block's original text (whole lines), so mutators.apply
works on it, plus `rule` and `item` (the removed sentence, word or list item).
"""
import hashlib
import re

import mutators

WEAKEN = (("Never", "Prefer not to"), ("never", "preferably not"), ("must", "should"),
          ("Must", "Should"), ("always", "usually"), ("Always", "Usually"), ("only", "mostly"),
          ("Every", "Most"), ("every", "most"))
STOP_WORDS = {"without", "in", "on", "of", "with", "for", "to", "at", "from", "by", "when", "unless",
              "until", "that", "which", "because", "if", "as", "before", "after", "but", "so"}
MAX_DROPS = 4

START_RE = re.compile(r"\s*(?:[-*+]|\d+[.)])\s|\s{0,3}#{1,6}\s|\s*\|")
SINGLE_RE = re.compile(r"\s{0,3}#{1,6}\s|\s*\|")
BULLET_RE = re.compile(r"(?:[-*+]|\d+[.)])\s+")
HEAD_RE = re.compile(r"#{1,6}\s+")
LABEL_RE = re.compile(r"\*\*[^*]+?[.:]\*\*:?(?=\s|$)")
TOKEN_RE = re.compile(r"`[^`]*`\S*|\S+")
CONJ_RE = re.compile(r"(?<=\s)(?:or|and)(?=\s)")


def split_blocks(text):
    """Bullets, paragraphs, headings and table rows: dicts of offset, line, text, kind. A bullet or
    paragraph takes the following non-blank, non-marker lines; a heading or table row is alone."""
    blocks, cur, pos = [], None, 0
    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            cur = None
        elif cur is not None and cur["kind"] == "text" and not START_RE.match(line):
            cur["text"] += "\n" + line
        else:
            cur = {"offset": pos, "line": number, "text": line,
                   "kind": "single" if SINGLE_RE.match(line) else "text"}
            blocks.append(cur)
        pos += len(line) + 1
    return blocks


def flatten(s):
    """(flat, start, end): whitespace runs collapsed to one space, edges trimmed; start[i] and end[i]
    are the original span of flat[i] (a space covers its whole run)."""
    chars, start, end = [], [], []
    i, n = 0, len(s)
    while i < n:
        if s[i].isspace():
            j = i
            while j < n and s[j].isspace():
                j += 1
            if chars:
                chars.append(" ")
                start.append(i)
                end.append(j)
            i = j
        else:
            chars.append(s[i])
            start.append(i)
            end.append(i + 1)
            i += 1
    if chars and chars[-1] == " ":
        chars.pop()
        start.pop()
        end.pop()
    return "".join(chars), start, end


def code_mask(flat):
    mask, inside = [], False
    for c in flat:
        if c == "`":
            inside = not inside
            mask.append(True)
        else:
            mask.append(inside)
    return mask


def prefix_end(flat):
    """Offset where a block's content starts: after the bullet or heading marker and a leading bold
    label such as `**Sizing.**`. The prefix is never mutated."""
    m = BULLET_RE.match(flat) or HEAD_RE.match(flat)
    if not m:
        return 0
    end = m.end()
    label = LABEL_RE.match(flat, end)
    if label:
        end = label.end()
    while end < len(flat) and flat[end] == " ":
        end += 1
    return end


def sentences(flat, code, lo):
    """(start, end) spans of the sentences from lo on. A sentence ends at . ? or ! followed by
    whitespace (closing quotes and brackets allowed between), outside backticks."""
    out, start, i, n = [], lo, lo, len(flat)
    while i < n:
        if flat[i] in ".?!" and not code[i] and not flat[:i + 1].endswith(("e.g.", "i.e.")):
            j = i + 1
            while j < n and flat[j] in "\"')]":
                j += 1
            if j == n or flat[j] == " ":
                out.append((start, j))
                start = i = j + 1
                continue
        i += 1
    if start < n:
        out.append((start, n))
    return out


def locate(text, anchor):
    """(block, flat, start, end, anchor_from, anchor_to) for the first block that holds the anchor in
    whitespace-flattened form, or None."""
    wanted = " ".join(anchor.split())
    if not wanted:
        return None
    for block in split_blocks(text):
        flat, start, end = flatten(block["text"])
        i = flat.find(wanted)
        if i >= 0:
            return block, flat, start, end, i, i + len(wanted)
    return None


def anchor_found(text, anchor):
    return locate(text, anchor) is not None


def words_of(flat, lo, hi):
    return [(lo + m.start(), lo + m.end()) for m in TOKEN_RE.finditer(flat[lo:hi])]


def clause_lists(flat, code, lo, hi):
    """Item spans (start, end) of each comma list of three or more in flat[lo:hi], one list per
    `;`-separated clause. The first item is what follows the last colon or opening bracket of the
    first segment, else as many trailing words as the next item has; a last item after a bare
    `or`/`and` is the words up to the first preposition or conjunction."""
    cuts, start = [], lo
    for i in range(lo, hi - 1):
        if flat[i] == ";" and not code[i] and flat[i + 1] == " ":
            cuts.append((start, i))
            start = i + 2
    cuts.append((start, hi))
    lists = []
    for ca, cb in cuts:
        while cb > ca and flat[cb - 1] in ".?!":
            cb -= 1
        depth, commas = 0, []
        for i in range(ca, cb):
            if code[i]:
                continue
            if flat[i] in "([":
                depth += 1
            elif flat[i] in ")]":
                depth = max(0, depth - 1)
            elif flat[i] == "," and depth == 0 and i + 1 < cb and flat[i + 1] == " ":
                commas.append(i)
        segs = list(zip([ca] + [c + 2 for c in commas], commas + [cb]))
        if len(segs) < 2:
            continue
        ls, le = segs[-1]
        oxford = re.match(r"(?:or|and) ", flat[ls:le])
        if oxford:
            tail = [(ls + oxford.end(), le)]
        else:
            conj = next((m for m in CONJ_RE.finditer(flat, ls, le) if not code[m.start()]), None)
            if conj:
                words = words_of(flat, conj.end() + 1, le)
                taken = []
                for ws, we in words:
                    if taken and flat[ws:we].lower() in STOP_WORDS:
                        break
                    taken.append((ws, we))
                tail = [(ls, conj.start() - 1), (words[0][0], taken[-1][1])] if taken else []
            else:
                tail = [(ls, le)]
        items_after_first = segs[1:-1] + tail
        if not items_after_first or not tail:
            continue
        fs, fe = segs[0]
        colon = max((i for i in range(fs, fe - 1) if flat[i:i + 2] == ": " and not code[i]), default=-1)
        bracket = max((i for i in range(fs, fe) if flat[i] == "(" and not code[i]), default=-1)
        if max(colon, bracket) >= 0:
            first_start = colon + 2 if colon > bracket else bracket + 1
        else:
            words = words_of(flat, fs, fe)
            if not words:
                continue
            n_next = len(words_of(flat, *items_after_first[0]))
            n = max(1, min(n_next, len(words) - 1 if len(words) > 1 else 1))
            first_start = words[-n][0]
        if first_start >= fe:
            continue
        items = [(first_start, fe)] + items_after_first
        if len(items) >= 3 and all(a < b for a, b in items):
            lists.append(items)
    return lists


def spread(items, n):
    """At most n of the items, evenly spaced and in order."""
    if len(items) <= n:
        return items
    picks = sorted({round(i * (len(items) - 1) / (n - 1)) for i in range(n)})
    return [items[i] for i in picks]


def rule_mutants(file, text, rule_id, anchor):
    """Every rule mutant of the rule `anchor` in `text`, in document order; [] when the anchor is not
    found (see anchor_found). The sentences the anchor touches are in scope (all of the block's when
    the anchor is only its label): each is deleted in turn, each strength word of the table is
    weakened in turn, and at most four items of the lists of three or more are dropped."""
    found = locate(text, anchor)
    if found is None:
        return []
    block, flat, start, end, a_from, a_to = found
    code = code_mask(flat)
    lo = prefix_end(flat)
    sents = sentences(flat, code, lo)
    scope = sents if a_to <= lo else [s for s in sents if s[0] < a_to and s[1] > a_from]
    edits = []

    for sa, sb in scope:
        if sb < len(flat):
            span = (sa, sb + 1)
        elif sa > 0 and flat[sa - 1] == " ":
            span = (sa - 1, sb)
        else:
            span = (sa, sb)
        edits.append(("delete-sentence", flat[sa:sb], span[0], span[1], ""))

    weaken = []
    for sa, sb in scope:
        for word, replacement in WEAKEN:
            for m in re.finditer(rf"(?<![\w-]){re.escape(word)}(?![\w-])", flat[sa:sb]):
                if not code[sa + m.start()]:
                    weaken.append(("weaken", word, sa + m.start(), sa + m.end(), replacement))
    edits += sorted(weaken, key=lambda e: e[2])

    drops = []
    for sa, sb in scope:
        for items in clause_lists(flat, code, sa, sb):
            for k, (a, b) in enumerate(items):
                span = (a, items[1][0]) if k == 0 else (items[k - 1][1], b)
                drops.append(("drop-item", flat[a:b], span[0], span[1], ""))
    edits += spread(drops, MAX_DROPS)

    out, seen = [], set()
    for op, item, a, b, after in edits:
        s, e = start[a], end[b - 1]
        key = (op, s, e, after)
        before = block["text"][s:e]
        if key in seen or before == after:
            continue
        seen.add(key)
        context = block["text"]
        m = mutators.make_mutant("rule", file, op, context, mutators.occurrence_of(text, context, block["offset"]),
                                 s, before, after, block["line"] + context.count("\n", 0, s))
        m["rule"], m["item"] = rule_id, item
        m["id"] = hashlib.sha1((m["id"] + "\0" + rule_id).encode()).hexdigest()[:12]
        out.append(m)
    return out


class Unresolved(Exception):
    pass


class PinError(Exception):
    def __init__(self, line, message):
        super().__init__(f"line {line}: {message}")


NEED_RE = re.compile(r"\s*(need|need_flat|need_in)(?=\s)")
ASSIGN_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
VAR_RE = re.compile(r"\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})")


def expand(src, i, env):
    m = VAR_RE.match(src, i)
    if not m:
        raise Unresolved(f"cannot expand {src[i:i + 12]!r}")
    name = m.group(1) or m.group(2)
    if name not in env:
        raise Unresolved(f"${name} is not set")
    if env[name] is None:
        raise Unresolved(f"${name} has no static value")
    return env[name], m.end()


def shell_words(src, env):
    """The words of one shell command line, with quotes removed and $NAME or ${NAME} taken from env.
    Raises Unresolved on a command substitution, an unset or dynamic variable, or an operator."""
    words, cur, have, i, n = [], [], False, 0, len(src)
    while i < n:
        c = src[i]
        if c in " \t":
            if have:
                words.append("".join(cur))
                cur, have = [], False
            i += 1
        elif c == "#" and not have:
            break
        elif c == "'":
            j = src.find("'", i + 1)
            if j < 0:
                raise Unresolved("unterminated quote")
            cur.append(src[i + 1:j])
            have, i = True, j + 1
        elif c == '"':
            have, i = True, i + 1
            while True:
                if i >= n:
                    raise Unresolved("unterminated quote")
                d = src[i]
                if d == '"':
                    i += 1
                    break
                if d == "\\" and i + 1 < n and src[i + 1] in '$`"\\':
                    cur.append(src[i + 1])
                    i += 2
                elif d == "$":
                    value, i = expand(src, i, env)
                    cur.append(value)
                elif d == "`":
                    raise Unresolved("command substitution")
                else:
                    cur.append(d)
                    i += 1
        elif c == "\\":
            if i + 1 < n:
                cur.append(src[i + 1])
            have, i = True, i + 2
        elif c == "$":
            value, i = expand(src, i, env)
            cur.append(value)
            have = True
        elif c == "`" or c in ";&|<>()":
            raise Unresolved(f"unsupported {c!r}")
        else:
            cur.append(c)
            have, i = True, i + 1
    if have:
        words.append("".join(cur))
    return words


def logical_lines(text):
    """(first physical line number, text) with backslash-newline continuations joined."""
    lines, i = text.split("\n"), 0
    while i < len(lines):
        first, cur = i + 1, lines[i]
        while (len(cur) - len(cur.rstrip("\\"))) % 2 == 1 and i + 1 < len(lines):
            i += 1
            cur = cur[:-1] + lines[i]
        yield first, cur
        i += 1


def pins(text):
    """Rows (id, file, anchor, safety, terms, note) for each need, need_flat or need_in call in a suite.
    Raises PinError naming the line of a call whose arguments cannot be resolved."""
    env, rows = {}, []
    for number, line in logical_lines(text):
        assign = ASSIGN_RE.match(line)
        if assign:
            try:
                words = shell_words(assign.group(2), env)
                env[assign.group(1)] = words[0] if len(words) == 1 else ("" if not words else None)
            except Unresolved:
                env[assign.group(1)] = None
            continue
        call = NEED_RE.match(line)
        if not call:
            continue
        try:
            words = shell_words(line, env)
        except Unresolved as err:
            raise PinError(number, f"{call.group(1)} argument cannot be resolved: {err}")
        if len(words) != 4:
            raise PinError(number, f"{call.group(1)} wants 3 arguments, got {len(words) - 1}")
        kind, where, anchor, label = words
        path = where if kind == "need_in" else f".chezmoitemplates/agents/{where}"
        if not anchor.strip():
            raise PinError(number, "empty anchor")
        for field in (path, anchor, label):
            if "\t" in field or "\n" in field:
                raise PinError(number, "a tab or newline in a pin cannot be written to a TSV")
        rows.append((f"p{number}", path, anchor, "?", "-", label))
    return rows
