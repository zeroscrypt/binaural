import XCTest

@testable import BinauralCore

/// The relaunch has to force a new instance, or the self-update closes the app for good.
///
/// This was reported as "I clicked install and restart, it closed, and it never came back".
/// The install itself had worked — the next manual launch was the new version — so the
/// failure was in the last step and left nothing behind to indicate it.
///
/// The cause is that the update replaces the bundle **at the path this process is running
/// from**. LaunchServices has that path registered as already running, so asking it to open
/// it resolves to *activate the process that is already there* rather than starting the new
/// binary. Both routes hit this: `open <path>` and `NSWorkspace.openApplication(at:)` are the
/// same service. The relaunch therefore accomplished nothing, and the terminate that follows
/// left no process running at all — which looks exactly like the app uninstalling itself.
///
/// `-n` is the documented way to ask for a new instance regardless, and it has to be in the
/// arguments. Asserted here because the flag's absence fails silently: the install succeeds,
/// the archive verifies, the version is right, and the only symptom is an app that does not
/// come back.
final class RelaunchArgumentsTests: XCTestCase {

    private let bundle = URL(fileURLWithPath: "/Applications/Binaural.app")

    func testTheRelaunchForcesANewInstance() {
        XCTAssertEqual(
            UpdateInstaller.relaunchArguments(for: bundle),
            ["-n", bundle.path],
            """
            LaunchServices resolves the running bundle's own path to "activate the process \
            already there", so the relaunch must pass -n or it starts nothing — and the \
            terminate that follows then closes the app for good.
            """
        )
    }

    func testTheBundlePathIsPassedUnchanged() {
        let arguments = UpdateInstaller.relaunchArguments(for: bundle)
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(arguments.last, bundle.path, "the bundle path must not be rewritten")
        XCTAssertEqual(
            arguments.first, "-n",
            "the new-instance flag must come before the path `open` is given"
        )
    }

    /// A path with a space in it — which any install under a home directory or on a volume
    /// named after its owner has — must survive as one argument rather than being split.
    func testAPathWithSpacesStaysOneArgument() {
        let spaced = URL(fileURLWithPath: "/Users/someone/My Apps/Binaural.app")
        let arguments = UpdateInstaller.relaunchArguments(for: spaced)
        XCTAssertEqual(arguments, ["-n", "/Users/someone/My Apps/Binaural.app"])
        XCTAssertEqual(arguments.count, 2, "`Process` arguments are not re-split, so this must hold")
    }

    /// A path that is itself a symlink must be passed as given: `open` resolves it, and
    /// resolving it here would change which app the user sees.
    func testASymlinkedPathIsPassedAsGiven() {
        let linked = URL(fileURLWithPath: "/tmp/Binaural-link.app")
        XCTAssertEqual(UpdateInstaller.relaunchArguments(for: linked).last, linked.path)
    }
}