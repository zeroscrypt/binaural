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
    public static let licenseHolder = "Dmitriy Solontsov"
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

    /// `"Copyright (c) 2026 Dmitriy Solontsov"` — the key, translated with its two
    /// placeholders filled.
    @MainActor
    public static func copyrightText() -> String {
        L10n.tr("Copyright (c) {year} {holder}", named: [
            "year": licenseYear, "holder": licenseHolder,
        ])
    }

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
    public static var disclaimerTitle: String { L10n.tr(AboutContent.disclaimerTitle) }
    public static var aboutTitle: String { L10n.tr(AboutContent.aboutTitle) }
    public static var licenseName: String { L10n.tr(AboutContent.licenseName) }
    public static var licenseSummary: String { L10n.tr(AboutContent.licenseSummary) }
    public static var disclaimer: String { AboutContent.disclaimerText() }
}