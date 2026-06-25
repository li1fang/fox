import type { SetRecord, SetTarget } from "./types.js";

export interface SensorCapabilitySnapshot {
  deviceMotion: boolean;
  accelerometer: boolean;
  camera: boolean;
  poseEstimation: boolean;
}

export function defaultSensorCapabilities(): SensorCapabilitySnapshot {
  return {
    deviceMotion: false,
    accelerometer: false,
    camera: false,
    poseEstimation: false
  };
}

export function recommendedCountingMethod(
  target: SetTarget | undefined,
  capabilities: SensorCapabilitySnapshot
): SetRecord["countingMethod"] {
  if (target?.targetDurationSeconds) {
    return "timer";
  }
  if (capabilities.poseEstimation) {
    return "pose_estimation";
  }
  if (capabilities.accelerometer) {
    return "accelerometer";
  }
  return "manual";
}
