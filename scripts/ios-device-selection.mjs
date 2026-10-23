export function selectPairedDevice(devices, { selector, family = "iPad" } = {}) {
  const paired = devices.filter((device) => device.connectionProperties?.pairingState === "paired");
  const matches = paired.filter((device) => {
    if (!selector) return device.hardwareProperties?.deviceType === family;
    return [device.identifier, device.hardwareProperties?.udid, device.deviceProperties?.name].includes(selector);
  });
  if (matches.length !== 1) {
    throw new Error(`${matches.length ? "Multiple" : "No"} paired ${selector ? "matching devices" : family + " devices"} found. Set FOX_IOS_DEVICE to an exact device ID or unique name.`);
  }
  if (selector && family === "iPhone" && matches[0].hardwareProperties?.deviceType !== "iPhone") {
    throw new Error("iPhone commands cannot target an iPad. Check FOX_IOS_DEVICE.");
  }
  return matches[0];
}
