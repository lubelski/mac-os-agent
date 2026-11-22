import MacOSAgentCore
import Testing

@Suite struct AppUpdatesTests {
    @Test func aBuildWithTheFeedAndKeyUpdatesItself() {
        #expect(AppUpdates.hasFeed([
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "a-public-key",
        ]))
    }

    @Test func aBuildWithoutBothKeysNeverUpdatesItself() {
        #expect(!AppUpdates.hasFeed(nil))
        #expect(!AppUpdates.hasFeed([:]))
        #expect(!AppUpdates.hasFeed(["SUFeedURL": "https://example.com/appcast.xml"]))
        #expect(!AppUpdates.hasFeed(["SUPublicEDKey": "a-public-key"]))
        #expect(!AppUpdates.hasFeed(["SUFeedURL": "", "SUPublicEDKey": "a-public-key"]))
    }

    @Test func anIdleAppMayRelaunch() {
        #expect(AppUpdates.mayRelaunch(.init()))
        #expect(AppUpdates.wait(for: .init()) == nil)
    }

    @Test func aRunningTaskHoldsTheRelaunch() {
        #expect(AppUpdates.wait(for: .init(taskRunning: true)) == .task)
        #expect(!AppUpdates.mayRelaunch(.init(taskRunning: true)))
    }

    @Test func aGoAheadHoldsTheRelaunchEvenOutsideATask() {
        #expect(AppUpdates.wait(for: .init(waitingForGoAhead: true)) == .goAhead)
        #expect(AppUpdates.wait(for: .init(taskRunning: true, waitingForGoAhead: true)) == .goAhead)
    }

    @Test func queuedMessagesHoldTheRelaunch() {
        #expect(AppUpdates.wait(for: .init(queuedMessages: true)) == .queuedMessages)
    }

    @Test func anIncognitoConversationHoldsTheRelaunch() {
        #expect(AppUpdates.wait(for: .init(incognitoConversation: true)) == .incognitoConversation)
    }

    @Test func theVersionShowsTheBuildNumber() {
        #expect(AppUpdates.version(["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "512"]) == "0.2.0 (512)")
        #expect(AppUpdates.version(nil) == "development")
    }
}
