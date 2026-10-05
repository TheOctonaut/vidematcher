"use strict";

const helperStatusElement = document.getElementById("helperStatus");
const startHintElement = document.getElementById("startHint");
const rescanButton = document.getElementById("rescanButton");
const openOptionsButton = document.getElementById("openOptionsButton");

initialize().catch(() => {
  showStartHint();
  setHelperStatus("Helper check failed.", false);
});

rescanButton.addEventListener("click", async () => {
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
});

openOptionsButton.addEventListener("click", () => {
  browser.runtime.openOptionsPage();
});

async function initialize() {
  try {
    const response = await browser.runtime.sendMessage({ type: "vidwebmatch:pingHelper" });
    if (response && response.ok) {
      const root = response.response && response.response.search_root ? ` (${response.response.search_root})` : "";
      setHelperStatus("Helper connected." + root, true);
      return;
    }

    const raw = response && response.message ? response.message : "";
    const message = interpretHelperError(raw);
    setHelperStatus(message, false);
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    setHelperStatus(interpretHelperError(details) || "Helper check failed.", false);
  }
}

function interpretHelperError(raw) {
  if (!raw || raw.trim() === "") {
    showStartHint();
    return "Helper is not running.";
  }
  if (/drive_unavailable|not accessible/i.test(raw)) {
    return raw + " — mount the drive and click Rescan.";
  }
  if (/could not be found|no such host|native messaging/i.test(raw)) {
    showStartHint();
    return "Helper is not running.";
  }
  showStartHint();
  return raw;
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
