import { describe, expect, it } from "vitest";
import { defaultSensorCapabilities, recommendedCountingMethod } from "../src";

describe("sensor counting boundary", () => {
  it("keeps manual counting as the default for rep targets", () => {
    expect(recommendedCountingMethod({ setIndex: 1, targetReps: 10, restSeconds: 90 }, defaultSensorCapabilities())).toBe("manual");
  });

  it("uses timer counting for duration targets before considering sensors", () => {
    expect(
      recommendedCountingMethod(
        { setIndex: 1, targetDurationSeconds: 45, restSeconds: 90 },
        { deviceMotion: true, accelerometer: true, camera: true, poseEstimation: true }
      )
    ).toBe("timer");
  });
});
