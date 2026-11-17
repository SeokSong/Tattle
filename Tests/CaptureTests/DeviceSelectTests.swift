import Foundation
import Testing

@testable import Capture

private func fake(_ name: String, _ udid: String) -> DeviceSummary {
    DeviceSummary(name: name, udid: udid, transport: "wired", pairing: "paired", tunnel: "disconnected")
}

private let sams = [
    fake("Sam's iPhone", "00008110-FAKEUDID0001"),
    fake("Sam's iPhone 2", "00008110-FAKEUDID0002"),
]

@Test func exactNameBeatsSubstring() {
    #expect(DeviceLookup.select(name: "Sam's iPhone", from: sams) == .chosen(sams[0]))
    #expect(DeviceLookup.select(name: "SAM'S IPHONE", from: sams) == .chosen(sams[0]))
}

@Test func apostropheVariantsMatch() {
    #expect(DeviceLookup.select(name: "Sam\u{2019}s iPhone 2", from: sams) == .chosen(sams[1]))
}

@Test func uniqueSubstringMatches() {
    #expect(DeviceLookup.select(name: "iphone 2", from: sams) == .chosen(sams[1]))
}

@Test func ambiguousSubstringFails() {
    #expect(DeviceLookup.select(name: "iphone", from: sams) == .ambiguous(["Sam's iPhone", "Sam's iPhone 2"]))
}

@Test func duplicateExactNamesAreAmbiguous() {
    let twins = [fake("Test iPhone", "00008110-FAKEUDID0003"), fake("test iphone", "00008110-FAKEUDID0004")]
    #expect(DeviceLookup.select(name: "Test iPhone", from: twins) == .ambiguous(["Test iPhone", "test iphone"]))
}

@Test func noNameWithTwoDevicesIsAmbiguous() {
    #expect(DeviceLookup.select(name: nil, from: sams) == .ambiguous(["Sam's iPhone", "Sam's iPhone 2"]))
}

@Test func noNameWithOneDeviceChoosesIt() {
    #expect(DeviceLookup.select(name: nil, from: [sams[0]]) == .chosen(sams[0]))
}

@Test func noNameWithNoDevicesIsNotFound() {
    #expect(DeviceLookup.select(name: nil, from: []) == .notFound(available: []))
}

@Test func notFoundListsNames() {
    let result = DeviceLookup.select(name: "x", from: sams)
    #expect(result == .notFound(available: ["Sam's iPhone", "Sam's iPhone 2"]))
    #expect(!"\(result)".contains("FAKEUDID"))
}
