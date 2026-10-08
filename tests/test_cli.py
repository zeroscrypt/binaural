"""``binaural --version``: the installer runs it to verify an install (install.sh).

It must print one line on stdout and return, without building a Qt application: a
window here would hang the installer's check until its timeout.
"""

from __future__ import annotations

import pytest

from binaural import __version__


@pytest.mark.parametrize("flag", ["--version", "-V"])
def test_version_prints_one_line_and_exits(flag, capsys, monkeypatch):
    from binaural import app

    def refuse(*_args, **_kwargs):
        raise AssertionError("--version must not build a Qt application")

    monkeypatch.setattr(app, "QApplication", refuse)
    assert app.main(["binaural", flag]) == 0
    assert capsys.readouterr().out == f"binaural {__version__}\n"
