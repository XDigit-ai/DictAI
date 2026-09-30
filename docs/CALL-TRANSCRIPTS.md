# Call Transcripts

When Zoom, Teams, Meet or another call app starts, DictAI offers to transcribe the call on your Mac. The transcript is written live to a Markdown file, then replaced with a more accurate final version when the call ends.

Transcripts are saved in `~/Documents/DictAI Transcripts/` (change it in **Settings → Calls**), one file per call, named `YYYY-MM-DD HHMM <title>.md`. The title comes from your calendar when a meeting is on, otherwise from the call app.

Your side is labeled **You** and everyone else is **Them**. The text is cleaned but never reworded: filler sounds, stutters and speech engine artifacts are removed, nothing else.

## Reading transcripts from agents

- While a call is being transcribed, `_live.md` in the transcripts folder is a symlink to its file. It disappears when the call ends.
- The file starts with YAML front matter. Its `status` field moves through:
  - `live`: the call is in progress. Text is only ever appended at the end, so `tail -f` works.
  - `processing`: the call has ended and the final transcript is being made.
  - `final`: the file was replaced by the final version. Read it again in full.
  - `ended-live-only`: the final pass failed. The live text is the result.
- `channels: you` means the other side could not be recorded (check System Audio Recording permission).

