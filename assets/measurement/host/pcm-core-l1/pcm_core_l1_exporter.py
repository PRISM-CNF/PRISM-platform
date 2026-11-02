#!/usr/bin/env python3

import argparse
import csv
import io
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Tuple


def load_env_file(path: str) -> Dict[str, str]:
    result: Dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result


class SampleState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.samples_by_metric: Dict[str, Dict[str, float]] = {}
        self.last_error = ""
        self.last_exit_code = 0
        self.last_elapsed_seconds = 0.0
        self.last_success_timestamp = 0.0
        self.last_attempt_timestamp = 0.0
        self.last_raw_output = ""

    def update_success(
        self,
        samples_by_metric: Dict[str, Dict[str, float]],
        elapsed_seconds: float,
        raw_output: str,
    ) -> None:
        now = time.time()
        with self.lock:
            self.samples_by_metric = {metric_name: dict(samples) for metric_name, samples in samples_by_metric.items()}
            self.last_error = ""
            self.last_exit_code = 0
            self.last_elapsed_seconds = elapsed_seconds
            self.last_success_timestamp = now
            self.last_attempt_timestamp = now
            self.last_raw_output = raw_output

    def update_failure(self, message: str, exit_code: int, raw_output: str) -> None:
        now = time.time()
        with self.lock:
            self.last_error = message
            self.last_exit_code = exit_code
            self.last_attempt_timestamp = now
            self.last_raw_output = raw_output

    def snapshot(self) -> Dict[str, object]:
        with self.lock:
            return {
                "samples_by_metric": {metric_name: dict(samples) for metric_name, samples in self.samples_by_metric.items()},
                "last_error": self.last_error,
                "last_exit_code": self.last_exit_code,
                "last_elapsed_seconds": self.last_elapsed_seconds,
                "last_success_timestamp": self.last_success_timestamp,
                "last_attempt_timestamp": self.last_attempt_timestamp,
                "last_raw_output": self.last_raw_output,
            }


def parse_pcm_output(output: str, metric_names: List[str]) -> Tuple[Dict[str, Dict[str, float]], float]:
    elapsed_seconds = 0.0
    csv_lines: List[str] = []
    capture = False

    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line.startswith("Time elapsed:"):
            parts = line.split()
            if len(parts) >= 4:
                try:
                    elapsed_seconds = float(parts[2]) / 1000.0
                except ValueError:
                    elapsed_seconds = 0.0
        if raw_line.startswith("Core,"):
            capture = True
        if capture:
            csv_lines.append(raw_line)

    if not csv_lines:
        raise ValueError("pcm-core output missing CSV section")

    reader = csv.DictReader(io.StringIO("\n".join(csv_lines)))
    if reader.fieldnames is None or "Core" not in reader.fieldnames:
        raise ValueError("pcm-core CSV missing Core column")
    for index, _metric_name in enumerate(metric_names):
        if f"Event{index}" not in reader.fieldnames:
            raise ValueError(f"pcm-core CSV missing Event{index} column")

    samples_by_metric: Dict[str, Dict[str, float]] = {metric_name: {} for metric_name in metric_names}
    for row in reader:
        cpu = (row.get("Core") or "").strip()
        if not cpu:
            continue
        if not cpu.isdigit():
            continue
        for index, metric_name in enumerate(metric_names):
            value = (row.get(f"Event{index}") or "").strip()
            if not value:
                continue
            try:
                samples_by_metric[metric_name][cpu] = float(value)
            except ValueError as exc:
                raise ValueError(f"invalid Event{index} value for cpu={cpu}: {value}") from exc

    for index, metric_name in enumerate(metric_names):
        if not samples_by_metric[metric_name]:
            raise ValueError(f"pcm-core CSV did not contain any Event{index} samples for {metric_name}")

    if elapsed_seconds <= 0.0:
        elapsed_seconds = 1.0

    return samples_by_metric, elapsed_seconds


def prometheus_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class MetricsHandler(BaseHTTPRequestHandler):
    exporter = None

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/healthz", "/health"):
            body = self.exporter.health_text().encode("utf-8")
            status = 200 if self.exporter.is_healthy() else 503
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        body = self.exporter.render_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class PCMCoreL1Exporter:
    def __init__(
        self,
        pcm_core_bin: str,
        event_specs: List[str],
        metric_names: List[str],
        listen_host: str,
        listen_port: int,
        sample_interval_sec: int,
        timeout_sec: int,
    ) -> None:
        self.pcm_core_bin = pcm_core_bin
        self.event_specs = event_specs
        self.metric_names = metric_names
        self.listen_host = listen_host
        self.listen_port = listen_port
        self.sample_interval_sec = sample_interval_sec
        self.timeout_sec = timeout_sec
        self.state = SampleState()
        self.stop_event = threading.Event()

    def run_sample_loop(self) -> None:
        while not self.stop_event.is_set():
            started = time.time()
            timeout = max(self.sample_interval_sec + self.timeout_sec, self.sample_interval_sec + 5)
            command = [self.pcm_core_bin]
            for event_spec in self.event_specs:
                command.extend(["-e", event_spec])
            command.extend(
                [
                    str(self.sample_interval_sec),
                    "-i=1",
                    "-csv=/dev/stdout",
                ]
            )
            try:
                completed = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
            except subprocess.TimeoutExpired as exc:
                self.state.update_failure(f"timeout after {timeout}s", 124, exc.stdout or "")
                self.stop_event.wait(self.sample_interval_sec)
                continue

            combined_output = "\n".join(part for part in [completed.stdout, completed.stderr] if part)
            if completed.returncode != 0:
                self.state.update_failure(
                    f"pcm-core exited with rc={completed.returncode}",
                    completed.returncode,
                    combined_output,
                )
                self.stop_event.wait(self.sample_interval_sec)
                continue

            try:
                samples_by_metric, elapsed_seconds = parse_pcm_output(combined_output, self.metric_names)
            except ValueError as exc:
                self.state.update_failure(str(exc), completed.returncode, combined_output)
                self.stop_event.wait(self.sample_interval_sec)
                continue

            self.state.update_success(samples_by_metric, elapsed_seconds, combined_output)

            spent = time.time() - started
            if spent < self.sample_interval_sec:
                self.stop_event.wait(self.sample_interval_sec - spent)

    def is_healthy(self) -> bool:
        snapshot = self.state.snapshot()
        if snapshot["last_success_timestamp"] == 0.0:
            return False
        max_age = max(float(self.sample_interval_sec * 3), float(self.sample_interval_sec + self.timeout_sec))
        return (time.time() - float(snapshot["last_success_timestamp"])) <= max_age

    def health_text(self) -> str:
        snapshot = self.state.snapshot()
        status = "ok" if self.is_healthy() else "degraded"
        return (
            f"status={status}\n"
            f"metric_names={','.join(self.metric_names)}\n"
            f"sample_interval_sec={self.sample_interval_sec}\n"
            f"last_success_timestamp={snapshot['last_success_timestamp']}\n"
            f"last_error={snapshot['last_error']}\n"
        )

    def render_metrics(self) -> str:
        snapshot = self.state.snapshot()
        now = time.time()
        lines = [
            "# HELP pcm_core_l1_exporter_up Whether the latest pcm-core L1 sample is healthy.",
            "# TYPE pcm_core_l1_exporter_up gauge",
            f"pcm_core_l1_exporter_up {1 if self.is_healthy() else 0}",
            "# HELP pcm_core_l1_exporter_last_success_timestamp_seconds Unix timestamp of the latest successful sample.",
            "# TYPE pcm_core_l1_exporter_last_success_timestamp_seconds gauge",
            f"pcm_core_l1_exporter_last_success_timestamp_seconds {snapshot['last_success_timestamp']:.3f}",
            "# HELP pcm_core_l1_exporter_last_attempt_timestamp_seconds Unix timestamp of the latest sample attempt.",
            "# TYPE pcm_core_l1_exporter_last_attempt_timestamp_seconds gauge",
            f"pcm_core_l1_exporter_last_attempt_timestamp_seconds {snapshot['last_attempt_timestamp']:.3f}",
            "# HELP pcm_core_l1_exporter_last_sample_elapsed_seconds Elapsed seconds reported by the latest successful pcm-core sample.",
            "# TYPE pcm_core_l1_exporter_last_sample_elapsed_seconds gauge",
            f"pcm_core_l1_exporter_last_sample_elapsed_seconds {snapshot['last_elapsed_seconds']:.6f}",
            "# HELP pcm_core_l1_exporter_configured_interval_seconds Configured sample interval in seconds.",
            "# TYPE pcm_core_l1_exporter_configured_interval_seconds gauge",
            f"pcm_core_l1_exporter_configured_interval_seconds {self.sample_interval_sec}",
            "# HELP pcm_core_l1_exporter_last_exit_code Exit code from the latest failed sample. Zero when the latest sample succeeded.",
            "# TYPE pcm_core_l1_exporter_last_exit_code gauge",
            f"pcm_core_l1_exporter_last_exit_code {snapshot['last_exit_code']}",
            "# HELP pcm_core_l1_exporter_last_sample_age_seconds Age of the latest successful sample in seconds.",
            "# TYPE pcm_core_l1_exporter_last_sample_age_seconds gauge",
            f"pcm_core_l1_exporter_last_sample_age_seconds {max(0.0, now - float(snapshot['last_success_timestamp'])):.6f}",
        ]

        samples_by_metric = snapshot["samples_by_metric"]
        for metric_name in self.metric_names:
            lines.append(
                f"# HELP {metric_name} Latest interval count collected by pcm-core for {metric_name}."
            )
            lines.append(f"# TYPE {metric_name} gauge")
            for cpu in sorted(samples_by_metric.get(metric_name, {}), key=lambda item: int(item)):
                value = samples_by_metric[metric_name][cpu]
                lines.append(f'{metric_name}{{cpu="{prometheus_escape(cpu)}"}} {value:.6f}')

        lines.append("")
        return "\n".join(lines)

    def serve(self) -> None:
        MetricsHandler.exporter = self
        server = ThreadingHTTPServer((self.listen_host, self.listen_port), MetricsHandler)
        server.daemon_threads = True

        sample_thread = threading.Thread(target=self.run_sample_loop, daemon=True)
        sample_thread.start()

        def _handle_signal(signum: int, _frame: object) -> None:
            self.stop_event.set()
            server.shutdown()

        signal.signal(signal.SIGTERM, _handle_signal)
        signal.signal(signal.SIGINT, _handle_signal)

        try:
            server.serve_forever(poll_interval=0.5)
        finally:
            self.stop_event.set()
            server.server_close()
            sample_thread.join(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Expose pcm-core L1 samples as Prometheus metrics.")
    parser.add_argument("--env-file", required=True, help="Path to KEY=VALUE environment file.")
    args = parser.parse_args()

    config = load_env_file(args.env_file)
    miss_event_spec = config.get("PCM_L1_MISS_EVENT_SPEC") or config.get("PCM_EVENT_SPEC")
    miss_metric_name = config.get("PCM_L1_MISS_METRIC_NAME") or config.get("PCM_METRIC_NAME")
    hit_event_spec = config.get("PCM_L1_HIT_EVENT_SPEC", "")
    hit_metric_name = config.get("PCM_L1_HIT_METRIC_NAME", "")

    event_specs: List[str] = []
    metric_names: List[str] = []
    if miss_event_spec and miss_metric_name:
        event_specs.append(miss_event_spec)
        metric_names.append(miss_metric_name)
    if hit_event_spec and hit_metric_name:
        event_specs.append(hit_event_spec)
        metric_names.append(hit_metric_name)
    if not event_specs:
        raise KeyError("missing PCM_L1_MISS_EVENT_SPEC/PCM_EVENT_SPEC configuration")

    exporter = PCMCoreL1Exporter(
        pcm_core_bin=config["PCM_CORE_BIN"],
        event_specs=event_specs,
        metric_names=metric_names,
        listen_host=config["PCM_LISTEN_HOST"],
        listen_port=int(config["PCM_LISTEN_PORT"]),
        sample_interval_sec=int(config["PCM_SAMPLE_INTERVAL_SEC"]),
        timeout_sec=int(config["PCM_TIMEOUT_SEC"]),
    )
    exporter.serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
