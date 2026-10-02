import Testing
import Foundation
import EventKit
@testable import DictAI

@MainActor
struct MeetingTitleTests {
    let store = EKEventStore()
    let now = sampleStart

    func event(_ title: String?, startsIn minutes: Double, lasts duration: Double = 30) -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = now.addingTimeInterval(minutes * 60)
        e.endDate = e.startDate.addingTimeInterval(duration * 60)
        return e
    }

    @Test func prefersTheMeetingHappeningNow() {
        let title = CallSession.meetingTitle(
            from: [event("Next up", startsIn: 3), event("Weekly sync", startsIn: -10)], now: now)
        #expect(title == "Weekly sync")
    }

    @Test func usesAMeetingStartingWithinFiveMinutes() {
        #expect(CallSession.meetingTitle(from: [event("Standup", startsIn: 4)], now: now) == "Standup")
        #expect(CallSession.meetingTitle(from: [event("Later", startsIn: 10)], now: now) == nil)
    }

    @Test func ignoresUntitledAndFinishedMeetings() {
        #expect(CallSession.meetingTitle(from: [event("", startsIn: -5)], now: now) == nil)
        #expect(CallSession.meetingTitle(from: [event("Done", startsIn: -60, lasts: 30)], now: now) == nil)
        #expect(CallSession.meetingTitle(from: [], now: now) == nil)
    }
}
