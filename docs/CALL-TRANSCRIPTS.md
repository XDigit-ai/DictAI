# Call Transcripts

When Zoom, Teams, Meet or another call app starts, DictAI offers to transcribe the call on your Mac. The transcript is written live to a Markdown file, then replaced with a more accurate final version when the call ends.

Transcripts are saved in `~/Documents/DictAI Transcripts/` (change it in **Settings → Calls**), one file per call, named `YYYY-MM-DD HHMM <title>.md`. The title comes from your calendar when a meeting is on, otherwise from the call app.

Your side is labeled **You** and everyone else is **Them**. The text is cleaned but never reworded: filler sounds, stutters and speech engine artifacts are removed, nothing else. Long turns are split into paragraphs at pauses of 1.5 s or more, and at a sentence end once a paragraph passes about 600 characters.

## Notes

**Make Notes from Last Call** in the menu bar writes a summary, key points, decisions, action items and open questions to `<transcript name> Notes.md` next to the transcript, using the LLM chosen under **Settings → Enhancement**. **Settings → Calls → Make notes after each call** does this automatically once the final transcript is written. Long calls are summarised in parts and merged. The transcript itself is never changed.

## Reading transcripts from agents

- While a call is being transcribed, `_live.md` in the transcripts folder is a symlink to its file. It disappears when the call ends.
- The file starts with YAML front matter. Its `status` field moves through:
  - `live`: the call is in progress. Text is only ever appended at the end, so `tail -f` works.
  - `processing`: the call has ended and the final transcript is being made.
  - `final`: the file was replaced by the final version. Read it again in full.
  - `ended-live-only`: the final pass failed. The live text is the result.
- `channels: you` means the other side could not be recorded (check System Audio Recording permission).

