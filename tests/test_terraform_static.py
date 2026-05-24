import shutil
import subprocess
from pathlib import Path

import pytest

TF_DIR = Path(__file__).resolve().parents[1] / "terraform"

pytestmark = pytest.mark.skipif(
    shutil.which("terraform") is None, reason="terraform not on PATH"
)


def _terraform(*args) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["terraform", f"-chdir={TF_DIR}", *args],
        capture_output=True,
        text=True,
    )


def test_terraform_fmt():
    result = _terraform("fmt", "-check", "-recursive")
    assert result.returncode == 0, (
        "terraform fmt would reformat these files:\n" + result.stdout
    )


def test_terraform_validate():
    if not (TF_DIR / ".terraform").exists():
        pytest.skip("terraform not initialized (run 'terraform init')")
    result = _terraform("validate")
    assert result.returncode == 0, (
        f"terraform validate failed:\n{result.stdout}\n{result.stderr}"
    )
