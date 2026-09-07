"""Bounded subprocess jobs; cancelling a numerical calculation cannot affect the editor."""
from __future__ import annotations

import csv
import json
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from .analysis import Scenario, Setup


class AnalysisJobs:
    def __init__(self):
        self._executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="horizontal-analysis")
        self._lock = threading.RLock()
        self._jobs: dict[str, dict[str, Any]] = {}

    def submit(self, kind: str, snapshot: dict[str, Any], scenario: Scenario, setup: Setup, timeout_s: float = 30) -> dict[str, Any]:
        if not 0 < timeout_s <= 60: raise ValueError("timeout_s must be in (0, 60]")
        request = {"kind": kind, "snapshot": snapshot, "scenario": scenario.model_dump(mode="json"), "setup": setup.model_dump(mode="json")}
        encoded = json.dumps(request, allow_nan=False)
        if len(encoded.encode()) > 32 * 1024 * 1024: raise ValueError("Analysis input exceeds 32 MiB")
        with self._lock:
            for id in list(self._jobs):
                if time.monotonic() - self._jobs[id]["created"] > 1800 and self._jobs[id]["state"] not in {"queued", "running"}: del self._jobs[id]
            if len(self._jobs) >= 32: raise ValueError("Analysis job capacity reached; discard old jobs")
            if sum(j["state"] in {"queued", "running"} for j in self._jobs.values()) >= 4: raise ValueError("Four analyses are already queued or running")
            id = str(uuid.uuid4())
            self._jobs[id] = {"job_id": id, "state": "queued", "kind": kind, "snapshot_id": snapshot["meta"]["snapshot_id"], "created": time.monotonic(), "process": None}
            self._executor.submit(self._run, id, encoded, timeout_s)
            return self.status(id)

    def _run(self, id: str, request: str, timeout: float):
        with self._lock:
            job = self._jobs.get(id)
            if job is None: return
            if job["state"] == "cancelled": return
            elapsed = time.monotonic() - job["created"]
            if elapsed >= timeout:
                job.update(state="failed", error={"code": "TIMEOUT", "message": "Analysis expired in the queue"})
                return
            try:
                process = subprocess.Popen([sys.executable, "-m", "horizontal.analysis"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            except OSError as error:
                job.update(state="failed", error={"code": "ANALYSIS_FAILED", "message": str(error)})
                return
            job.update(process=process, state="running")
        try:
            stdout, stderr = process.communicate(request, timeout=timeout - elapsed)
            if process.returncode:
                result = {"error": {"code": "ANALYSIS_FAILED", "message": "Analysis worker exited", "exit_code": process.returncode}}
            elif len(stdout) > 64 * 1024 * 1024:
                result = {"error": {"code": "RESULT_TOO_LARGE", "message": "Analysis response exceeds 64 MiB"}}
            else: result = json.loads(stdout)
            with self._lock:
                if job["state"] != "cancelled": job.update(state="failed" if "error" in result else "completed", **result)
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate()
            with self._lock:
                if job["state"] != "cancelled": job.update(state="failed", error={"code": "TIMEOUT", "message": "Analysis exceeded its total deadline"})
        except (OSError, ValueError) as error:
            with self._lock:
                if job["state"] != "cancelled": job.update(state="failed", error={"code": "ANALYSIS_FAILED", "message": str(error)})
        finally:
            with self._lock: job["process"] = None

    def status(self, id: str, include_result=False, include_replay=False) -> dict[str, Any]:
        with self._lock:
            if id not in self._jobs: raise ValueError("Unknown or expired analysis job")
            job = self._jobs[id]
            if job["state"] not in {"queued", "running"} and time.monotonic() - job["created"] > 1800:
                del self._jobs[id]
                raise ValueError("Unknown or expired analysis job")
            result = {k: v for k, v in job.items() if k not in {"created", "process", "result"}}
            if include_result and "result" in job:
                result["result"] = {k: v for k, v in job["result"].items() if include_replay or k != "replay"}
            return result

    def cancel(self, id: str) -> dict[str, Any]:
        with self._lock:
            if id not in self._jobs: raise ValueError("Unknown analysis job")
            job = self._jobs[id]
            if job["state"] in {"queued", "running"}:
                job["state"] = "cancelled"
                if job["process"] is not None: job["process"].terminate()
            return self.status(id)

    def discard(self, id: str):
        with self._lock:
            if id not in self._jobs: raise ValueError("Unknown analysis job")
            if self._jobs[id]["process"] is not None or self._jobs[id]["state"] == "queued":
                raise ValueError("Cancel the job and wait for its worker to stop before discarding it")
            del self._jobs[id]

    def export(self, id: str, directory: str, images: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        status = self.status(id, include_result=True, include_replay=True)
        if status["state"] != "completed": raise ValueError("Only a completed analysis can be exported")
        report = status["result"]
        project_path = Path(report["replay"]["snapshot"]["project"]["path"]).resolve()
        project_root = project_path if project_path.suffix == ".horizontal" else project_path.parent
        target = Path(directory).expanduser().resolve() / ("analysis-" + id)
        if target.is_relative_to(project_root): raise ValueError("Export analysis outside the project")
        target.mkdir(parents=True, exist_ok=False)
        (target / "replay.json").write_text(json.dumps(report["replay"], indent=2, allow_nan=False))
        (target / "result.json").write_text(json.dumps({k: v for k, v in report.items() if k != "replay"}, indent=2, allow_nan=False))
        scenario = {"schema_version": 1, "scenario": report["replay"]["scenario"], "setup": report["replay"]["setup"], "snapshot_id": report["provenance"]["snapshot_id"]}
        (target / "scenario.json").write_text(json.dumps(scenario, indent=2, allow_nan=False))
        data = report["data"]
        def write_columns(name: str, columns: dict[str, list]):
            with (target / name).open("w", newline="") as file:
                writer = csv.writer(file)
                writer.writerow(columns)
                writer.writerows(zip(*columns.values()))
        if "frequency_hz" in data:
            size = len(data["frequency_hz"])
            columns = {k: v for k, v in data.items() if isinstance(v, list) and len(v) == size and
                       k not in {"alias_frequency_hz", "sampled_output_psd_v2_hz", "minus_3db_crossings_hz"} and
                       all(isinstance(x, (int, float)) or x is None for x in v)}
            columns.update({f"output_psd_v2_hz[{source}]": values for source, values in data.get("per_source_psd_v2_hz", {}).items()})
            write_columns("sweep.csv", columns)
        if "alias_frequency_hz" in data:
            write_columns("alias-noise.csv", {key: data[key] for key in ["alias_frequency_hz", "sampled_output_psd_v2_hz"]})
        if "limits" in data:
            keys = ["component_id", "kind", "rating", "positive_net", "negative_net", "minimum_v", "maximum_v", "dc_v", "signal_peak_v", "margin_v", "maximum_input_peak_v", "passed"]
            write_columns("headroom.csv", {key: [row[key] for row in data["limits"]] for key in keys})
        from .analysis_report import write_report
        write_report(report, target, images or [])
        (target / "README.txt").write_text("Open report.html for plots and schematic evidence.\nReplay: python -m horizontal.analysis < replay.json\nAll model assumptions and schematic evidence are in result.json and replay.json.\nNumerical equality is assessed within floating-point tolerance.\n")
        return {"directory": str(target), "files": sorted(p.name for p in target.iterdir()), "snapshot_id": report["provenance"]["snapshot_id"]}

    def close(self):
        with self._lock:
            for id in self._jobs: self.cancel(id)
        self._executor.shutdown(wait=False, cancel_futures=True)
