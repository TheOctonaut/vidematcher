"use strict";

const helperStatusElement = document.getElementById("helperStatus");
const startHintElement = document.getElementById("startHint");
const rescanButton = document.getElementById("rescanButton");
const openOptionsButton = document.getElementById("openOptionsButton");
const mountDriveButton = document.getElementById("mountDriveButton");
const unmountDriveButton = document.getElementById("unmountDriveButton");
const driveStatusElement = document.getElementById("driveStatus");
const keepAliveStatusElement = document.getElementById("keepAliveStatus");

mountDriveButton.addEventListener("click", () => requestDriveControl("start"));
unmountDriveButton.addEventListener("click", () => {
  if (window.confirm("Unmount the drive? This may interrupt scans, playback or other applications using it.")) {
    requestDriveControl("stop");
  }
});

async function requestDriveControl(action) {
  mountDriveButton.disabled = true;
  unmountDriveButton.disabled = true;
  driveStatusElement.hidden = false;
  driveStatusElement.classList.remove("ok", "fail");
  driveStatusElement.textContent = action === "start" ? "Requesting mount..." : "Requesting unmount...";
  try {
    const response = await browser.runtime.sendMessage({ type: "vidwebmatch:driveControl", action });
    driveStatusElement.textContent = response && response.message ? response.message : "Drive control returned no response.";
    driveStatusElement.classList.add(response && response.ok ? "ok" : "fail");
    await initialize();
  } catch (error) {
    driveStatusElement.textContent = "Drive control failed: " + (error instanceof Error ? error.message : String(error));
    driveStatusElement.classList.add("fail");
  } finally {
    mountDriveButton.disabled = false;
    unmountDriveButton.disabled = false;
  }
}

initialize().catch(() => {
  showStartHint();
  setHelperStatus("Helper check failed.", false);
});

rescanButton.addEventListener("click", async () => {
  try {
    const response = await browser.runtime.sendMessage({
      type: "vidwebmatch:rescanActiveTab",
      forceRefresh: true
    });

    if (response && response.ok) {
      window.close();
      return;
    }

    const message = response && response.message ? response.message : "Failed to request rescan.";
    setHelperStatus(message, false);
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    setHelperStatus("Failed to request rescan: " + details, false);
  }
});

openOptionsButton.addEventListener("click", () => {
  browser.runtime.openOptionsPage();
});

async function initialize() {
  try {
    const value = await browser.storage.local.get("driveKeepAlive");
    const state = value.driveKeepAlive || {};
    keepAliveStatusElement.textContent = state.enabled
      ? "Drive keep-alive on: refreshed on watched page loads."
      : "Drive keep-alive off: click Mount drive to enable.";
    keepAliveStatusElement.classList.remove("ok", "fail");
    if (state.lastError) {
      keepAliveStatusElement.textContent += " Last drive request failed: " + state.lastError;
      keepAliveStatusElement.classList.add("fail");
    }
  } catch (error) {
    keepAliveStatusElement.textContent = "Could not read drive keep-alive state: " +
      (error instanceof Error ? error.message : String(error));
    keepAliveStatusElement.classList.add("fail");
  }
  startHintElement.style.display = "none";
  try {
    const response = await browser.runtime.sendMessage({ type: "vidwebmatch:pingHelper" });
    if (response && response.ok) {
      const root = response.response && response.response.search_root ? ` (${response.response.search_root})` : "";
      setHelperStatus("Helper connected." + root, true);
      return;
    }

    if (!response || !response.driveUnavailable) {
      showStartHint();
    }
    const message = response && response.message ? response.message : "Helper check returned no response.";
    setHelperStatus(message, false);
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    showStartHint();
    setHelperStatus("Could not check helper: " + details, false);
  }
}

function showStartHint() {
  if (startHintElement) {
    startHintElement.style.display = "";
  }
}

function setHelperStatus(message, ok) {
  helperStatusElement.textContent = message;
  helperStatusElement.classList.remove("ok");
  helperStatusElement.classList.remove("fail");
  helperStatusElement.classList.add(ok ? "ok" : "fail");
}
