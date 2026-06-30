"""Make the plugin's scripts/ directory importable so tests can `import agent_token`.

The engine lives in ../scripts; the tests live here in tests/. This shim adds the
scripts dir to sys.path at collection time (relocation glue only — no behavior change).
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
