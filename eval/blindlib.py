"""Shared helpers: read prompts, rubric and the blind sheet.

The blind sheet is split only on the exact headers blind.py writes ("# <n>. <prompt id>" and
"## Answer <n><letter>"), so headings inside a model's answer can't truncate it."""
import json, pathlib, re
here = pathlib.Path(__file__).parent
def prompts():
    return {str(json.loads(l)["n"]): json.loads(l) for l in open(here / "prompts.jsonl")}
def rubric():
    out = {}
    for block in re.split(r"^## (?=\d+\. `)", (here / "RUBRIC.md").read_text(), flags=re.M)[1:]:
        head, _, body = block.partition("\n"); out[head.split(".")[0].strip()] = body.strip()
    return out
def answers(sheet="blind-sheet.md"):
    P = prompts(); text = (here / sheet).read_text()
    heads = "|".join(re.escape(f"# {n}. {p['id']}") for n, p in P.items())
    labels = "|".join(rf"{n}[XYZWVU]" for n in P)
    marks = list(re.finditer(rf"^(?:(?P<q>{heads})|## Answer (?P<a>{labels}))[ \t]*$", text, flags=re.M))
    out = {}
    for i, m in enumerate(marks):
        if m.group("a"):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
            body = text[m.end():end].strip()
            # drop the prompt quote that follows a question header (only present before the first answer)
            out[m.group("a")] = body
    return out
