"use strict";

const helperStatusElement = document.getElementById("helperStatus");
const rescanButton = document.getElementById("rescanButton");
const openOptionsButton = document.getElementById("openOptionsButton");

initialize().catch(() => {
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
      setHelperStatus("Helper connected.", true);
      return;
    }

    const message = response && response.message ? response.message : "Helper unavailable.";
    setHelperStatus(message, false);
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    setHelperStatus(details || "Helper check failed.", false);
  }
}

function setHelperStatus(message, ok) {
  helperStatusElement.textContent = message;
  helperStatusElement.classList.remove("ok");
  helperStatusElement.classList.remove("fail");
  helperStatusElement.classList.add(ok ? "ok" : "fail");
}
