import SwiftUI
import SwiftData

struct MeetingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var searchText = ""
    @State private var meetingToDelete: Meeting?

    var filteredMeetings: [Meeting] {
        if searchText.isEmpty { return meetings }
        let query = searchText.lowercased()
        return meetings.filter {
            $0.title.lowercased().contains(query) ||
            $0.transcript.lowercased().contains(query) ||
            $0.notes.lowercased().contains(query) ||
            $0.userNotes.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if meetings.isEmpty {
                    emptyState
                } else {
                    meetingList
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $searchText, prompt: "Search meetings...")
        } detail: {
            if meetings.isEmpty {
                Text("No meeting selected")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a meeting to view details")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 350)
        .frame(minWidth: 800, minHeight: 500)
        .alert("Delete Meeting?", isPresented: Binding(
            get: { meetingToDelete != nil },
            set: { if !$0 { meetingToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { meetingToDelete = nil }
            Button("Delete", role: .destructive) {
                if let meeting = meetingToDelete {
                    modelContext.delete(meeting)
                    meetingToDelete = nil
                }
            }
        } message: {
            Text("This will permanently delete the meeting and its notes.")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Meetings Yet", systemImage: "person.2.wave.2")
        } description: {
            Text("Start a meeting from the menu bar to begin recording and transcribing.")
        }
    }

    // MARK: - Meeting List

    private var meetingList: some View {
        List {
            ForEach(filteredMeetings) { meeting in
                NavigationLink(value: meeting.id) {
                    MeetingRow(meeting: meeting)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        meetingToDelete = meeting
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    meetingToDelete = filteredMeetings[index]
                }
            }
        }
        .navigationDestination(for: UUID.self) { meetingID in
            if let meeting = meetings.first(where: { $0.id == meetingID }) {
                MeetingDetailView(meeting: meeting)
            }
        }
    }
}

// MARK: - Meeting Row

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                statusBadge
            }

            HStack {
                Text(meeting.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(meeting.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !meeting.bookmarks.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "bookmark.fill")
                        Text("\(meeting.bookmarks.count)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            if !meeting.notes.isEmpty {
                Text(meeting.notes.prefix(100).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .recording:
            Label("Recording", systemImage: "record.circle")
                .font(.caption2)
                .foregroundStyle(.red)
        case .transcribing:
            Label("Transcribing", systemImage: "waveform")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .generatingNotes:
            Label("Generating", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
