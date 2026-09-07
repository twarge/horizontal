import copy
import math
import tempfile
import time
import unittest
from pathlib import Path

from horizontal.analysis import Scenario, Setup, Circuit, analyze, validate, K_B, filter_gain, ADCFilter, FilterStage
from horizontal.analysis_jobs import AnalysisJobs
from horizontal._native import HorizontalError

EVIDENCE = {"source": "user", "description": "Analytic test fixture"}


def fixture(capacitor=False):
    def component(id, refdes, a, b, value, unit):
        return {"id": id, "refdes": refdes, "no_populate": False,
                "electrical_value": {"status": "parsed", "value_si": value, "unit": unit},
                "pins": [{"gate_pin_path": "gate/1", "net_id": a}, {"gate_pin_path": "gate/2", "net_id": b}],
                "evidence": {"file": "block.json", "json_pointer": f"/components/{id}", "snapshot_id": "fixture"}}
    snapshot = {"meta": {"snapshot_id": "fixture", "source": "disk", "revision": "r1"},
                "project": {"path": "/tmp/fixture-project/Test.horizontal"}, "hierarchy_supported": True,
                "nets": [{"id": id} for id in ["in", "out", "gnd"]],
                "components": [component("r1", "R1", "in", "out", 1000, "ohm"),
                               component("r2", "C1" if capacitor else "R2", "out", "gnd", 1e-6 if capacitor else 1000, "F" if capacitor else "ohm")]}
    scenario = Scenario.model_validate({"reference_net": "gnd", "models": {"r1": {"kind": "resistor"}, "r2": {"kind": "capacitor" if capacitor else "resistor"}},
                                      "sources": [{"id": "input", "positive_net": "in", "negative_net": "gnd", "dc_v": 2, "evidence": EVIDENCE}]})
    setup = Setup.model_validate({"input_source": "input", "output_positive_net": "out", "output_negative_net": "gnd",
                                  "sweep": {"start_hz": 1, "stop_hz": 1000, "points": 32}})
    return snapshot, scenario, setup


class AnalysisTests(unittest.TestCase):
    def test_divider_and_reproducibility(self):
        snapshot, scenario, setup = fixture()
        first = analyze("transfer", snapshot, scenario, setup)
        second = analyze("transfer", snapshot, scenario, setup)
        self.assertEqual(first["result_sha256"], second["result_sha256"])
        self.assertEqual(first["provenance"], second["provenance"])
        self.assertTrue(all(abs(g - .5) < 1e-12 for g in first["data"]["magnitude"]))
        self.assertEqual(first["evidence"]["r1"]["json_pointer"], "/components/r1")

    def test_rc_pole_and_loaded_transfer(self):
        snapshot, scenario, setup = fixture(capacitor=True)
        circuit = Circuit(snapshot, scenario, setup)
        pole = 1 / (2 * math.pi * .001)
        self.assertAlmostEqual(abs(circuit.gain(pole)), 1 / math.sqrt(2), places=12)
        self.assertAlmostEqual(math.degrees(__import__('cmath').phase(circuit.gain(pole))), -45, places=10)
        loaded = scenario.model_copy(update={"loads": []})
        encoded = loaded.model_dump(); encoded["loads"] = [{"positive_net": "out", "negative_net": "gnd", "resistance_ohm": 1000, "evidence": EVIDENCE}]
        self.assertAlmostEqual(abs(Circuit(snapshot, Scenario.model_validate(encoded), setup).gain(0)), .5)

    def test_thermal_noise_known_parallel_resistance(self):
        snapshot, scenario, setup = fixture()
        data = analyze("noise", snapshot, scenario, setup)["data"]
        expected = 4 * K_B * 300 * 500
        self.assertAlmostEqual(data["output_psd_v2_hz"][0] / expected, 1, places=12)
        self.assertAlmostEqual(data["output_rms_v"] ** 2 / (expected * 999), 1, places=12)
        self.assertAlmostEqual(sum(x*x for x in data["per_source_rms_v"].values()) / data["output_rms_v"] ** 2, 1)

    def test_rc_integrated_noise_converges(self):
        snapshot, scenario, setup = fixture(capacitor=True)
        setup = Setup.model_validate({**setup.model_dump(), "sweep": {"start_hz": .01, "stop_hz": 1e7, "points": 1024}})
        data = analyze("noise", snapshot, scenario, setup)["data"]
        self.assertAlmostEqual(data["output_rms_v"] ** 2 / (K_B * 300 / 1e-6), 1, delta=.001)

    def test_population_and_missing_models(self):
        snapshot, scenario, setup = fixture()
        scenario.models.pop("r2")
        self.assertFalse(validate(snapshot, scenario, setup)["ready"])
        with self.assertRaises(HorizontalError): analyze("transfer", snapshot, scenario, setup)
        scenario.population["r2"] = False
        data = analyze("transfer", snapshot, scenario, setup)["data"]
        self.assertAlmostEqual(data["magnitude"][0], 1)

    def test_relay_requires_explicit_state(self):
        snapshot, scenario, setup = fixture()
        raw = scenario.model_dump()
        raw["models"]["r2"] = {"kind": "relay", "states": ["on", "off"], "latching": True,
                                "contacts": [{"pins": ["gate/1", "gate/2"], "closed_states": ["on"], "on_resistance_ohm": 1000}], "evidence": EVIDENCE}
        off = Scenario.model_validate(raw)
        self.assertFalse(validate(snapshot, off, setup)["ready"])
        off.relay_states["r2"] = "off"
        self.assertAlmostEqual(analyze("transfer", snapshot, off, setup)["data"]["magnitude"][0], 1)
        off.relay_states["r2"] = "on"
        self.assertAlmostEqual(analyze("transfer", snapshot, off, setup)["data"]["magnitude"][0], .5)

    def test_headroom_dc_bias_and_evidence(self):
        snapshot, scenario, setup = fixture()
        encoded = scenario.model_dump(); encoded["headroom_limits"] = [{"component_id": "r2", "positive_net": "out", "negative_net": "gnd",
            "minimum_v": 0, "maximum_v": 1.5, "kind": "adc_input", "rating": "guaranteed", "evidence": EVIDENCE}]
        setup.signal_peak_v = 1.2; setup.signal_frequency_hz = 100
        data = analyze("headroom", snapshot, Scenario.model_validate(encoded), setup)["data"]
        self.assertAlmostEqual(data["limiting"]["dc_v"], 1)
        self.assertAlmostEqual(data["limiting"]["margin_v"], -.1)
        self.assertFalse(data["limiting"]["passed"])

    def test_adc_sinc_response_delay_and_alias(self):
        snapshot, scenario, setup = fixture()
        model = ADCFilter.model_validate({"component_id": "r2", "converter": "fixture", "configuration": "moving average /4", "input_rate_hz": 8000,
            "stages": [{"kind": "sinc", "decimation": 4, "sinc_order": 1}], "evidence": EVIDENCE,
            "input_noise_psd_v2_hz": 1e-12, "noise_band_limit_hz": 4000})
        self.assertAlmostEqual(abs(filter_gain(model, 0)), 1)
        self.assertLess(abs(filter_gain(model, 2000)), 1e-12)
        setup.adc = model
        data = analyze("adc_filter", snapshot, scenario, setup)["data"]
        self.assertAlmostEqual(data["group_delay_s"], 3/16000)
        # Divider gain squared 1/4, moving-average noise power gain 1/4.
        self.assertAlmostEqual(data["sampled_output_rms_v"]**2 / (1e-12 * 4000 / 16), 1, places=10)

    def test_unsupported_and_bad_inputs_do_not_generate_numbers(self):
        snapshot, scenario, setup = fixture()
        snapshot["hierarchy_supported"] = False
        with self.assertRaises(HorizontalError): analyze("transfer", snapshot, scenario, setup)
        with self.assertRaises(ValueError): Setup.model_validate({**setup.model_dump(), "signal_peak_v": float('nan')})
        with self.assertRaises(ValueError): Scenario.model_validate({**scenario.model_dump(), "typo": 1})

    def test_filter_stability_and_model_identity_are_checked(self):
        for denominator in ([1.0, -1.0], [1.0, -1.1], [1.0, -2.0, .9]):
            with self.assertRaises(ValueError): FilterStage(kind="coefficients", denominator=denominator)
        FilterStage(kind="coefficients", denominator=[1.0, -1.5, .7])
        snapshot, scenario, setup = fixture()
        scenario.sources[0].id = "r1"; setup.input_source = "r1"
        with self.assertRaises(HorizontalError): analyze("transfer", snapshot, scenario, setup)

    def test_declared_amplifier_gain_and_partial_noise(self):
        snapshot, scenario, setup = fixture()
        snapshot["components"] = [{"id": "amp", "refdes": "U1", "no_populate": False,
            "pins": [{"gate_pin_path": "p", "net_id": "in"}, {"gate_pin_path": "n", "net_id": "gnd"}, {"gate_pin_path": "o", "net_id": "out"}]}]
        encoded = scenario.model_dump(); encoded["models"] = {"amp": {"kind": "amplifier", "positive_pin": "p", "negative_pin": "n", "output_pin": "o", "gain": 2.0, "evidence": EVIDENCE}}
        modeled = Scenario.model_validate(encoded)
        self.assertAlmostEqual(analyze("transfer", snapshot, modeled, setup)["data"]["magnitude"][0], 2)
        with self.assertRaises(HorizontalError): analyze("noise", snapshot, modeled, setup)
        modeled.allow_partial_noise = True
        self.assertEqual(analyze("noise", snapshot, modeled, setup)["data"]["completeness"], "partial")
        encoded["models"]["amp"].update(voltage_noise_v_rtHz=1e-9, current_noise_a_rtHz=0.0)
        noise = analyze("noise", snapshot, Scenario.model_validate(encoded), setup)["data"]
        self.assertAlmostEqual(noise["output_psd_v2_hz"][0] / 4e-18, 1)
        self.assertAlmostEqual(noise["input_referred_psd_v2_hz"][0] / 1e-18, 1)

    def test_worker_export_and_replay(self):
        snapshot, scenario, setup = fixture()
        jobs = AnalysisJobs()
        try:
            id = jobs.submit("transfer", snapshot, scenario, setup)["job_id"]
            deadline = time.monotonic() + 10
            while jobs.status(id)["state"] in {"queued", "running"} and time.monotonic() < deadline: time.sleep(.02)
            status = jobs.status(id, include_result=True, include_replay=True)
            self.assertEqual(status["state"], "completed", status)
            with tempfile.TemporaryDirectory() as directory:
                exported = jobs.export(id, directory)
                self.assertTrue((Path(exported["directory"]) / "replay.json").is_file())
                self.assertTrue((Path(exported["directory"]) / "transfer.svg").is_file())
                self.assertTrue((Path(exported["directory"]) / "report.html").is_file())
                replay = status["result"]["replay"]
                rerun = analyze(replay["kind"], replay["snapshot"], Scenario.model_validate(replay["scenario"]), Setup.model_validate(replay["setup"]))
                self.assertEqual(rerun["result_sha256"], status["result"]["result_sha256"])
        finally: jobs.close()


if __name__ == "__main__": unittest.main()
