import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="tokenmenyu-tests-") as directory:
    temporary = Path(directory)
    fixture = temporary / "codex"
    fixture.write_text(f"#!{sys.executable}\n" + '''
import json
import os
import sys
import time

mode = os.environ["CODEX_TEST_MODE"]
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"userAgent": "test"}
    elif method == "account/read":
        result = {"account": {"type": "chatgpt", "planType": "plus"}}
    elif method == "account/rateLimits/read":
        if mode == "closed":
            break
        if mode == "error":
            print(json.dumps({"id": request["id"], "error": {"code": -1, "message": "Usage unavailable"}}), flush=True)
            continue
        result = {"rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1800000000},
            "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1800600000},
            "credits": {"unlimited": False, "balance": "12.5"}
        }}
    response = json.dumps({"id": request["id"], "result": result}) + "\\n"
    if mode == "fragmented":
        sys.stdout.write(json.dumps({"method": "account/updated", "params": {}}) + "\\n" + response[:7])
        sys.stdout.flush()
        time.sleep(0.02)
        sys.stdout.write(response[7:])
        sys.stdout.flush()
    else:
        sys.stdout.write(response)
        sys.stdout.flush()
''')
    fixture.chmod(0o755)

    harness = temporary / "main.swift"
    harness.write_text('''
import SwiftUI

do {
    let usage = try CodexUsage.fetch()
    let output: [String: Any] = [
        "percentages": usage.snapshot.limits.map(\\.percent),
        "credits": usage.snapshot.extraUsage ?? "",
        "tier": usage.profile.tierLabel ?? ""
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
} catch {
    print(error.localizedDescription)
    exit(1)
}
''')
    executable = temporary / "codex-test"
    subprocess.run([
        "xcrun", "swiftc",
        str(ROOT / "Sources/TokenMenyu/UsageModel.swift"),
        str(ROOT / "Sources/TokenMenyu/CodexUsage.swift"),
        str(harness), "-module-cache-path", str(temporary / "modules"),
        "-o", str(executable)
    ], check=True)

    for mode in ["small", "fragmented", "closed", "error"]:
        environment = dict(os.environ, PATH=f"{temporary}:{os.environ.get('PATH', '')}", CODEX_TEST_MODE=mode)
        result = subprocess.run([str(executable)], env=environment, capture_output=True, text=True, timeout=10)
        if mode in ["small", "fragmented"]:
            assert result.returncode == 0, result.stderr + result.stdout
            assert json.loads(result.stdout) == {"percentages": [25, 60], "credits": "12.5", "tier": "Plus"}
        else:
            assert result.returncode == 1, result.stderr + result.stdout
            expected = "Codex app-server stopped" if mode == "closed" else "Usage unavailable"
            assert expected in result.stdout, result.stdout
        print(f"PASS: {mode}")
