# Claude Skill for the Gree bridge

A [Claude Skill](https://support.claude.com/en/articles/12512180-using-skills-in-claude) is a folder of instructions and files that Claude reads when they are relevant. This one helps you build, install and troubleshoot the bridge, and adapt it to another unit: finding the tap points safely, reading the Gree tools page (IR brand, bus speed detection), planning captures, and decoding them with its analysis script.

The skill itself is in [`.claude/skills/gree-bridge/`](../.claude/skills/gree-bridge/): `SKILL.md`, `references/` (copies of this repository's docs), `scripts/analyze_capture.py` and `assets/example_capture.txt`.

## Add it to Claude

- **Claude Code**: clone this repository and open the folder in Claude Code. The skill is loaded by itself (project skills live in `.claude/skills/`). Ask for example "help me install a Gree bridge board" or "decode this capture: gree_capture.txt".
- **Claude app** (web, desktop, mobile): download [`gree-bridge.zip`](gree-bridge.zip), then Settings → Capabilities → Skills → **Upload skill**. Custom skills need a paid plan (Pro, Max, Team or Enterprise) with code execution turned on. Then attach your capture file to a chat and ask.

The analysis script also works on its own, without Claude:

```
python3 .claude/skills/gree-bridge/scripts/analyze_capture.py gree_capture.txt
```

## Rebuild

After changing the docs or the skill: `python3 skill/build_skill.py` refreshes the reference copies and rebuilds the zip.
