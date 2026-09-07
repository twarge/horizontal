"""Offline analysis bundles: standard scientific plots and linked schematic crops."""
from __future__ import annotations

import base64
import html
import hashlib
import json
import threading
from pathlib import Path
from typing import Any

_plot_lock = threading.Lock()  # Matplotlib's font/style caches are process-wide.


def write_report(report: dict[str, Any], target: Path, images: list[dict[str, Any]]) -> None:
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib import pyplot as plt

    data, kind = report["data"], report["kind"]
    plots = []
    with _plot_lock:
        if kind == "headroom":
            figure, axis = plt.subplots(figsize=(8, 4.5), layout="constrained")
            labels = [f"{item['component_id']}\n{item['kind']}" for item in data["limits"]]
            margins = [item["margin_v"] for item in data["limits"]]
            axis.barh(labels, margins, color=["#277a61" if value >= 0 else "#be4646" for value in margins])
            axis.axvline(0, color="#555555", linewidth=1)
            axis.set_xlabel("Declared limit margin (V)")
            axes = [axis]
        else:
            figure, axes = plt.subplots(2, 1, figsize=(8, 6), layout="constrained")
            frequencies = data["frequency_hz"]
            if kind == "transfer":
                axes[0].semilogx(frequencies, data["magnitude_db"])
                axes[0].set_ylabel("Gain (dB, V/V)")
                axes[1].semilogx(frequencies, data["phase_deg"])
                axes[1].set_ylabel("Phase (degrees)")
            elif kind == "noise":
                axes[0].loglog(frequencies, data["output_asd_v_rtHz"], label="Output")
                axes[0].set_ylabel("Amplitude density (V/√Hz)")
                for source, values in data["per_source_psd_v2_hz"].items():
                    axes[1].loglog(frequencies, values, label=source)
                axes[1].set_ylabel("Output PSD by source (V²/Hz)")
                if len(data["per_source_psd_v2_hz"]) <= 8: axes[1].legend(fontsize=7)
            else:
                for key in ("analog_magnitude", "digital_magnitude", "combined_magnitude"):
                    axes[0].semilogx(frequencies, data[key], label=key.replace("_", " "))
                axes[0].set_ylabel("Magnitude (V/V)")
                axes[0].legend(fontsize=8)
                if "alias_frequency_hz" in data:
                    axes[1].semilogy(data["alias_frequency_hz"], data["sampled_output_psd_v2_hz"])
                    axes[1].set_ylabel("Sampled output PSD (V²/Hz)")
                else:
                    axes[1].text(.5, .5, "Alias noise not requested", ha="center", transform=axes[1].transAxes)
            for axis in axes: axis.set_xlabel("Frequency (Hz)")
        for axis in axes: axis.grid(True, alpha=.2)
        figure.suptitle(f"{report['replay']['scenario']['name']} · {kind.replace('_', ' ')}")
        for extension in ("svg", "png"):
            filename = f"{kind}.{extension}"
            figure.savefig(target / filename, dpi=160)
            plots.append(filename)
        plt.close(figure)

    evidence = []
    for i, image in enumerate(images):
        filename = f"schematic-{i + 1}.png"
        png = base64.b64decode(image["png_base64"], validate=True)
        (target / filename).write_bytes(png)
        evidence.append({**{key: value for key, value in image.items() if key != "png_base64"}, "image": filename, "sha256": hashlib.sha256(png).hexdigest()})
    (target / "evidence.json").write_text(json.dumps({"components": report["evidence"], "images": evidence}, indent=2))
    esc = html.escape
    warnings = "".join(f"<li>{esc(warning)}</li>" for warning in report["warnings"])
    evidence_html = "".join(f'<figure><img src="{item["image"]}" alt="Captured schematic crop"><figcaption>{esc(json.dumps({k: v for k, v in item.items() if k != "image"}))}</figcaption></figure>' for item in evidence)
    if not evidence:
        evidence_html = "<p>No schematic images included. Stable component IDs, file hashes and JSON pointers are recorded in evidence.json and replay.json.</p>"
    (target / "report.html").write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Horizontal analysis</title>
<style>body{{max-width:980px;margin:40px auto;padding:0 24px;font:16px/1.6 system-ui;color:#20312e}}img{{max-width:100%}}pre,figcaption{{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}}a{{color:#186751}}h1{{line-height:1.2}}</style>
<h1>{esc(report['replay']['scenario']['name'])}: {esc(kind.replace('_', ' '))}</h1>
<p>Snapshot <code>{esc(report['provenance']['snapshot_id'])}</code></p>
<p><a href="result.json">Results and assumptions</a> · <a href="replay.json">Replay input</a> · <a href="scenario.json">Scenario</a> · <a href="{plots[0]}">Vector plot</a></p>
<img src="{plots[1]}" alt="Analysis plot"><ul>{warnings}</ul>
<h2>Schematic evidence</h2>{evidence_html}<h2>Provenance</h2><pre>{esc(json.dumps(report['provenance'], indent=2))}</pre>
<p>Model scope and numerical conventions are recorded in result.json. Replay with <code>python -m horizontal.analysis &lt; replay.json</code>.</p></html>''')
