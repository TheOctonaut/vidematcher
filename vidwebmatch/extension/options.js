"use strict";

const DEFAULT_SETTINGS = {
  urlPatterns: ["*://*/*"],
  scanLinks: true,
  scanVisibleText: true,
  scanScopedTitles: true,
  titleScopeSelector: ".torrentNameInfo",
  producersList: [],
  performersList: [],
  dimStrings: [],
  dimRows: [],
  batchSize: 150,
  maxCandidatesPerScan: 2000,
  debounceMs: 400
};

const urlPatternsInput = document.getElementById("urlPatterns");
const scanLinksInput = document.getElementById("scanLinks");
const scanVisibleTextInput = document.getElementById("scanVisibleText");
const scanScopedTitlesInput = document.getElementById("scanScopedTitles");
const titleScopeSelectorInput = document.getElementById("titleScopeSelector");
const producersListInput = document.getElementById("producersList");
const performersListInput = document.getElementById("performersList");
const dimStringsInput = document.getElementById("dimStrings");
const dimRowsInput = document.getElementById("dimRows");
const batchSizeInput = document.getElementById("batchSize");
const maxCandidatesPerScanInput = document.getElementById("maxCandidatesPerScan");
const debounceMsInput = document.getElementById("debounceMs");
const saveButton = document.getElementById("saveButton");
const statusElement = document.getElementById("status");

saveButton.addEventListener("click", async () => {
  clearStatus();
  try {
    const settings = mergeSettings({
      urlPatterns: splitPatterns(urlPatternsInput.value),
      scanLinks: scanLinksInput.checked,
      scanVisibleText: scanVisibleTextInput.checked,
      scanScopedTitles: scanScopedTitlesInput.checked,
      titleScopeSelector: String(titleScopeSelectorInput.value || "").trim(),
      producersList: splitCommaList(producersListInput.value),
      performersList: splitCommaList(performersListInput.value),
      dimStrings: splitCommaList(dimStringsInput.value),
      dimRows: splitCommaList(dimRowsInput.value),
      batchSize: clampInteger(batchSizeInput.value, 1, 500, 150),
      maxCandidatesPerScan: clampInteger(maxCandidatesPerScanInput.value, 50, 10000, 2000),
      debounceMs: clampInteger(debounceMsInput.value, 50, 5000, 400)
    });
    await browser.storage.local.set({ settings });
    statusElement.textContent = "Saved.";
  } catch (_error) {
    statusElement.textContent = "Save failed.";
  }
});

load().catch(() => {
  statusElement.textContent = "Failed to load settings.";
});

async function load() {
  const value = await browser.storage.local.get("settings");
  const settings = mergeSettings(value.settings || {});
  urlPatternsInput.value = (settings.urlPatterns || []).join("\n");
  scanLinksInput.checked = Boolean(settings.scanLinks);
  scanVisibleTextInput.checked = Boolean(settings.scanVisibleText);
  scanScopedTitlesInput.checked = Boolean(settings.scanScopedTitles);
  titleScopeSelectorInput.value = String(settings.titleScopeSelector || ".torrentNameInfo");
  producersListInput.value = (settings.producersList || []).join(", ");
  performersListInput.value = (settings.performersList || []).join(", ");
  dimStringsInput.value = (settings.dimStrings || []).join(", ");
  dimRowsInput.value = (settings.dimRows || []).join(", ");
  batchSizeInput.value = String(settings.batchSize || 150);
  maxCandidatesPerScanInput.value = String(settings.maxCandidatesPerScan || 2000);
  debounceMsInput.value = String(settings.debounceMs || 400);
}

function mergeSettings(partial) {
  const merged = Object.assign({}, DEFAULT_SETTINGS, partial || {});
  if (Array.isArray(merged.urlPatterns)) {
    merged.urlPatterns = splitPatterns(merged.urlPatterns.join("\n"));
  } else {
    merged.urlPatterns = splitPatterns(String(merged.urlPatterns || ""));
  }
  merged.scanLinks = Boolean(merged.scanLinks);
  merged.scanVisibleText = Boolean(merged.scanVisibleText);
  merged.scanScopedTitles = Boolean(merged.scanScopedTitles);
  merged.titleScopeSelector = String(merged.titleScopeSelector || ".torrentNameInfo").trim() || ".torrentNameInfo";
  merged.producersList = dedupeList(merged.producersList);
  merged.performersList = dedupeList(merged.performersList);
  merged.dimStrings = dedupeList(merged.dimStrings);
  merged.dimRows = dedupeList(merged.dimRows);
  merged.batchSize = clampInteger(merged.batchSize, 1, 500, DEFAULT_SETTINGS.batchSize);
  merged.maxCandidatesPerScan = clampInteger(merged.maxCandidatesPerScan, 50, 10000, DEFAULT_SETTINGS.maxCandidatesPerScan);
  merged.debounceMs = clampInteger(merged.debounceMs, 50, 5000, DEFAULT_SETTINGS.debounceMs);
  return merged;
}

function splitPatterns(raw) {
  const output = [];
  const lines = String(raw).split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length > 0) {
      output.push(trimmed);
    }
  }
  return output;
}

function splitCommaList(raw) {
  const output = [];
  const items = String(raw).split(",");
  for (const item of items) {
    const trimmed = item.trim();
    if (trimmed.length > 0) {
      output.push(trimmed);
    }
  }
  return output;
}

function dedupeList(value) {
  const items = Array.isArray(value) ? value : splitCommaList(String(value || ""));
  const out = [];
  const seen = new Set();
  for (const item of items) {
    const trimmed = String(item || "").trim();
    if (!trimmed) {
      continue;
    }
    const key = trimmed.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      out.push(trimmed);
    }
  }
  return out;
}

function clampInteger(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value), 10);
  if (Number.isNaN(parsed)) {
    return fallback;
  }
  if (parsed < min) {
    return min;
  }
  if (parsed > max) {
    return max;
  }
  return parsed;
}

function clearStatus() {
  statusElement.textContent = "";
}
