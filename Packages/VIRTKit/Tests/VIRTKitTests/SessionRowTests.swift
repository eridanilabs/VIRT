import AgentHostProtocol
import Testing
@testable import VIRTKit

func summary(_ resource: String = "ahp-session:/one", title: String = "A session", status: UInt32 = 1,
             folders: [String]? = nil, modifiedAt: String = "2025-03-10T18:42:03.123Z") -> SessionSummary {
    SessionSummary(provider: "copilot", title: title, status: SessionStatus(rawValue: status),
                   workingDirectories: folders, resource: resource,
                   createdAt: "2025-03-10T18:00:00Z", modifiedAt: modifiedAt)
}

struct SessionRowTests {
    @Test(arguments: [
        (UInt32(2 | 24), SessionRow.State.failed),
        (2, .failed),
        (24, .waitingForInput),
        (24 | 32, .waitingForInput),
        (8, .working),
        (0, .idle),
        (1, .idle),
        (32, .idle),
        (128, .idle),
    ])
    func stateFollowsTheStatusBits(status: UInt32, state: SessionRow.State) {
        #expect(SessionRow(summary: summary(status: status)).state == state)
    }

    @Test func stateNames() {
        #expect([SessionRow.State.failed, .waitingForInput, .working, .idle].map(\.rawValue)
            == ["Failed", "Waiting for input", "Working", "Idle"])
    }

    @Test(arguments: [
        (["/Users/me/repo", "/tmp"], "/Users/me/repo"),
        ([], nil),
        (nil, nil),
    ] as [([String]?, String?)])
    func folderIsTheFirstWorkingDirectory(folders: [String]?, folder: String?) {
        #expect(SessionRow(summary: summary(folders: folders)).folder == folder)
    }

    @Test func rowIsIdentifiedByItsResource() {
        let row = SessionRow(summary: summary("ahp-session:/abc", modifiedAt: "2025-01-01T00:00:00Z"))
        #expect(row.id == "ahp-session:/abc")
        #expect(row.modifiedAt == "2025-01-01T00:00:00Z")
        #expect(row == SessionRow(summary: summary("ahp-session:/abc", modifiedAt: "2025-01-01T00:00:00Z")))
    }

    @Test func sortsNewestFirstThenByResourceWithUnparseableDatesLast() {
        let rows = [
            ("ahp-session:/bad-b", "yesterday"),
            ("ahp-session:/old", "2025-03-10T18:42:03Z"),
            ("ahp-session:/tie-b", "2025-03-11T09:00:00.000Z"),
            ("ahp-session:/bad-a", ""),
            ("ahp-session:/new", "2025-03-12T08:00:00.5Z"),
            ("ahp-session:/tie-a", "2025-03-11T09:00:00Z"),
            ("ahp-session:/mid", "2025-03-10T18:42:03.250Z"),
        ].map { SessionRow(summary: summary($0.0, modifiedAt: $0.1)) }

        #expect(SessionRow.sorted(rows).map(\.resource) == [
            "ahp-session:/new", "ahp-session:/tie-a", "ahp-session:/tie-b", "ahp-session:/mid",
            "ahp-session:/old", "ahp-session:/bad-a", "ahp-session:/bad-b",
        ])
    }

    @Test(arguments: [
        ("ahp-session:/guppi.eridanilabs.VIRT.37.1", "eridanilabs/VIRT #37"),
        ("ahp-session:/guppi.eridanilabs.VIRT.37.3", "eridanilabs/VIRT #37 (attempt 3)"),
        ("ahp-session:/guppi.acme.my.dotted.repo.5.2", "acme/my.dotted.repo #5 (attempt 2)"),
        ("ahp-session:/guppi.eridanilabs.VIRT.0.1", "Host title"),
        ("ahp-session:/guppi.eridanilabs.VIRT.-3.1", "Host title"),
        ("ahp-session:/guppi.eridanilabs.VIRT.37.0", "Host title"),
        ("ahp-session:/guppi.eridanilabs.VIRT.3a.1", "Host title"),
        ("ahp-session:/guppi.eridanilabs.VIRT.٣.1", "Host title"),
        ("ahp-session:/guppi.eridanilabs.VIRT.37", "Host title"),
        ("ahp-session:/guppi.eridanilabs..37.1", "Host title"),
        ("ahp-session:/guppi..VIRT.37.1", "Host title"),
        ("ahp-session:/guppi.eridanilabs.VIRT.99999999999999999999.1", "Host title"),
        ("ahp-session:/1b2c3d", "Host title"),
    ])
    func titleFromAGuppiResourceOrTheHost(resource: String, title: String) {
        #expect(SessionRow(summary: summary(resource, title: "Host title")).title == title)
    }

    @Test func memberwiseInitStoresEveryField() {
        let row = SessionRow(resource: "ahp-session:/guppi.a.b.1.1", title: "**x** [y](z)", state: .working,
                             folder: "/tmp/<b>", modifiedAt: "not a date")
        #expect(row.resource == "ahp-session:/guppi.a.b.1.1")
        #expect(row.id == "ahp-session:/guppi.a.b.1.1")
        #expect(row.title == "**x** [y](z)")
        #expect(row.state == .working)
        #expect(row.folder == "/tmp/<b>")
        #expect(row.modifiedAt == "not a date")
        #expect(SessionRow(resource: "r", title: "", state: .idle, folder: nil, modifiedAt: "").folder == nil)
    }

    @Test func emptyTitleIsUntitled() {
        #expect(SessionRow(summary: summary("ahp-session:/1b2c3d", title: "")).title == "Untitled session")
        #expect(SessionRow(summary: summary("ahp-session:/guppi.a.b.1.1", title: "")).title == "a/b #1")
    }
}
