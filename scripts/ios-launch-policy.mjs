export function iosLaunchArguments({ device, bundleId, environment = {}, forceRestart = false }) {
  const hasEnvironment = Object.keys(environment).length > 0;
  return [
    "devicectl", "device", "process", "launch", "--device", device,
    ...(forceRestart || hasEnvironment ? ["--terminate-existing"] : []),
    ...(hasEnvironment ? ["--environment-variables", JSON.stringify(environment)] : []),
    bundleId
  ];
}
