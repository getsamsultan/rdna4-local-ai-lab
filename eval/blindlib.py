"""Shared helpers: read prompts, rubric and the blind sheet."""
import json, pathlib, re
here = pathlib.Path(__file__).parent
def prompts():
    return {str(json.loads(l)["n"]): json.loads(l) for l in open(here / "prompts.jsonl")}
def rubric():
    out = {}
    for block in re.split(r"^## ", (here / "RUBRIC.md").read_text(), flags=re.M)[1:]:
        head, _, body = block.partition("\n"); out[head.split(".")[0].strip()] = body.strip()
    return out
def answers(sheet="blind-sheet.md"):
    out = {}
    for block in re.split(r"^## Answer ", (here / sheet).read_text(), flags=re.M)[1:]:
        label, _, body = block.partition("\n")
        out[label.strip()] = re.split(r"^# \d+\. ", body, flags=re.M)[0].strip()
    return out
