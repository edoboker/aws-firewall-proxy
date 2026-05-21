import json
import subprocess
from functools import lru_cache
from pathlib import Path

TERRAFORM_DIR = Path(__file__).resolve().parents[1] / "terraform"


@lru_cache(maxsize=1)
def load() -> dict:
    result = subprocess.run(
        ["terraform", f"-chdir={TERRAFORM_DIR}", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    )
    raw = json.loads(result.stdout)
    return {key: entry["value"] for key, entry in raw.items()}
