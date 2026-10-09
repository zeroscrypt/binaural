"""Guards on the properties the CI matrix depends on.

These are not tests of the application. They pin the two things that silently
turned a green workflow red, both of which are invisible in a passing run and
only visible as a broken one.

**Why ``--forked`` is not optional on Linux.** shiboken hands `None` back to
CPython without balancing its reference count for Qt objects it creates, so a
long-lived process that builds and destroys many widgets drives that count to
zero and the interpreter aborts:

    Fatal Python error: none_dealloc: deallocating None
    Aborted (core dumped)          # exit 134

It is an upstream bug, reproducible in isolation with nothing but a
``QComboBox`` in a loop, and the fix has not shipped. What the project controls
is how many Qt objects a single process ever sees, and `--forked` bounds that to
one test. These tests fail if that is ever dropped, because the symptom — a
matrix job dying at test 74 of 596 with a green traceback right up to it — points
nowhere near its cause.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CI = ROOT / ".github" / "workflows" / "ci.yml"


def _is_linux() -> bool:
    return sys.platform.startswith("linux")


def _ci_text() -> str:
    return CI.read_text(encoding="utf-8")


# --------------------------------------------------------------- --forked gate


def test_linux_ci_jobs_run_pytest_forked():
    """Every Linux pytest step must isolate tests into their own process."""
    text = _ci_text()
    # Steps that run the suite on Linux, and so inherit the interpreter abort.
    linux_steps = re.findall(r"run:\s*(python -m pytest[^\n]*)", text)
    assert linux_steps, "expected to find the pytest invocations in ci.yml"

    linux_only = [
        line for line in linux_steps if "--forked" in line
    ]
    assert linux_only, (
        "no pytest step passes --forked; on Linux the suite will abort with "
        "'none_dealloc: deallocating None' partway through the run"
    )


def test_the_forked_flag_is_not_applied_to_macos():
    """Cocoa is not fork-safe: ``--forked`` segfaults on macOS."""
    text = _ci_text()
    # The macOS steps are the ones guarded by `runner.os == 'macOS'`.
    macos_blocks = re.findall(
        r"if: runner\.os == 'macOS'\s*\n\s*run:\s*(python -m pytest[^\n]*)", text
    )
    assert macos_blocks, "expected a macOS-guarded pytest step in ci.yml"
    for line in macos_blocks:
        assert "--forked" not in line, (
            f"--forked is not fork-safe on macOS and will segfault: {line!r}"
        )


def test_pytest_forked_is_a_declared_dependency():
    """A CI step cannot rely on a plugin the project does not declare."""
    pyproject = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert "pytest-forked" in pyproject, (
        "--forked is used by CI but pytest-forked is not in [project.optional-"
        "dependencies].dev"
    )


# ----------------------------------------------------------------- Qt offscreen


def test_ci_pins_the_offscreen_platform():
    """Qt needs a platform plugin before any window exists; offscreen is it.

    Without this the Linux jobs depend on a display the runner does not have,
    and Qt's failure mode is `qFatal` -> abort, not a test failure.
    """
    assert "QT_QPA_PLATFORM" in _ci_text()
    assert "offscreen" in _ci_text()


@pytest.mark.skipif(not _is_linux(), reason="the abort is Linux-only")
def test_offscreen_creates_a_usable_qapplication():
    """The platform CI relies on actually loads here.

    A wrong plugin name does not produce a pytest error: Qt aborts the
    interpreter while constructing `QApplication`, which takes the whole run
    with it and reports nothing about the cause.
    """
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import os\n"
            "os.environ['QT_QPA_PLATFORM'] = 'offscreen'\n"
            "from PySide6.QtWidgets import QApplication, QLabel\n"
            "app = QApplication([])\n"
            "label = QLabel('probe')\n"
            "label.show()\n"
            "app.processEvents()\n"
            "print(label.text())\n",
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, (
        "QApplication could not be constructed under the offscreen platform:\n"
        f"{result.stderr[-2000:]}"
    )
    assert "probe" in result.stdout