"""Round 2 answer preparation: style stripping and length matching.

strip(text)  removes things that can reveal which model wrote an answer without changing its
             content: emoji, markdown headings / bold / horizontal rules, and chatty opening or
             closing lines ("Great question!", "Let me know if...", "Hope this helps").
             Code blocks are left exactly as written.
words(text)  word count used for length matching and length reporting.
trim(text, n) keeps the first n words. If that cuts inside a code block, the block is closed.
"""
import re

EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF\U00002B00-\U00002BFF"
    "\u2300-\u23FF\uFE0F\u200D]+")   # emoji and pictographs; arrows, maths and box-drawing are kept
CHATTY = re.compile(
    r"^\s*(?:"
    r"(?:great|good|excellent|nice) question\b.*"
    r"|(?:sure|certainly|absolutely|of course)[!.,].*"
    r"|let me know if\b.*|feel free to\b.*|hope (?:this|that) helps\b.*|happy to help\b.*"
    r"|if you (?:have|want|need) (?:any )?(?:more|further|other)\b.*"
    r"|would you like me to\b.*|want me to\b.*"
    r")$", re.I)
FENCE = re.compile(r"^\s*(```|~~~)")


def _blocks(text):
    """Yield (is_code, chunk) pieces, keeping fenced code blocks intact."""
    out, buf, code = [], [], False
    for line in text.split("\n"):
        if FENCE.match(line):
            if code:
                buf.append(line); out.append((True, "\n".join(buf))); buf = []; code = False
            else:
                if buf: out.append((False, "\n".join(buf)))
                buf = [line]; code = True
            continue
        buf.append(line)
    if buf: out.append((code, "\n".join(buf)))
    return out


def _strip_prose(chunk):
    lines = []
    for line in chunk.split("\n"):
        # ticks and crosses often carry the answer ("Fits? ❌"), so they become words, not blanks
        line = re.sub("[✅✔☑]️?", "yes", line)
        line = re.sub("[❌✖❎✗✘]️?", "no", line)
        line = EMOJI.sub("", line)
        if re.match(r"^\s*([-*_])\s*(\1\s*){2,}$", line):   # horizontal rule
            continue
        line = re.sub(r"^\s{0,3}#{1,6}\s+", "", line)        # heading marker -> plain line
        line = re.sub(r"\*\*(.+?)\*\*|__(.+?)__", lambda m: m.group(1) or m.group(2), line)  # bold
        if CHATTY.match(line):
            continue
        lines.append(line.rstrip())
    return "\n".join(lines)


def strip(text):
    parts = [c if is_code else _strip_prose(c) for is_code, c in _blocks(text or "")]
    text = "\n".join(parts)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def words(text):
    return len((text or "").split())


def trim(text, n):
    """First n words, keeping line breaks; closes a code fence left open by the cut."""
    if words(text) <= n:
        return text
    out, count = [], 0
    for line in text.split("\n"):
        w = line.split()
        if count + len(w) > n:
            keep = n - count
            if keep > 0:
                lead = line[: len(line) - len(line.lstrip())]
                out.append(lead + " ".join(w[:keep]))
            break
        out.append(line); count += len(w)
    res = "\n".join(out)
    if sum(1 for l in out if FENCE.match(l)) % 2:
        res += "\n```"
    return res
