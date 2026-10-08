import Foundation
import XCTest

@testable import BinauralCore

/// Locates the one frequency reference both implementations read.
///
/// The path is derived from `#filePath` — `apple/Tests/CoreTests/TestSupport.swift`,
/// four levels up is the repository root — so the tests always read the file being
/// edited. There is deliberately no bundled copy for the test target: a count that goes
/// stale would hide exactly the drift these tests exist to catch.
enum ReferenceFile {

    /// `<repo>/src/binaural/data/frequencies.json`
    static let url: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent("src/binaural/data/frequencies.json")
    }()

    static func catalogue(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FrequencyCatalogue {
        try FrequencyCatalogue(contentsOf: url)
    }
}

/// Minimal analysis used by the synthesis tests.
///
/// The oscillator emits a pure sine, so a frequency can be recovered from its
/// zero crossings with linear interpolation: the estimate is bounded by `1 / window`,
/// not by the sample rate.
enum SignalAnalysis {

    /// Frequency of a sine, in Hz, from positive-going zero crossings.
    ///
    /// The crossings are located by linear interpolation between the two samples that
    /// straddle zero, then the frequency follows from how many of them fit between the
    /// first and the last one — independent of where the window starts. The fade-in is
    /// skipped: only samples at or above half the peak amplitude are measured, so the
    /// amplitude ramp cannot invent crossings.
    static func frequency(of samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > 2 else { return 0 }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return 0 }

        let threshold = peak * 0.5
        let start = samples.firstIndex { abs($0) >= threshold } ?? 0

        var crossings = 0
        var firstPosition: Double?
        var lastPosition = 0.0
        var previous = Double(samples[start])

        for index in (start + 1)..<samples.count {
            let current = Double(samples[index])
            if previous <= 0, current > 0 {
                // The zero sits `fraction` of the way from the previous sample.
                let fraction = -previous / (current - previous)
                let position = Double(index) - fraction
                if firstPosition == nil { firstPosition = position }
                lastPosition = position
                crossings += 1
            }
            previous = current
        }

        guard crossings > 1, let first = firstPosition else { return 0 }
        let elapsed = (lastPosition - first) / sampleRate
        return elapsed > 0 ? Double(crossings - 1) / elapsed : 0
    }

    /// Largest absolute sample value.
    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// RMS of a buffer — used to tell a faded-in signal from a step.
    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}

/// A lock-protected recorder for values a `@Sendable` closure captures.
///
/// The injected closures in the update tests are `@Sendable`, so they cannot capture a
/// mutable local; they capture this instead and the test reads the snapshot afterwards.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    var snapshot: [Value] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

extension XCTestCase {

    /// Assert `value` equals `expected` within `tolerance`, reporting the difference.
    func assertClose(
        _ value: Double,
        _ expected: Double,
        accuracy tolerance: Double,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            value,
            expected,
            accuracy: tolerance,
            message.isEmpty ? "got \(value), expected \(expected) ± \(tolerance)" : message,
            file: file,
            line: line
        )
    }
}