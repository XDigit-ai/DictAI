import Foundation
import EventKit

/// Read-only calendar access, used to title call transcripts after the meeting in progress.
@MainActor
final class CalendarIntegration {
    static let shared = CalendarIntegration()

    private let eventStore = EKEventStore()

    private init() {
        Task { await requestAccess() }
    }

    /// Asks for calendar access once. Titles fall back to the app name without it.
    func requestAccess() async {
        do {
            _ = try await eventStore.requestFullAccessToEvents()
        } catch {
            DebugLogger.log("Calendar access request failed: \(error)", subsystem: "Calls")
        }
    }

    /// Today's events sorted by start date. Empty without calendar access.
    func getTodayEvents() -> [EKEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
}
