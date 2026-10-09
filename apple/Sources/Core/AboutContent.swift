import Foundation

/// The wording About and the frequency reference share (SPEC §6.13, §7).
///
/// Kept in `BinauralCore`, not in a dialog: SPEC §6.13 requires the disclaimer in the app
/// **and** in the README, so the one sentence that both the About dialog and the
/// reference dialog show must not be typed twice — and `BinauralCoreTests` has to be able
/// to check it against the Russian catalogue, which it can only do from inside Core.
///
/// It lives here rather than in `Sources/macOS` because it holds no AppKit at all: three
/// strings, one licence holder, and one `L10n.tr` call. `Core` is pure maths and data by
/// design, and a fixed text constant with its translation is data.
public enum AboutContent {

    // MARK: - Identity

    public static let projectURL = "https://github.com/zeroscrypt/binaural"

    /// Shown in About. Not a `tr` literal at the call site: Python calls the same
    /// sentence `tr("About Binaural")`, and a shared key is what keeps the two
    /// implementations saying the same thing.
    public static let aboutTitle = "About Binaural"

    /// SPEC §7: the tagline under the title. `apple/` is a **separate product** from the
    /// Python PySide6 app (SPEC §3), and this one is macOS-only, so it does not reuse
    /// Python's "macOS and Linux" wording — which would be false here.
    public static let tagline = "Binaural beats for macOS"

    /// The project description (SPEC §1, §2): two tones, one perceived difference.
    /// Verbatim in meaning from `about.py::_WHAT_IT_IS`, so both products describe
    /// themselves the same way.
    public static let whatItIs = "Two sine tones of different frequency are sent to the "
        + "left and the right ear. Your brain fuses them into a third tone that has no "
        + "sound source: the difference between the two frequencies. That phantom tone "
        + "is the binaural beat."

    /// Why headphones are a physical requirement and not a preference (SPEC §2.1).
    public static let whatItNeeds = "Headphones are a physical requirement, not a "
        + "recommendation: on speakers both frequencies mix in the air before they reach "
        + "your ears, and the effect is gone. The application checks the audio output on "
        + "every start and reports what it found."

    public static let evidenceNote = "The frequency reference keeps every record it has "
        + "— from peer-reviewed EEG literature to esoteric traditions — each marked with "
        + "how well it is studied."

    // MARK: - The four descriptive sections

    // SPEC §7 item 6 names the four sections the About dialog shows. They are here,
    // in `Core`, for the same reason the disclaimer is: a sentence both products
    // show must be one string translated through `L10n.tr`, not two sentences that
    // can drift (CONTRACT rule 9).

    /// Section headings. Each is a bare noun phrase in the key, which is also how
    /// `ru.py` carries them — a heading is not a full sentence and does not read
    /// like one when a translator reads the key alone.
    public static let whoMadeItTitle = "Who made it"
    public static let howItWorksTitle = "How it works"
    public static let whatItIsForTitle = "What it is and what it is for"
    public static let technicalTitle = "Technical details"

    /// «Кто создал». Two handles, one name, a year and the repository — and nothing
    /// else. A biography, a company and a contact address are all invented, so they
    /// are all absent.
    public static let creditsLine = "Written by @zeroscrypt, "
        + "with special thanks to @hakatao."
    public static let creditsWhere = "The project lives at github.com/zeroscrypt/binaural. "
        + "Released in 2026."

    /// «Как это работает», part 1: the effect itself. Names the third tone and says
    /// what it is, so the reader has the whole idea before `beat` and `carrier`
    /// arrive in the next sentence.
    public static let mechanismLine = "Two sine tones of different frequency, one sent "
        + "to each ear, and the brain hears a third tone that is not there. That third "
        + "tone is the difference between the two frequencies, and it is called the beat."

    /// …part 2: the two numbers, defined. ``beat`` is the difference, ``carrier`` is
    /// the average — the tone each ear actually hears, with the beat inside it. A
    /// reader who does not know either word can still follow this sentence.
    public static let termsLine = "The beat is the difference between the two "
        + "frequencies. The carrier is their average — the tone you actually hear in "
        + "each ear, with the beat pulsing inside it."

    /// …part 3: why headphones are a requirement. ``whatItNeeds`` says the app
    /// *checks* the output; this says why the check can fail, which is the part a
    /// reader without the other paragraph would be missing.
    public static let headphonesWhyLine = "Headphones are not a preference but a "
        + "physical requirement: the two frequencies have to reach your ears separately, "
        + "and only headphones do that. On speakers they mix in the air first, and "
        + "there is nothing left to fuse."

    /// …part 4: what the app actually does. The feature list in words, and the two
    /// absences — nothing touches the signal, nothing leaves the machine — which are
    /// the claims a user is most likely to want checked.
    public static let appDoesLine = "The application itself does the plain part: two "
        + "independent frequencies you set, play and stop, volume, a timer, presets, "
        + "the frequency reference and a headphone check. Nothing is added to the "
        + "sound and nothing is sent anywhere."

    /// «Что это и зачем», part 1: what the thing is, in one sentence.
    public static let scopeLine = "Binaural is a desktop generator of binaural beats. "
        + "It makes a sound and shows you what is known about the frequencies it can play."

    /// …part 2: what it is not. The three words SPEC §6.13 turns on — not a medical
    /// device, no diagnosis / treatment / prevention, no promised effect — and a
    /// pointer to the disclaimer panel rather than a second copy of it: a disclaimer
    /// quoted twice is two texts to keep in step, and the short one would soften first.
    public static let notMedicalLine = "It is not a medical device and makes no health "
        + "claim. It does not diagnose, treat or prevent anything, and it does not "
        + "promise an effect. The disclaimer below is the full version of that sentence."

    /// «Технические детали», part 1: the licence, and the sentence about the two
    /// applications. The version line is deliberately **not** here —
    /// ``versionTemplate`` already shows it once, and a second copy would be two
    /// lines to keep in step for no gain.
    ///
    /// ``platformLicenceLine`` is macOS-only on purpose and follows ``tagline``: the
    /// Swift build is a separate product (SPEC §3), so the shared "macOS and Linux"
    /// wording would be false in it. Its Russian lives in `RussianWindowAdditions`.
    public static let platformLicenceLine = "Platform: macOS. Licence: MIT — use it, change it, ship it."

    /// …part 2: the stack, and what the two implementations do and do not share. The
    /// frequency arithmetic is one contract (CONTRACT §2) and the code is not, which
    /// is the one thing worth saying about the stack to somebody deciding whether to
    /// read the repository or install something from it.
    ///
    /// One literal, not a `+` run: `L10nTests.testEveryAdditionIsShownByTheApp` finds
    /// a Swift-only key by `contains`, so a joined literal would not be found at all.
    public static let stackLine = "Built with Swift and AVAudioEngine. Two applications are built from this repository; they share their frequency arithmetic, not their code."

    /// …part 3: why there is no `.app` to download. In the technical section rather
    /// than a fifth one because it is part of what "this is a build you can actually
    /// get" means, and it is already in this form in `apple/README.md` and `README.md`.
    public static let unsignedLine = "The macOS app is unsigned: no Apple Developer "
        + "identity is available, so it runs for whoever built it and Gatekeeper blocks "
        + "it for anyone else. Right-click, then Open, gets past it. GitHub releases "
        + "carry source only."

    /// ``versionLine``'s key, which carries `{version}` and `{system}` placeholders.
    public static let versionTemplate = "Version {version} · macOS {system}"

    /// The version line as the user sees it, from the running bundle.
    ///
    /// `CFBundleShortVersionString` with the build number appended when it is there: the
    /// two are what a bug report has to quote. Falls back to `"0.1"`, the marketing
    /// version in `project.yml`, rather than showing an empty string.
    @MainActor
    public static func versionText(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version: String
        if let short, let build, !build.isEmpty, short != build {
            version = "\(short) (\(build))"
        } else {
            version = short ?? "0.1"
        }
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return L10n.tr(versionTemplate, named: ["version": version, "system": system])
    }

    // MARK: - Disclaimer (SPEC §6.13)

    public static let disclaimerTitle = "Disclaimer"

    /// SPEC §6.13, English. Not a medical device; no diagnosis, treatment or prevention;
    /// ask a doctor with epilepsy, a pacemaker, in pregnancy or with photosensitivity;
    /// keep the volume sane; beats are sound rather than a substance and nothing here
    /// treats dependence.
    public static let disclaimerEnglish = """
        These frequencies and the descriptions of their effects come from research, \
        and also from esoteric, energy and alternative practices. This application is \
        not a medical device and is not intended for the diagnosis, treatment or \
        prevention of any disease. Do not use it if you have epilepsy or a pacemaker, \
        during pregnancy, or if you are photosensitive, without consulting a doctor. \
        Do not turn the volume above a comfortable level. Binaural beats are sound, \
        not a substance, and they do not replace one. Nothing here helps with \
        withdrawal, craving, tolerance or relapse, and this app does not treat \
        dependence of any kind. Dependence is a medical condition with risks of its \
        own: withdrawal from alcohol and from sedatives can be dangerous. If you are \
        dependent on something, or want to use less of it, that is a question for a \
        doctor or a specialist service, not for a tone generator.
        """

    /// The disclaimer as the user sees it, in the current language.
    ///
    /// The key is the same sentence ``disclaimerEnglish`` holds, and `ru.py` translates
    /// exactly that string — so Russian comes from the shared catalogue and never from a
    /// private translation here.
    @MainActor
    public static func disclaimerText() -> String {
        L10n.tr(disclaimerEnglish)
    }

    // MARK: - Licence

    public static let licenseName = "MIT License"
    public static let licenseHolder = "@zeroscrypt"
    public static let licenseYear = "2026"

    /// The MIT notice, **verbatim** from `about.py::LICENSE_SUMMARY_EN` — and therefore
    /// also from `ru.py`, which is what gives the Russian translation below.
    ///
    /// The abbreviated form is deliberate on Python's side: it is a summary shown inside
    /// the About dialog, not the licence file. Re-typing the full MIT text here would
    /// create a second English key with no Russian, i.e. a licence paragraph that reads
    /// in English inside a Russian dialog.
    public static let licenseSummary = "Permission is hereby granted, free of charge, "
        + "to any person obtaining a copy of this software and associated documentation "
        + "files (the \"Software\"), to deal in the Software without restriction, "
        + "including without limitation the rights to use, copy, modify, merge, publish, "
        + "distribute, sublicense and/or sell copies of the Software, and to permit "
        + "persons to whom the Software is furnished to do so, subject to the conditions "
        + "of the MIT licence. The software is provided \"as is\", without warranty of any "
        + "kind, express or implied."

    /// `"Copyright (c) 2026 @zeroscrypt"` — the key, translated with its two
    /// placeholders filled.
    @MainActor
    public static func copyrightText() -> String {
        L10n.tr("Copyright (c) {year} {holder}", named: [
            "year": licenseYear, "holder": licenseHolder,
        ])
    }

    // MARK: - Update check

    // The update flow's wording, here for the same reason the About wording is: one
    // constant per sentence, translated through `L10n.tr` when shown, so the English
    // source and the Russian catalogue cannot drift apart (CONTRACT rule 9).

    public static let checkForUpdatesButton = "Check for updates"
    public static let checkingMessage = "Checking for updates…"
    public static let upToDateMessage = "You are up to date"
    public static let updateAvailableTemplate = "Version {version} is available"
    public static let downloadAndInstallButton = "Download and install"
    public static let laterButton = "Later"
    public static let skipThisVersionButton = "Skip this version"
    public static let downloadingMessage = "Downloading update…"
    public static let checkFailedMessage = "Could not check for updates"
    public static let downloadFailedMessage = "Could not download the update."
    public static let installFailedMessage = "Could not install the update."
    public static let installConfirmMessage = "Binaural will restart to finish the update."
    public static let installAndRestartButton = "Install and restart"
    public static let releasePageButton = "Open the release page"

    // MARK: - Translation

    /// Every string in this file, for callers that build a whole dialog out of them.
    ///
    /// The keys here are constants translated **when shown**, not `tr()` literals — the
    /// `engine.py::_ERROR_SOURCES` rule that ``AudioFailure`` follows. Exposed so
    /// `L10nKeysTests` can put them through the parity check anyway: a named constant must
    /// not be a way around the catalogue.
    public static let namedKeys: [String] = [
        aboutTitle, tagline, whatItIs, whatItNeeds, evidenceNote, versionTemplate,
        disclaimerTitle, disclaimerEnglish, licenseName, licenseSummary,
        "Copyright (c) {year} {holder}",
        // The four sections of SPEC §7 item 6.
        whoMadeItTitle, howItWorksTitle, whatItIsForTitle, technicalTitle,
        creditsLine, creditsWhere,
        mechanismLine, termsLine, headphonesWhyLine, appDoesLine,
        scopeLine, notMedicalLine,
        platformLicenceLine, stackLine, unsignedLine,
        // The update check.
        checkForUpdatesButton, checkingMessage, upToDateMessage, updateAvailableTemplate,
        downloadAndInstallButton, laterButton, skipThisVersionButton, downloadingMessage,
        checkFailedMessage, downloadFailedMessage, installFailedMessage,
        installConfirmMessage, installAndRestartButton, releasePageButton,
    ]

}

/// Every user-visible string of About and the shared disclaimer, in the current language.
///
/// One place so the About dialog is a view over data and not a place where wording can
/// diverge: `L10n.tr` is called once per string and the result handed to the labels.
@MainActor
public enum AboutContentText {

    public static var tagline: String { L10n.tr(AboutContent.tagline) }
    public static var whatItIs: String { L10n.tr(AboutContent.whatItIs) }
    public static var whatItNeeds: String { L10n.tr(AboutContent.whatItNeeds) }
    public static var evidenceNote: String { L10n.tr(AboutContent.evidenceNote) }
    public static var whoMadeItTitle: String { L10n.tr(AboutContent.whoMadeItTitle) }
    public static var howItWorksTitle: String { L10n.tr(AboutContent.howItWorksTitle) }
    public static var whatItIsForTitle: String { L10n.tr(AboutContent.whatItIsForTitle) }
    public static var technicalTitle: String { L10n.tr(AboutContent.technicalTitle) }
    public static var creditsLine: String { L10n.tr(AboutContent.creditsLine) }
    public static var creditsWhere: String { L10n.tr(AboutContent.creditsWhere) }
    public static var mechanismLine: String { L10n.tr(AboutContent.mechanismLine) }
    public static var termsLine: String { L10n.tr(AboutContent.termsLine) }
    public static var headphonesWhyLine: String { L10n.tr(AboutContent.headphonesWhyLine) }
    public static var appDoesLine: String { L10n.tr(AboutContent.appDoesLine) }
    public static var scopeLine: String { L10n.tr(AboutContent.scopeLine) }
    public static var notMedicalLine: String { L10n.tr(AboutContent.notMedicalLine) }
    public static var platformLicenceLine: String {
        L10n.tr(AboutContent.platformLicenceLine)
    }
    public static var stackLine: String { L10n.tr(AboutContent.stackLine) }
    public static var unsignedLine: String { L10n.tr(AboutContent.unsignedLine) }
    public static var disclaimerTitle: String { L10n.tr(AboutContent.disclaimerTitle) }
    public static var aboutTitle: String { L10n.tr(AboutContent.aboutTitle) }
    public static var licenseName: String { L10n.tr(AboutContent.licenseName) }
    public static var licenseSummary: String { L10n.tr(AboutContent.licenseSummary) }
    public static var disclaimer: String { AboutContent.disclaimerText() }

    // MARK: - Update check

    public static var checkForUpdatesButton: String { L10n.tr(AboutContent.checkForUpdatesButton) }
    public static var checkingMessage: String { L10n.tr(AboutContent.checkingMessage) }
    public static var upToDateMessage: String { L10n.tr(AboutContent.upToDateMessage) }
    public static var updateAvailableTemplate: String { L10n.tr(AboutContent.updateAvailableTemplate) }
    public static var downloadAndInstallButton: String { L10n.tr(AboutContent.downloadAndInstallButton) }
    public static var laterButton: String { L10n.tr(AboutContent.laterButton) }
    public static var skipThisVersionButton: String { L10n.tr(AboutContent.skipThisVersionButton) }
    public static var downloadingMessage: String { L10n.tr(AboutContent.downloadingMessage) }
    public static var checkFailedMessage: String { L10n.tr(AboutContent.checkFailedMessage) }
    public static var downloadFailedMessage: String { L10n.tr(AboutContent.downloadFailedMessage) }
    public static var installFailedMessage: String { L10n.tr(AboutContent.installFailedMessage) }
    public static var installConfirmMessage: String { L10n.tr(AboutContent.installConfirmMessage) }
    public static var installAndRestartButton: String { L10n.tr(AboutContent.installAndRestartButton) }
    public static var releasePageButton: String { L10n.tr(AboutContent.releasePageButton) }
}