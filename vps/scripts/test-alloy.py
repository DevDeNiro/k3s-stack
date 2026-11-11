#!/usr/bin/env python3
"""Exercise the repository's Alloy log pipeline without a cluster or network.

Only Python 3, Docker, and a locally cached grafana/alloy:v1.21.3 are required.
All generated inputs, positions and outputs exist inside a disposable tmpfs.
"""

from pathlib import Path
import subprocess
import sys
import textwrap

values_path = Path(sys.argv[1] if len(sys.argv) > 1 else "vps/values/alloy.yaml")
image = "grafana/alloy:v1.21.3"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    values = values_path.read_text()
    content = textwrap.dedent(
        values.split("    content: |-\n", 1)[1].split("\ncontroller:", 1)[0]
    )
    validation = subprocess.run(
        ["docker", "run", "--rm", "-i", "--pull=never", "--network", "none",
         image, "validate", "/dev/stdin"],
        input=content, text=True, capture_output=True, timeout=40,
    )
    require(
        validation.returncode == 0,
        f"Alloy configuration validation failed:\n{validation.stderr}",
    )
    pipeline = content[
        content.index('loki.process "kubernetes_pods" {') :
        content.index('discovery.relabel "kubernetes_pods" {')
    ]
    original_receiver = "forward_to = [loki.write.default.receiver]"
    require(pipeline.count(original_receiver) == 1, "Unexpected process receiver")
    pipeline = pipeline.replace(
        original_receiver, "forward_to = [loki.echo.output.receiver]"
    )
    source = """\
loki.source.file "test" {
  targets = [
    { __path__ = "/tmp/positive.log", namespace = "app", container = "demo" },
    { __path__ = "/tmp/drop-local.log", namespace = "kube-system", container = "local-path-provisioner" },
    { __path__ = "/tmp/drop-metrics.log", namespace = "kube-system", container = "metrics-server" },
    { __path__ = "/tmp/keep.log", namespace = "default", container = "metrics-server" },
  ]
  forward_to = [loki.process.kubernetes_pods.receiver]
  legacy_positions_file = "/tmp/positions.yaml"
  file_match { enabled = true }
}
loki.echo "output" {}
"""
    config = source + "\n" + pipeline
    missing_config = config.replace("/tmp/positions.yaml", "/tmp/does-not-exist.yaml")
    old = "2026-01-01T00:00:00Z stdout F ALREADY_READ\n"
    entries = [
        "2026-01-01T00:00:01Z stdout F TEST_REDACT /stop/FAKE_PATH?code=FAKE_CODE&state=FAKE_STATE&session_state=FAKE_SESSION&id_token_hint=FAKE_HINT&ok=visible",
        "2026-01-01T00:00:02Z stdout F TEST_REPEAT /stop/FAKE_ONE /stop/FAKE_TWO?code=FAKE_A&code=FAKE_B",
        '2026-01-01T00:00:03Z stdout F {"level":"info","message":"KEEP_JSON /stop/FAKE_JSON","extra":"KEEP_METADATA"}',
        '2026-01-01T00:00:04Z stdout F {"log":"TEST_APP_LOG /stop/FAKE_INNER","extra":"METADATA_MAY_DISAPPEAR","stream":"stderr","time":"2026-01-01T00:00:05Z"}',
        '{"log":"TEST_DOCKER /stop/FAKE_DOCKER?state=FAKE_DOCKER_STATE\\n","stream":"stdout","time":"2026-01-01T00:00:06Z"}',
        "2026-01-01T00:00:07Z stdout P TEST_PARTIAL /stop/FAKE_",
        "2026-01-01T00:00:08Z stdout F PARTIAL",
    ]
    positive = old + "\n".join(entries) + "\n"
    appended = "2026-01-01T00:00:12Z stdout F AFTER_RESTART_MARKER\n"

    def heredoc(path, body, marker):
        require("\n" + marker + "\n" not in body, "Heredoc delimiter collision")
        return f"cat > {path} <<'{marker}'\n{body.rstrip()}\n{marker}\n"

    script = "".join(
        [
            heredoc("/tmp/config.alloy", config, "ALLOY_CONFIG"),
            heredoc("/tmp/no-legacy.alloy", missing_config, "MISSING_CONFIG"),
            heredoc("/tmp/positive.log", positive, "POSITIVE"),
            heredoc(
                "/tmp/drop-local.log",
                "2026-01-01T00:00:09Z stdout F DROP_LOCAL_MARKER\n",
                "DROP_LOCAL",
            ),
            heredoc(
                "/tmp/drop-metrics.log",
                "2026-01-01T00:00:10Z stdout F DROP_METRICS_MARKER\n",
                "DROP_METRICS",
            ),
            heredoc(
                "/tmp/keep.log",
                "2026-01-01T00:00:11Z stdout F KEEP_OTHER_NAMESPACE_MARKER\n",
                "KEEP",
            ),
            heredoc(
                "/tmp/positions.yaml",
                f'positions:\n  /tmp/positive.log: "{len(old.encode())}"\n',
                "POSITIONS",
            ),
            """\
cp /tmp/positions.yaml /tmp/original-positions.yaml
chmod 444 /tmp/positions.yaml
/usr/bin/timeout -s TERM 6 /bin/alloy run /tmp/config.alloy --storage.path=/tmp/data --server.http.listen-addr=127.0.0.1:12345 --disable-reporting > /tmp/first.out 2> /tmp/first.err
printf '%s\\n' "$?" > /tmp/first.status
cmp /tmp/positions.yaml /tmp/original-positions.yaml > /dev/null
printf '%s\\n' "$?" > /tmp/legacy-same.status
""",
            "printf '%s\\n' '"
            + appended.rstrip()
            + "' >> /tmp/positive.log\n",
            """\
chmod 644 /tmp/positions.yaml
cat > /tmp/positions.yaml <<'RESET_POSITIONS'
positions:
  /tmp/positive.log: "0"
RESET_POSITIONS
chmod 444 /tmp/positions.yaml
/usr/bin/timeout -s TERM 6 /bin/alloy run /tmp/config.alloy --storage.path=/tmp/data --server.http.listen-addr=127.0.0.1:12345 --disable-reporting > /tmp/second.out 2> /tmp/second.err
printf '%s\\n' "$?" > /tmp/second.status
/usr/bin/timeout -s TERM 6 /bin/alloy run /tmp/no-legacy.alloy --storage.path=/tmp/data-new --server.http.listen-addr=127.0.0.1:12345 --disable-reporting > /tmp/missing.out 2> /tmp/missing.err
printf '%s\\n' "$?" > /tmp/missing.status
printf 'PHASE_FIRST\\n'; cat /tmp/first.out /tmp/first.err
printf 'PHASE_SECOND\\n'; cat /tmp/second.out /tmp/second.err
printf 'PHASE_MISSING\\n'; cat /tmp/missing.out /tmp/missing.err
printf 'PHASE_STATUS\\n'; cat /tmp/first.status /tmp/second.status /tmp/missing.status /tmp/legacy-same.status
printf 'PHASE_POSITIONS\\n'; cat /tmp/data/loki.source.file.test/positions.yml
""",
        ]
    )
    command = [
        "docker",
        "run",
        "--rm",
        "-i",
        "--pull=never",
        "--network",
        "none",
        "--read-only",
        "--user",
        "65534:65534",
        "--tmpfs",
        "/tmp:rw,nosuid,nodev,mode=1777",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--entrypoint",
        "/bin/sh",
        image,
        "-s",
    ]
    result = subprocess.run(
        command, input=script, text=True, capture_output=True, timeout=60
    )
    require(result.returncode == 0, f"Container failed:\n{result.stderr}\n{result.stdout}")
    output = result.stdout
    first = output.split("PHASE_FIRST\n", 1)[1].split("PHASE_SECOND\n", 1)[0]
    second = output.split("PHASE_SECOND\n", 1)[1].split("PHASE_MISSING\n", 1)[0]
    missing = output.split("PHASE_MISSING\n", 1)[1].split("PHASE_STATUS\n", 1)[0]
    statuses = output.split("PHASE_STATUS\n", 1)[1].split("PHASE_POSITIONS\n", 1)[0]
    positions = output.split("PHASE_POSITIONS\n", 1)[1]

    def records(log):
        return [
            line
            for line in log.splitlines()
            if "component_id=loki.echo.output" in line and 'msg="received log entry"' in line
        ]

    first_records = records(first)
    second_records = records(second)
    missing_records = records(missing)
    joined = "\n".join(first_records)

    require(statuses.split() == ["124", "124", "124", "0"], f"Unexpected status: {statuses}")
    require("successfully converted legacy positions file" in first, "Legacy conversion missing")
    require("ALREADY_READ" not in joined, "Already-read line was replayed")
    require(len(first_records) == 7, f"Expected 7 output records, got {len(first_records)}")
    require("FAKE_" not in joined, "Synthetic sensitive value escaped redaction")
    require(
        "/stop/<redacted>?code=<redacted>&state=<redacted>&session_state=<redacted>&id_token_hint=<redacted>&ok=visible"
        in joined,
        "CRI URL masking failed",
    )
    require(
        "/stop/<redacted> /stop/<redacted>?code=<redacted>&code=<redacted>" in joined,
        "Repeated masking failed",
    )
    require("KEEP_JSON" in joined and "KEEP_METADATA" in joined, "JSON or masking failed")
    require("TEST_APP_LOG /stop/<redacted>" in joined, "Application JSON masking failed")
    require(
        "TEST_DOCKER /stop/<redacted>?state=<redacted>" in joined,
        "Docker parsing or masking failed",
    )
    require("TEST_PARTIAL /stop/<redacted>" in joined, "CRI partial-line masking failed")
    require("KEEP_OTHER_NAMESPACE_MARKER" in joined, "Unexpected drop outside kube-system")
    require("DROP_LOCAL_MARKER" not in joined, "local-path-provisioner was not dropped")
    require("DROP_METRICS_MARKER" not in joined, "kube-system metrics-server was not dropped")
    require(
        "will not convert the legacy positions file as the new positions file already exists" in second,
        "Existing Alloy positions not selected on restart",
    )
    require(
        len(second_records) == 1 and "AFTER_RESTART_MARKER" in second_records[0],
        "Restart replayed existing records or missed the new record",
    )
    require("no legacy positions file found" in missing, "Missing legacy case not observed")
    require(
        any("ALREADY_READ" in line for line in missing_records),
        "Missing positions did not replay from beginning",
    )
    expected_offset = len((positive + appended).encode())
    require(f'"{expected_offset}"' in positions, "Final Alloy offset was not persisted")

    print("PASS: complete Alloy configuration validated")
    print("PASS: CRI, Docker, partial lines, redaction, repeat masking, and drop rules")
    print("PASS: read-only Promtail positions imported; already-read entry skipped")
    print("PASS: persisted Alloy positions used on restart; only new record emitted")
    print("PASS: missing legacy positions start from the beginning")
    print(f"PASS: final Alloy offset persisted ({expected_offset} bytes)")
    if "METADATA_MAY_DISAPPEAR" not in joined:
        print(
            "WARNING: stage.docker flattened an application JSON object after stage.cri "
            "and dropped its extra field; this is not asserted as desired behavior."
        )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, IndexError, FileNotFoundError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
