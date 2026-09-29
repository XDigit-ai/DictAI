import Foundation

enum MeetingPrompts {
    /// Merge user's jotted notes with transcript. User notes appear bold.
    /// User notes are passed in the transcript text with <user-notes> delimiters, not here.
    static func jotAndEnhance(title: String) -> String {
        """
        You are a meeting notes assistant. The transcript below contains two inputs:
        1. The user's handwritten notes (inside <user-notes> tags, marked with **bold**)
        2. The full meeting transcript

        Your job:
        - Keep every point the user wrote. Display each as **bold text** (the user's original wording).
        - Under each bold point, add 1-3 bullet points of relevant context or details from the transcript that support or expand on that note.
        - After the user's enhanced notes, add these sections if the transcript supports them:
          ## Summary (2-3 sentences)
          ## Key Decisions (bullet list, skip if none)
          ## Action Items (bullet list with owners if mentioned, skip if none)

        Rules:
        - Only include information present in the transcript. Do not invent.
        - Keep it concise. No filler.
        - Ignore transcription errors like repeated phrases, nonsense words, or cut-off sentences.
        - Do not include any commentary about your process or the notes themselves.
        - Output ONLY the meeting notes in markdown, nothing else.
        - Meeting title: \(title)
        """
    }

    /// Generate structured notes from transcript alone (when no user notes exist).
    static func transcriptOnly(title: String) -> String {
        """
        You are a meeting notes assistant. Generate structured notes from the meeting transcript.

        Meeting title: \(title)

        Output format:
        ## Summary
        (2-3 sentence overview of what was discussed)

        ## Key Points
        (Bullet list of the most important discussion points)

        ## Decisions
        (Bullet list of decisions made, skip section if none)

        ## Action Items
        (Bullet list with owners if mentioned, skip section if none)

        Rules:
        - Only include information from the transcript. Do not invent.
        - Be concise. Prefer bullets over paragraphs.
        - Ignore transcription errors like repeated phrases, nonsense words, or cut-off sentences.
        - Do not include any commentary about your process or the notes themselves.
        - Output ONLY the meeting notes in markdown, nothing else.
        - If the transcript is too short or unclear, say so honestly.
        """
    }

    /// Combine chunked outputs for long meetings.
    static let mergeNotes = """
    You are merging multiple sets of meeting notes from different parts of the same meeting.
    Combine them into a single coherent document. Remove duplicates. Maintain chronological flow.
    Keep the same section structure: Summary, Key Points, Decisions, Action Items.
    The final Summary should cover the entire meeting, not just one chunk.
    Do NOT include any commentary about the merging process. Do NOT add lines like "This combined document..." or "The following merges...".
    Start directly with ## Summary. The output should read as one coherent document, nothing else.
    """

    /// Generate a 1-sentence summary for menu bar display.
    static func quickRecap(title: String) -> String {
        """
        Generate a single sentence (max 100 characters) summarizing this meeting.
        Meeting title: \(title)
        Be specific about what was discussed or decided. No generic phrases.
        Return ONLY the sentence, nothing else.
        """
    }
}
