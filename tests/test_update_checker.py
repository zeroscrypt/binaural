"""The update check's pure logic: the version order and the release lookup.

Mirrors ``apple/Tests/CoreTests/UpdateCheckerTests.swift`` — the same rules, the
Python spelling. The endpoint, the fetch and the comparator are injected, so
nothing here touches the network.
"""

from __future__ import annotations

import json

import pytest

from binaural import __version__
from binaural.core.update_checker import (
    DEFAULT_ENDPOINT,
    REQUEST_TIMEOUT,
    AppVersion,
    Availability,
    GitHubRelease,
    ReleaseAsset,
    UpdateChecker,
    UpdateHttpError,
    UpdateMissingVersionTag,
    UpdatePayloadError,
    UpdateTransportError,
    host_platform_tag,
    running_version,
)

# --------------------------------------------------------------------------
# The version order
# --------------------------------------------------------------------------


def test_components_are_compared_numerically():
    """0.10.0 is newer than 0.1.0 — the case a string comparison gets backwards."""
    assert AppVersion("0.10.0") > AppVersion("0.1.0")
    assert AppVersion("0.2.0") > AppVersion("0.1.9")
    assert AppVersion("1.0.0") > AppVersion("0.99.99")
    assert AppVersion("0.1.10") > AppVersion("0.1.9")


def test_ordering_is_the_same_in_both_directions():
    assert AppVersion("0.1.0").order(AppVersion("0.2.0")) == -1
    assert AppVersion("0.2.0").order(AppVersion("0.1.0")) == 1
    assert AppVersion("0.2.0").order(AppVersion("0.2.0")) == 0
    assert AppVersion("0.1.0") <= AppVersion("0.2.0")
    assert AppVersion("0.2.0") >= AppVersion("0.1.0")


def test_a_missing_component_is_zero():
    """0.1 and 0.1.0 are the same version, so a build is not nagged by its own release."""
    assert AppVersion("0.1") == AppVersion("0.1.0")
    assert not AppVersion("0.1") > AppVersion("0.1.0")
    assert hash(AppVersion("0.1")) == hash(AppVersion("0.1.0"))
    assert AppVersion("1") == AppVersion("1.0.0.0")
    assert AppVersion("0.0.0") == AppVersion("0")


def test_a_leading_v_is_the_tag_spelling_not_a_version():
    assert AppVersion("v0.2.0") == AppVersion("0.2.0")
    assert AppVersion("V 0.2.0") == AppVersion("0.2.0")
    assert str(AppVersion("v0.2.0")) == "0.2.0"


def test_a_pre_release_is_older_than_its_release():
    assert AppVersion("0.2.0-beta.1") < AppVersion("0.2.0")
    assert AppVersion("0.2.0-beta.1") < AppVersion("0.2.0-beta.2")
    assert AppVersion("1.0.0+build") == AppVersion("1.0.0")


def test_parsing_is_lenient_about_what_follows_the_numbers():
    assert AppVersion("1.2.3abc") == AppVersion("1.2.3")
    assert str(AppVersion("0.2.0-beta.1+build7")) == "0.2.0-beta.1"
    assert AppVersion("0.2.0+build7") == AppVersion("0.2.0")
    assert AppVersion("1.2.3").components == (1, 2, 3)
    assert AppVersion("1.2").components == (1, 2)


def test_text_that_is_not_a_version_is_nothing():
    for text in ("", "v", "unknown", "vNext", None, "..."):
        assert AppVersion.parse(text) is None
    with pytest.raises(ValueError):
        AppVersion("unknown")


def test_the_running_version_comes_from_the_package():
    """The one version the app compares: ``binaural.__version__``."""
    assert running_version() == AppVersion(__version__)
    assert AppVersion.parse(__version__) == running_version()


# --------------------------------------------------------------------------
# The payload
# --------------------------------------------------------------------------

DEFAULT_ASSETS = (
    ("binaural-0.2.0-linux-x64.tar.gz", 2_400_000),
    ("binaural-0.2.0-linux-arm64.tar.gz", 2_300_000),
    ("binaural-0.2.0-windows-amd64.zip", 3_000_000),
    ("Source code (zip)", 900_000),
)


def release_json(tag: str = "v0.2.0", assets=DEFAULT_ASSETS) -> str:
    """A release document shaped like the one GitHub returns."""
    encoded = ", ".join(
        "{"
        f'"name": "{name}", "size": {size}, '
        f'"browser_download_url": "https://github.com/zeroscrypt/binaural/'
        f'releases/download/{tag}/{name}", '
        '"content_type": "application/gzip"}'
        for name, size in assets
    )
    return json.dumps(
        {
            "tag_name": tag,
            "name": tag.lstrip("v"),
            "html_url": f"https://github.com/zeroscrypt/binaural/releases/tag/{tag}",
            "draft": False,
            "prerelease": False,
            "published_at": "2026-10-08T12:00:00Z",
            "assets": json.loads(f"[{encoded}]") if encoded else [],
        }
    )


def checker(document: str = release_json(), **kwargs) -> UpdateChecker:
    return UpdateChecker(fetch=lambda _url: document, **kwargs)


def test_a_newer_tag_is_an_update():
    availability = checker().check(AppVersion("0.1"))
    assert availability.kind is Availability.UPDATE_AVAILABLE
    assert availability.current == AppVersion("0.1")
    assert availability.release.tag_name == "v0.2.0"
    assert availability.release.version == AppVersion("0.2.0")
    assert availability.release.is_draft is False
    assert availability.release.is_prerelease is False
    assert availability.is_worth_telling is True
    assert (
        availability.release.linux_archive(platform_tag="linux-x64").name
        == "binaural-0.2.0-linux-x64.tar.gz"
    )


def test_the_running_release_is_not_offered_to_itself():
    """0.1.0 against v0.1.0: the case that keeps the feature quiet."""
    availability = checker(release_json(tag="v0.1.0")).check(AppVersion("0.1"))
    assert availability.kind is Availability.UP_TO_DATE
    assert availability.release is None
    assert availability.is_worth_telling is False


def test_an_older_tag_is_not_an_update():
    availability = checker(release_json(tag="v0.0.9")).check(AppVersion("0.1"))
    assert availability.kind is Availability.UP_TO_DATE


def test_skipping_silences_one_version_only():
    """``skipped`` is its own answer: silent at launch, still reported when asked."""
    skipped = checker().check(AppVersion("0.1"), skipping=AppVersion("0.2.0"))
    assert skipped.kind is Availability.SKIPPED
    assert skipped.release.tag_name == "v0.2.0"
    assert skipped.is_worth_telling is False

    offered = checker(release_json(tag="v0.3.0")).check(
        AppVersion("0.1"), skipping=AppVersion("0.2.0")
    )
    assert offered.is_worth_telling is True


# --------------------------------------------------------------------------
# Which archive
# --------------------------------------------------------------------------


def test_the_exact_archive_is_preferred():
    """The exact name wins even when several archives look plausible."""
    release = GitHubRelease(
        tag_name="v0.2.0",
        assets=(
            ReleaseAsset("binaural-0.2.0-linux.tar.gz", "a"),
            ReleaseAsset("binaural-0.2.0-linux-x64.tar.gz", "b"),
        ),
    )
    assert release.linux_archive(platform_tag="linux-x64").url == "b"


def test_the_running_architecture_wins_over_another_one():
    release = GitHubRelease(
        tag_name="v0.2.0",
        assets=(
            ReleaseAsset("binaural-0.2.0-linux-arm64.tar.gz", "arm"),
            ReleaseAsset("binaural-0.2.0-linux-x64.tar.gz", "x64"),
        ),
    )
    assert release.linux_archive(platform_tag="linux-x64").url == "x64"
    assert release.linux_archive(platform_tag="linux-arm64").url == "arm"


def test_a_renamed_archive_is_still_found():
    """A release whose asset carries no architecture is still a usable update."""
    release = GitHubRelease(
        tag_name="v0.2.0",
        assets=(ReleaseAsset("binaural-0.2.0.tar.gz", "plain"),),
    )
    assert release.linux_archive(platform_tag="linux-x64").url == "plain"


def test_an_archive_for_another_platform_is_not_offered():
    """Unlike macOS, this app must not offer an archive it cannot run."""
    release = GitHubRelease(
        tag_name="v0.2.0",
        assets=(
            ReleaseAsset("binaural-0.2.0-macos-arm64.tar.gz", "mac"),
            ReleaseAsset("binaural-0.2.0-windows-amd64.zip", "win"),
        ),
    )
    assert release.linux_archive(platform_tag="linux-x64") is None


def test_a_release_with_no_assets_has_no_archive():
    release = GitHubRelease(tag_name="v0.2.0")
    assert release.linux_archive(platform_tag="linux-x64") is None


def test_the_platform_tag_is_this_machine_or_none():
    import sys

    tag = host_platform_tag()
    if sys.platform.startswith("linux"):
        assert tag is None or tag.startswith("linux-")
    else:
        assert tag is None


# --------------------------------------------------------------------------
# Failures
# --------------------------------------------------------------------------


def test_a_malformed_document_is_an_error():
    with pytest.raises(UpdatePayloadError):
        checker("<html>404</html>").latest_release()
    with pytest.raises(UpdatePayloadError):
        checker("[]").latest_release()


def test_a_tag_that_is_not_a_version_is_an_error():
    with pytest.raises(UpdateMissingVersionTag):
        checker(release_json(tag="nightly")).check(AppVersion("0.1"))


def test_a_failed_request_is_a_transport_error():
    """Whatever the injected fetch raises, the checker's failure is an UpdateError."""

    def explode(_url):
        raise OSError("no route to host")

    with pytest.raises(UpdateTransportError):
        UpdateChecker(fetch=explode).check(AppVersion("0.1"))


def test_a_non_success_status_is_an_error():
    def status(_url):
        raise UpdateHttpError(403)

    with pytest.raises(UpdateHttpError) as caught:
        UpdateChecker(fetch=status).check(AppVersion("0.1"))
    assert caught.value.status == 403


def test_an_update_error_from_the_fetch_is_not_rewrapped():
    """A non-200 must not read as a network failure, which is a lie about it."""

    def status(_url):
        raise UpdateHttpError(404)

    with pytest.raises(UpdateHttpError):
        UpdateChecker(fetch=status).check(AppVersion("0.1"))


def test_unknown_fields_are_ignored():
    document = json.dumps(
        {
            "tag_name": "v0.2.0",
            "draft": False,
            "prerelease": False,
            "author": {"login": "zeroscrypt"},
            "assets": [
                {
                    "name": "binaural-0.2.0-linux-x64.tar.gz",
                    "size": 10,
                    "browser_download_url": "https://example.invalid/a.tar.gz",
                    "state": "uploaded",
                }
            ],
        }
    )
    release = UpdateChecker(fetch=lambda _url: document).latest_release()
    assert release.version == AppVersion("0.2.0")
    assert release.assets[0].size == 10


def test_one_malformed_asset_does_not_hide_the_release():
    """The lenient second pass keeps ``tag_name`` and drops only the broken asset."""
    document = json.dumps(
        {
            "tag_name": "v0.2.0",
            "assets": [
                {"name": "broken", "size": 1},
                {
                    "name": "binaural-0.2.0-linux-x64.tar.gz",
                    "browser_download_url": "https://example.invalid/a.tar.gz",
                },
            ],
        }
    )
    release = UpdateChecker(fetch=lambda _url: document).latest_release()
    assert release.tag_name == "v0.2.0"
    assert [asset.name for asset in release.assets] == ["binaural-0.2.0-linux-x64.tar.gz"]


def test_the_default_endpoint_is_this_repository():
    assert UpdateChecker().endpoint == DEFAULT_ENDPOINT
    assert (
        DEFAULT_ENDPOINT
        == "https://api.github.com/repos/zeroscrypt/binaural/releases/latest"
    )
    assert REQUEST_TIMEOUT > 0


def test_the_check_orders_versions_with_app_version():
    """The comparator is the one the version order implements, not a string sort."""
    checker_ = UpdateChecker(fetch=lambda _url: release_json())
    assert checker_.ordering(AppVersion("0.2.0"), AppVersion("0.10.0")) == -1
    assert checker_.ordering(AppVersion("0.1"), AppVersion("0.1.0")) == 0


def test_an_injected_comparator_is_the_one_used():
    """The seam exists so the comparison rule can be replaced, not bypassed."""
    always_newer = UpdateChecker(
        fetch=lambda _url: release_json(tag="v0.0.1"),
        compare=lambda left, right: 1,
    )
    assert always_newer.check(AppVersion("9.9.9")).kind is Availability.UPDATE_AVAILABLE