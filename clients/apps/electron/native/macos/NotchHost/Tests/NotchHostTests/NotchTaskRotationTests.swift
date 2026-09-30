import Testing
@testable import NotchHost

@Test func rotatesThroughEveryTaskAndWraps() {
    var rotation = CommaNotchTaskRotation()
    rotation.update(taskIDs: ["a", "b", "c"])
    #expect(rotation.currentTaskID == "a")
    rotation.advance()
    #expect(rotation.currentTaskID == "b")
    rotation.advance()
    #expect(rotation.currentTaskID == "c")
    rotation.advance()
    #expect(rotation.currentTaskID == "a")
}

@Test func projectionUpdatesPreserveTheVisibleTask() {
    var rotation = CommaNotchTaskRotation()
    rotation.update(taskIDs: ["a", "b"])
    rotation.advance()
    rotation.update(taskIDs: ["new", "b", "a"])
    #expect(rotation.currentTaskID == "b")
    rotation.advance()
    #expect(rotation.currentTaskID == "a")
    rotation.advance()
    #expect(rotation.currentTaskID == "new")
}

@Test func completedTaskIsReplacedByARemainingTask() {
    var rotation = CommaNotchTaskRotation()
    rotation.update(taskIDs: ["a", "b", "c"])
    rotation.advance()
    rotation.update(taskIDs: ["c", "a"])
    #expect(rotation.currentTaskID == "c")
    rotation.advance()
    #expect(rotation.currentTaskID == "a")
}

@Test func singleAndEmptyProjectionsDoNotRotate() {
    var rotation = CommaNotchTaskRotation()
    rotation.advance()
    #expect(rotation.currentTaskID == nil)
    rotation.update(taskIDs: ["a"])
    rotation.advance()
    #expect(rotation.currentTaskID == "a")
    rotation.update(taskIDs: [])
    rotation.advance()
    #expect(rotation.currentTaskID == nil)
    rotation.update(taskIDs: ["b", "c"])
    #expect(rotation.currentTaskID == "b")
}
