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
  debounceMs: 400,
  batchSize: 150,
  maxCandidatesPerScan: 2000,
  nativeHostName: "com.theoctonaut.vidwebmatch"
};

let nextRequestId = 1;

browser.runtime.onInstalled.addListener(async () => {
  try {
    const current = await browser.storage.local.get("settings");
    const merged = mergeSettings(current.settings || {});
    await browser.storage.local.set({ settings: merged });
  } catch (_error) {
    // Keep background script alive even if initial settings sync fails.
  }
});

browser.runtime.onMessage.addListener((message, sender) => {
  return handleMessage(message, sender);
});

async function handleMessage(message, sender) {
  try {
    if (!message || typeof message.type !== "string") {
      return undefined;
    }

    if (message.type === "vidwebmatch:getSettings") {
      return getSettings();
    }

    if (message.type === "vidwebmatch:saveSettings") {
      return saveSettings(message.settings || {});
    }

    if (message.type === "vidwebmatch:scanRequest") {
      return handleScanRequest(message, sender);
    }

    if (message.type === "vidwebmatch:rescanActiveTab") {
      return triggerActiveTabRescan(Boolean(message.forceRefresh));
    }

    if (message.type === "vidwebmatch:pingHelper") {
      return pingHelper();
    }

    return undefined;
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    return { ok: false, message: details };
  }
}

function mergeSettings(partial) {
  const merged = Object.assign({}, DEFAULT_SETTINGS, partial || {});
  merged.urlPatterns = normalizePatterns(merged.urlPatterns);
  merged.batchSize = clampInteger(merged.batchSize, 1, 500, DEFAULT_SETTINGS.batchSize);
  merged.debounceMs = clampInteger(merged.debounceMs, 50, 5000, DEFAULT_SETTINGS.debounceMs);
  merged.maxCandidatesPerScan = clampInteger(
    merged.maxCandidatesPerScan,
    50,
    10000,
    DEFAULT_SETTINGS.maxCandidatesPerScan
  );
  merged.scanLinks = Boolean(merged.scanLinks);
  merged.scanVisibleText = Boolean(merged.scanVisibleText);
  merged.scanScopedTitles = Boolean(merged.scanScopedTitles);
  merged.producersList = normalizeStringList(merged.producersList);
  merged.performersList = normalizeStringList(merged.performersList);
  merged.dimStrings = normalizeStringList(merged.dimStrings);
  merged.dimRows = normalizeStringList(merged.dimRows);
  if (typeof merged.titleScopeSelector !== "string" || merged.titleScopeSelector.trim() === "") {
    merged.titleScopeSelector = DEFAULT_SETTINGS.titleScopeSelector;
  } else {
    merged.titleScopeSelector = merged.titleScopeSelector.trim();
  }
  if (typeof merged.nativeHostName !== "string" || merged.nativeHostName.trim() === "") {
    merged.nativeHostName = DEFAULT_SETTINGS.nativeHostName;
  }
  return merged;
}

async function getSettings() {
  const value = await browser.storage.local.get("settings");
  return mergeSettings(value.settings || {});
}

async function saveSettings(settings) {
  const merged = mergeSettings(settings);
  await browser.storage.local.set({ settings: merged });
  return { ok: true, settings: merged };
}

function normalizePatterns(value) {
  const items = Array.isArray(value) ? value : [value];
  const output = [];
  for (const item of items) {
    if (typeof item !== "string") {
      continue;
    }
    const trimmed = item.trim();
    if (trimmed.length > 0) {
      output.push(trimmed);
    }
  }
  if (output.length === 0) {
    return DEFAULT_SETTINGS.urlPatterns.slice();
  }
  return output;
}

function normalizeStringList(value) {
  const items = Array.isArray(value) ? value : [value];
  const output = [];
  const seen = new Set();
  for (const item of items) {
    if (typeof item !== "string") {
      continue;
    }
    const trimmed = item.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const key = trimmed.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      output.push(trimmed);
    }
  }
  return output;
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

function isUrlAllowed(url, patterns) {
  if (typeof url !== "string" || url.length === 0) {
    return false;
  }

  const candidates = buildUrlCandidates(url);
  for (const pattern of patterns) {
    if (pattern === "<all_urls>") {
      return true;
    }

    const regex = toMatchPatternRegex(pattern);
    if (!regex) {
      continue;
    }
    for (const candidate of candidates) {
      if (regex.test(candidate)) {
        return true;
      }
    }
  }

  return false;
}

function buildUrlCandidates(url) {
  const values = [url];
  try {
    const parsed = new URL(url);
    values.push(parsed.origin + parsed.pathname);
    values.push(parsed.origin + parsed.pathname + parsed.search);
  } catch (_error) {
    // Keep the raw URL candidate only.
  }
  return values;
}

function toMatchPatternRegex(pattern) {
  if (typeof pattern !== "string") {
    return null;
  }
  const raw = pattern.trim();
  const schemeSplit = raw.split("://");
  if (schemeSplit.length !== 2) {
    return null;
  }

  const schemePart = schemeSplit[0];
  const hostAndPath = schemeSplit[1];
  const slashIndex = hostAndPath.indexOf("/");
  const hostPart = slashIndex >= 0 ? hostAndPath.substring(0, slashIndex) : hostAndPath;
  const pathPart = slashIndex >= 0 ? hostAndPath.substring(slashIndex) : "/";

  let schemeRegex = "";
  if (schemePart === "*") {
    schemeRegex = "(http|https)";
  } else {
    schemeRegex = escapeRegex(schemePart);
  }

  let hostRegex = "";
  if (hostPart === "*") {
    hostRegex = ".*";
  } else if (hostPart.startsWith("*.")) {
    const base = escapeRegex(hostPart.substring(2));
    hostRegex = "([^/]+\\.)*" + base;
  } else {
    hostRegex = escapeRegex(hostPart);
  }

  const normalizedPath = pathPart.length > 0 ? pathPart : "/";
  const pathRegex = escapeRegex(normalizedPath).replace(/\\\*/g, ".*");
  const finalRegex = "^" + schemeRegex + "://" + hostRegex + pathRegex + "$";

  try {
    return new RegExp(finalRegex, "i");
  } catch (_error) {
    return null;
  }
}

function escapeRegex(input) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function handleScanRequest(message, sender) {
  const settings = await getSettings();
  const pageUrl = typeof message.pageUrl === "string" ? message.pageUrl : "";

  if (!isUrlAllowed(pageUrl, settings.urlPatterns)) {
    return {
      ok: true,
      skipped: true,
      reason: "url_not_matched",
      helperAvailable: true,
      results: []
    };
  }

  const allNames = Array.isArray(message.filenames) ? message.filenames : [];
  const uniqueByBase = new Map();
  for (const name of allNames) {
    if (typeof name !== "string") {
      continue;
    }
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const basename = getNormalizedBaseName(trimmed);
    if (!basename) {
      continue;
    }
    if (!uniqueByBase.has(basename)) {
      uniqueByBase.set(basename, trimmed);
    }
  }

  const deduped = Array.from(uniqueByBase.values());
  if (deduped.length === 0) {
    return {
      ok: true,
      skipped: true,
      reason: "no_candidates",
      helperAvailable: true,
      results: []
    };
  }

  const clamped = deduped.slice(0, settings.maxCandidatesPerScan);
  const batchSize = clampInteger(settings.batchSize, 1, 500, DEFAULT_SETTINGS.batchSize);
  const forceRefresh = Boolean(message.forceRefresh);

  try {
    const allResults = [];
    for (let i = 0; i < clamped.length; i += batchSize) {
      const batch = clamped.slice(i, i + batchSize);
      const payload = {
        type: "query_status",
        request_id: generateRequestId(),
        filenames: batch,
        force_refresh: forceRefresh && i === 0
      };
      const response = await sendNativeRequest(payload, settings.nativeHostName);
      if (!response || response.ok !== true || !Array.isArray(response.results)) {
        const messageText = response && response.message ? response.message : "Helper returned an invalid response.";
        throw new Error(messageText);
      }
      allResults.push(...response.results);
    }

    return {
      ok: true,
      skipped: false,
      helperAvailable: true,
      results: allResults
    };
  } catch (error) {
    return {
      ok: true,
      skipped: false,
      helperAvailable: false,
      error: error instanceof Error ? error.message : String(error),
      results: []
    };
  }
}

function getNormalizedBaseName(name) {
  const slashIndex = Math.max(name.lastIndexOf("/"), name.lastIndexOf("\\"));
  const leaf = slashIndex >= 0 ? name.substring(slashIndex + 1) : name;
  const dotIndex = leaf.lastIndexOf(".");
  const base = dotIndex >= 0 ? leaf.substring(0, dotIndex) : leaf;
  const trimmed = base.trim();
  if (trimmed.length === 0) {
    return "";
  }
  return trimmed.toLowerCase();
}

async function triggerActiveTabRescan(forceRefresh) {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  if (!tabs || tabs.length === 0) {
    return { ok: false, message: "No active tab found." };
  }

  const tab = tabs[0];
  if (!tab.id) {
    return { ok: false, message: "Active tab id is unavailable." };
  }

  try {
    await browser.tabs.sendMessage(tab.id, {
      type: "vidwebmatch:rescan",
      forceRefresh: Boolean(forceRefresh)
    });
    return { ok: true };
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    return { ok: false, message: details };
  }
}

async function pingHelper() {
  const settings = await getSettings();
  try {
    const response = await browser.runtime.sendNativeMessage(settings.nativeHostName, {
      type: "ping",
      request_id: generateRequestId()
    });
    return { ok: true, response };
  } catch (error) {
    const details = error instanceof Error ? error.message : String(error);
    return { ok: false, message: details };
  }
}

function generateRequestId() {
  nextRequestId += 1;
  return "req-" + String(Date.now()) + "-" + String(nextRequestId);
}

function sendNativeRequest(payload, hostName) {
  if (!payload || typeof payload.request_id !== "string") {
    return Promise.reject(new Error("Missing request_id in native request payload."));
  }
  return browser.runtime.sendNativeMessage(hostName, payload);
}
