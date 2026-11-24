import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct MessageRecallTests {
    @Test func historyIsNewestFirstWithRepeatsCollapsedAndBlanksLeftOut() {
        let history = MessageRecall.history(newestFirst: ["c", "b", "b", " ", "a", "b"])
        #expect(history == ["c", "b", "a", "b"])
    }

    @Test func historyStopsAtTheLimit() {
        let history = MessageRecall.history(newestFirst: (0..<500).map { "message \($0)" })
        #expect(history.count == MessageRecall.limit)
        #expect(history.first == "message 0")
    }

    @Test func upGoesBackAndDownComesForwardToTheDraft() {
        var recall = MessageRecall()
        let history = ["third", "second", "first"]
        #expect(recall.older(current: "half typed", history: { history }) == "third")
        #expect(recall.older(current: "third", history: { history }) == "second")
        #expect(recall.older(current: "second", history: { history }) == "first")
        #expect(recall.older(current: "first", history: { history }) == nil, "nothing older")
        #expect(recall.newer(current: "first") == "second")
        #expect(recall.newer(current: "second") == "third")
        #expect(recall.newer(current: "third") == "half typed")
        #expect(!recall.isRecalling)
        #expect(recall.newer(current: "half typed") == nil, "Down past the draft does what it always does")
    }

    @Test func anEditIsKeptWhileMovingThroughTheOthers() {
        var recall = MessageRecall()
        let history = ["third", "second"]
        _ = recall.older(current: "", history: { history })
        #expect(recall.older(current: "third, edited", history: { history }) == "second")
        #expect(recall.newer(current: "second") == "third, edited")
        #expect(recall.newer(current: "third, edited") == "")
    }

    @Test func nothingToRecallLeavesTheKeyAlone() {
        var recall = MessageRecall()
        #expect(recall.older(current: "draft", history: { [] }) == nil)
        #expect(!recall.isRecalling)
    }
}

@Suite struct MessageQueueTests {
    @Test func messagesGoOutInTheOrderTheyWereQueued() {
        var queue = MessageQueue()
        queue.append("one")
        queue.append("two")
        #expect(queue.next()?.text == "one")
        #expect(queue.next()?.text == "two")
        #expect(queue.next() == nil)
    }

    @Test func aPausedQueueSendsNothingUntilResumed() {
        var queue = MessageQueue()
        queue.append("one")
        queue.append("two")
        queue.pause(.stopped)
        #expect(queue.next() == nil)
        #expect(queue.items.map(\.text) == ["one", "two"])
        #expect(queue.resume()?.text == "one")
        #expect(queue.pauseReason == nil)
        #expect(queue.next()?.text == "two")
    }

    @Test func anEmptyQueueDoesNotPause() {
        var queue = MessageQueue()
        queue.pause(.failed)
        #expect(queue.pauseReason == nil)
    }

    @Test func removeAndPullBack() {
        var queue = MessageQueue()
        queue.append("one")
        queue.append("two")
        queue.append("three")
        queue.remove(queue.items[1].id)
        #expect(queue.items.map(\.text) == ["one", "three"])
        #expect(queue.pullBack() == "three", "without an id, the newest")
        #expect(queue.pullBack(queue.items[0].id) == "one")
        #expect(queue.isEmpty)
    }
}

@Suite struct BehaviorSettingTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "mac-os-agent-behavior-tests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func defaultsAreRecallAndDoubleDeleteOnAndTheRestOff() throws {
        let (defaults, name) = try suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(HarnessBehavior.recallEarlierMessages.isOn(defaults))
        #expect(HarnessBehavior.doubleDeleteStartsNewEpisode.isOn(defaults))
        #expect(!HarnessBehavior.controlCStopsOrClears.isOn(defaults))
        #expect(!Experiment.queueMessagesWhileRunning.isOn(defaults))
    }

    @Test func aSwitchKeepsItsValue() throws {
        let (defaults, name) = try suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        HarnessBehavior.recallEarlierMessages.set(false, defaults)
        HarnessBehavior.controlCStopsOrClears.set(true, defaults)
        HarnessBehavior.doubleDeleteStartsNewEpisode.set(false, defaults)
        Experiment.queueMessagesWhileRunning.set(true, defaults)
        #expect(!HarnessBehavior.doubleDeleteStartsNewEpisode.isOn(defaults))
        #expect(!HarnessBehavior.recallEarlierMessages.isOn(defaults))
        #expect(HarnessBehavior.controlCStopsOrClears.isOn(defaults))
        #expect(Experiment.queueMessagesWhileRunning.isOn(defaults))
    }

    /// Every experiment is off on a fresh install, including the panel with bars, and each
    /// has its own key and a title for Settings.
    @Test func everyExperimentIsOffByDefaultWithItsOwnKeyAndTitle() throws {
        let (defaults, name) = try suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        for experiment in Experiment.allCases {
            #expect(!experiment.defaultValue, "\(experiment)")
            #expect(!experiment.isOn(defaults), "\(experiment)")
            #expect(!experiment.title.isEmpty)
        }
        #expect(Set(Experiment.allCases.map(\.key)).count == Experiment.allCases.count)
        #expect(Experiment.panelWithBarsAndInputPill.title == "Panel with bars and an input pill")
        #expect(Experiment.panelWithBarsAndInputPill.key == "ExperimentPanelWithBarsAndInputPill")
        Experiment.panelWithBarsAndInputPill.set(true, defaults)
        #expect(Experiment.panelWithBarsAndInputPill.isOn(defaults))
        // Turning it on does not turn on the suggestions experiment's own switch.
        #expect(!Experiment.suggestionsInFieldAndFooter.isOn(defaults))
        Experiment.panelWithBarsAndInputPill.set(false, defaults)
        #expect(!Experiment.panelWithBarsAndInputPill.isOn(defaults))
    }
}

@Suite struct DoubleDeleteTests {
    private func press(_ presses: inout DoubleDelete, _ empty: Bool, _ repeating: Bool, _ time: TimeInterval) -> Bool {
        presses.press(fieldIsEmpty: empty, isRepeat: repeating, at: time)
    }

    @Test func twoPressesOnAnEmptyFieldWithinTheIntervalCount() {
        var presses = DoubleDelete(interval: 0.5)
        #expect(!press(&presses, true, false, 10))
        #expect(presses.isWaiting)
        #expect(press(&presses, true, false, 10.3))
        #expect(!presses.isWaiting, "a third press starts over")
        #expect(!press(&presses, true, false, 10.4))
    }

    @Test func onePressDoesNotCount() {
        var presses = DoubleDelete(interval: 0.5)
        #expect(!press(&presses, true, false, 10))
    }

    @Test func tooSlowStartsOverFromTheLaterPress() {
        var presses = DoubleDelete(interval: 0.5)
        #expect(!press(&presses, true, false, 10))
        #expect(!press(&presses, true, false, 10.6))
        #expect(press(&presses, true, false, 10.9), "the slow press was a first press")
    }

    @Test func aPressThatEmptiesTheFieldIsNotTheFirst() {
        var presses = DoubleDelete(interval: 0.5)
        #expect(!press(&presses, false, false, 10))
        #expect(!press(&presses, true, false, 10.1))
    }

    @Test func keyRepeatNeverCountsAndStartsOver() {
        var presses = DoubleDelete(interval: 0.5)
        // Holding Delete through the last characters and on into an empty field.
        #expect(!press(&presses, false, false, 10))
        for step in 1...10 {
            #expect(!press(&presses, step > 3, true, 10 + Double(step) * 0.05))
        }
        #expect(!presses.isWaiting)
        // A press, then a repeat between it and the next press.
        #expect(!press(&presses, true, false, 11))
        #expect(!press(&presses, true, true, 11.05))
        #expect(!press(&presses, true, false, 11.1))
    }

    @Test func resetForgetsTheFirstPress() {
        var presses = DoubleDelete(interval: 0.5)
        _ = presses.press(fieldIsEmpty: true, isRepeat: false, at: 10)
        presses.reset()
        #expect(!press(&presses, true, false, 10.1))
    }
}
