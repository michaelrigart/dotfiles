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
# Words a list item never contains: the weaken table, negations, copulas and auxiliaries.
FORBIDDEN = {"never", "not", "no", "must", "always", "only", "every", "is", "are", "be", "was", "were",
             "been", "being", "has", "have", "had", "does", "do", "did", "can", "cannot", "may", "might",
             "should", "shall", "will", "would", "could"}
# Words that end a list: prepositions and conjunctions that start what follows it.
STOP_WORDS = {"without", "in", "on", "of", "with", "for", "to", "at", "from", "by", "when", "unless",
              "until", "that", "which", "because", "if", "as", "before", "after", "but", "so", "except",
              "then", "than", "per", "via", "into", "onto", "over", "under", "about", "against", "within",
              "between", "through", "during", "while", "where", "whose", "who", "whom"}
# A clause that starts with one of these has a fronted subordinate clause or phrase: its first comma
# ends it, and what follows is the main clause.
SUBORDINATORS = {"if", "when", "whenever", "before", "after", "unless", "until", "while", "because", "since",
                 "once", "for", "as", "where", "although"}
MAX_DROPS = 4
MAX_ITEM_WORDS = 8

START_RE = re.compile(r"\s*(?:[-*+]|\d+[.)])\s|\s{0,3}#{1,6}\s|\s*\|")
SINGLE_RE = re.compile(r"\s{0,3}#{1,6}\s|\s*\|")
BULLET_RE = re.compile(r"(?:[-*+]|\d+[.)])\s+")
HEAD_RE = re.compile(r"#{1,6}\s+")
BOLD_RE = re.compile(r"\*\*[^*\n]+?\*\*[:.]?(?=\s|$)")
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


def bracket_depth(flat, code):
    """depth[i]: the bracket nesting before flat[i], brackets in backticks not counted."""
    out, d = [], 0
    for i, c in enumerate(flat):
        out.append(d)
        if not code[i]:
            if c in "([":
                d += 1
            elif c in ")]":
                d = max(0, d - 1)
    return out


def prefix_end(flat):
    """(content, protected): where a block's sentences start, and where its protected prefix ends.
    The prefix is the bullet or heading marker and a leading bold span, in a bullet, heading or
    paragraph. A bold span ending in . or : (inside or after the asterisks) is a label: the sentences
    start after it. Any other bold span is the lead of a sentence that goes on: the sentence starts
    at the bold span (its words can be weakened) but delete-sentence leaves the span."""
    m = BULLET_RE.match(flat) or HEAD_RE.match(flat)
    start = m.end() if m else 0
    bold = BOLD_RE.match(flat, start)
    if not bold:
        return start, start
    end = bold.end()
    close = flat.rfind("**", start + 2, end)
    is_label = (flat[start + 2:close].endswith((".", ":")) or flat[close + 2:end] in (":", ".")
                or end >= len(flat))
    skip = end
    while skip < len(flat) and flat[skip] == " ":
        skip += 1
    return (skip if is_label else start), skip


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


def locate_all(text, anchor):
    """[(block, flat, start, end, anchor_from, anchor_to)] for every block that holds the anchor in
    whitespace-flattened form, in document order."""
    wanted = " ".join(anchor.split())
    found = []
    if not wanted:
        return found
    for block in split_blocks(text):
        flat, start, end = flatten(block["text"])
        i = flat.find(wanted)
        if i >= 0:
            found.append((block, flat, start, end, i, i + len(wanted)))
    return found


def anchor_found(text, anchor):
    return bool(locate_all(text, anchor))


def words_of(flat, lo, hi):
    return [(lo + m.start(), lo + m.end()) for m in TOKEN_RE.finditer(flat[lo:hi])]


def word_key(flat, code, s, e):
    return None if code[s] else flat[s:e].strip("`*.,;:()[]\"'").lower()


def is_bad(flat, code, s, e):
    """A token an item never holds: a forbidden word, a table pipe."""
    return "|" in flat[s:e] or word_key(flat, code, s, e) in FORBIDDEN


def valid_item(flat, code, a, b):
    """An item is non-empty, short, balanced, and holds no forbidden word and no pipe."""
    if a >= b or any(is_bad(flat, code, s, e) for s, e in words_of(flat, a, b)):
        return False
    if len(words_of(flat, a, b)) > MAX_ITEM_WORDS or sum(1 for i in range(a, b) if flat[i] == "`") % 2:
        return False
    plain = [flat[i] for i in range(a, b) if not code[i]]
    return plain.count("(") == plain.count(")") and plain.count("[") == plain.count("]")


def trim_last(flat, code, a, b):
    """The last item of a list: the words from a up to the first forbidden or stop word or opening
    bracket, ending early after a backticked name. None when no word is left."""
    taken = []
    for s, e in words_of(flat, a, b):
        key = word_key(flat, code, s, e)
        if taken and (key in FORBIDDEN or key in STOP_WORDS or flat[s] == "("):
            break
        taken.append((s, e))
        if code[s]:
            break
    return (taken[0][0], taken[-1][1]) if taken else None


def parse_clause(flat, code, depth, ca, cb):
    """The item spans of the comma list in flat[ca:cb], 'none' when it is no list, 'unparsed' when
    it looks like one and cannot be read with confidence."""
    commas = [i for i in range(ca, cb - 1) if flat[i] == "," and flat[i + 1] == " " and depth[i] == 0
              and not code[i]]
    if not commas:
        return "none"
    first_word = words_of(flat, ca, cb)[:1]
    if first_word and word_key(flat, code, *first_word[0]) in SUBORDINATORS:
        return parse_clause(flat, code, depth, commas[0] + 2, cb)
    segs = list(zip([ca] + [c + 2 for c in commas], commas + [cb]))
    for j in range(1, len(segs)):
        if any(flat[i:i + 2] == ": " and depth[i] == 0 and not code[i] for i in range(*segs[j])):
            return parse_clause(flat, code, depth, segs[j][0], cb)
    ls, le = segs[-1]
    final_conj = (re.match(r"(?:or|and) ", flat[ls:le]) is not None
                  or any(not code[m.start()] and depth[m.start()] == 0 for m in CONJ_RE.finditer(flat, ls, le)))
    if len(segs) < (2 if final_conj else 3):
        return "none"
    items, stopped_at = [], len(segs)
    for k in range(1, len(segs)):
        s, e = segs[k]
        words = words_of(flat, s, e)
        key = word_key(flat, code, *words[0]) if words else None
        if key in STOP_WORDS or key in FORBIDDEN:
            stopped_at = k
            break
        if key in ("or", "and") and not code[words[0][0]]:
            tail = trim_last(flat, code, words[1][0], e) if len(words) > 1 else None
            if tail is None:
                return "unparsed"
            items.append(tail)
            stopped_at = k + 1
            break
        conj = next((m for m in CONJ_RE.finditer(flat, s, e) if not code[m.start()] and depth[m.start()] == 0), None)
        if conj:
            tail = trim_last(flat, code, conj.end() + 1, e) if conj.end() + 1 < e else None
            if tail is None or conj.start() - 1 <= s:
                return "unparsed"
            items += [(s, conj.start() - 1), tail]
            stopped_at = k + 1
            break
        items.append((s, e))
    if stopped_at < len(segs):
        rest = words_of(flat, *segs[stopped_at])
        lead = word_key(flat, code, *rest[0]) if rest else None
        if lead not in STOP_WORDS and lead not in FORBIDDEN:
            return "unparsed"
    elif items and stopped_at == len(segs):
        last = trim_last(flat, code, *items[-1])
        if last is None:
            return "unparsed"
        items[-1] = last
    if not items:
        return "none"
    fs, fe = segs[0]
    colon = max((i for i in range(fs, fe - 1) if flat[i:i + 2] == ": " and not code[i]), default=-1)
    if colon >= 0:
        first = (colon + 2, fe)
    else:
        walk, n_next = [], min(4, len(words_of(flat, *items[0])))
        for s, e in reversed(words_of(flat, fs, fe)):
            key = word_key(flat, code, s, e)
            if len(walk) >= n_next:
                break
            if key in SUBORDINATORS:
                return "unparsed"
            if key in FORBIDDEN or key in STOP_WORDS or flat[e - 1] == ":":
                break
            walk.append((s, e))
        if not walk:
            return "unparsed"
        first = (walk[-1][0], fe)
    items = [first] + items
    if not all(valid_item(flat, code, a, b) for a, b in items):
        return "unparsed"
    return items if len(items) >= 3 else "none"


def clause_lists(flat, code, lo, hi):
    """(lists, unparsed): the item spans of each comma list of three or more in flat[lo:hi], one list
    per `;`- or `|`-separated clause, and how many lists looked like lists but could not be read."""
    depth = bracket_depth(flat, code)
    end = hi
    while end > lo and flat[end - 1] in ".?!":
        end -= 1
    cuts, start = [], lo
    for i in range(lo, end):
        if depth[i] == 0 and not code[i] and (flat[i] == "|" or (flat[i] == ";" and i + 1 < end and flat[i + 1] == " ")):
            cuts.append((start, i))
            start = i + 1
    cuts.append((start, end))
    lists, unparsed = [], 0
    for ca, cb in cuts:
        while ca < cb and flat[ca] == " ":
            ca += 1
        while cb > ca and flat[cb - 1] == " ":
            cb -= 1
        got = parse_clause(flat, code, depth, ca, cb) if cb > ca else "none"
        if got == "unparsed":
            unparsed += 1
        elif got != "none":
            lists.append(got)
    return lists, unparsed


def spread(items, n):
    """At most n of the items, evenly spaced and in order."""
    if len(items) <= n:
        return items
    picks = sorted({round(i * (len(items) - 1) / (n - 1)) for i in range(n)})
    return [items[i] for i in picks]


def rule_plan(file, text, rule_id, anchor):
    """(mutants, info) for the rule `anchor` in `text`. info: found (the anchor is in a block),
    ambiguous (it is in several), unparsed (comma lists in scope that could not be read, which get no
    drop-item mutant). The sentences the anchor touches are in scope (all of the block's when the
    anchor is only its prefix): each is deleted in turn (a leading bold lead stays), each strength
    word of the table is weakened in turn, and at most four items of the lists are dropped."""
    matches = locate_all(text, anchor)
    info = {"found": bool(matches), "ambiguous": len(matches) > 1, "unparsed": 0}
    if len(matches) != 1:
        return [], info
    block, flat, start, end, a_from, a_to = matches[0]
    code = code_mask(flat)
    lo, protected = prefix_end(flat)
    sents = sentences(flat, code, lo)
    scope = sents if a_to <= protected else [s for s in sents if s[0] < a_to and s[1] > a_from]
    edits = []

    for sa, sb in scope:
        da = max(sa, protected)
        if da >= sb:
            continue
        if sb < len(flat):
            span = (da, sb + 1)
        elif da > 0 and flat[da - 1] == " ":
            span = (da - 1, sb)
        else:
            span = (da, sb)
        edits.append(("delete-sentence", flat[da:sb], span[0], span[1], ""))

    weaken = []
    for sa, sb in scope:
        for word, replacement in WEAKEN:
            for m in re.finditer(rf"(?<![\w-]){re.escape(word)}(?![\w-])", flat[sa:sb]):
                if not code[sa + m.start()]:
                    weaken.append(("weaken", word, sa + m.start(), sa + m.end(), replacement))
    edits += sorted(weaken, key=lambda e: e[2])

    drops = []
    for sa, sb in scope:
        lists, unparsed = clause_lists(flat, code, sa, sb)
        info["unparsed"] += unparsed
        for items in lists:
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
    return out, info


def rule_mutants(file, text, rule_id, anchor):
    """The mutants of rule_plan; [] when the anchor is missing or ambiguous."""
    return rule_plan(file, text, rule_id, anchor)[0]


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


def stray_call(line):
    """True when need, need_flat or need_in is an unquoted word of the line other than its first."""
    tokens, cur, quoted, quote, i, n = [], [], False, None, 0, len(line)

    def flush():
        nonlocal cur, quoted
        if cur or quoted:
            tokens.append(("".join(cur), quoted))
        cur, quoted = [], False

    while i < n:
        c = line[i]
        if quote:
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"':
                i += 1
            i += 1
            continue
        if c in "'\"":
            quote, quoted = c, True
        elif c == "\\":
            i += 1
            quoted = True
        elif c == "#" and not cur and not quoted:
            break
        elif c in " \t;&|(){}<>":
            flush()
        else:
            cur.append(c)
        i += 1
    flush()
    return any(text in ("need", "need_flat", "need_in") and not q for k, (text, q) in enumerate(tokens) if k > 0)


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
        if stray_call(line):
            raise PinError(number, "need, need_flat or need_in is not the first word of the line")
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
