import importlib.util
import math
from pathlib import Path
from types import SimpleNamespace
import unittest

MODULE = Path(__file__).resolve().parents[2] / "scripts/pose_experiment_mediapipe.py"
spec = importlib.util.spec_from_file_location("experiment", MODULE)
experiment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(experiment)


def landmarks():
    return [SimpleNamespace(x=0.2 + i * 0.01, y=0.3, visibility=0.8, presence=0.7) for i in range(33)]


class MappingTests(unittest.TestCase):
    def test_y_flip_does_not_swap_anatomical_side(self):
        points = {p["joint"]: p for p in experiment.map_landmarks(landmarks())}
        self.assertAlmostEqual(points["leftShoulder"]["x"], 0.31)
        self.assertAlmostEqual(points["leftShoulder"]["y"], 0.7)
        self.assertAlmostEqual(points["rightShoulder"]["x"], 0.32)

    def test_confidence_is_conservative_adapter_not_calibrated_probability(self):
        self.assertEqual(experiment.map_landmarks(landmarks())[0]["confidence"], 0.7)

    def test_out_of_frame_point_is_not_clamped(self):
        values = landmarks()
        values[15].x = 1.2
        self.assertNotIn("leftWrist", [p["joint"] for p in experiment.map_landmarks(values)])

    def test_non_finite_point_is_rejected(self):
        values = landmarks()
        values[13].x = math.nan
        self.assertNotIn("leftElbow", [p["joint"] for p in experiment.map_landmarks(values)])

    def test_derived_joint_requires_both_current_parents(self):
        values = landmarks()
        values[12].y = -0.1
        self.assertNotIn("neck", [p["joint"] for p in experiment.map_landmarks(values)])

    def test_derived_midpoint_has_minimum_parent_confidence(self):
        values = landmarks()
        values[12].presence = 0.4
        points = {p["joint"]: p for p in experiment.map_landmarks(values)}
        self.assertAlmostEqual(points["neck"]["x"], 0.315)
        self.assertEqual(points["neck"]["confidence"], 0.4)

    def test_rejects_wrong_topology(self):
        with self.assertRaises(ValueError):
            experiment.map_landmarks(landmarks()[:20])


if __name__ == "__main__":
    unittest.main()
