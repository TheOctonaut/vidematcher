"use strict";

const BADGE_CLASS = "vidwebmatch-status-badge";
const BANNER_ID = "vidwebmatch-helper-banner";
const DIM_SPAN_ATTR = "data-vidwebmatch-dim";
const DIMROW_CLASS = "vidwebmatch-dimrow";
const HIDDENROW_CLASS = "vidwebmatch-row-hidden";
const HIGHLIGHT_ROW_CLASS = "vidwebmatch-highlight-row";
const HIDDEN_NONHIGHLIGHT_CLASS = "vidwebmatch-row-hidden-nonhighlight";
const DISMISS_BUTTON_CLASS = "vidwebmatch-row-dismiss-button";
const FLOATING_DISMISS_ID = "vidwebmatch-floating-dismiss";
const FLOATING_DISMISS_CLASS = "vidwebmatch-floating-dismiss-button";
const AVI_REGEX = /([A-Za-z0-9][A-Za-z0-9 _.\-]*\.avi)\b/gi;
const EXCLUDED_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEXTAREA"]);

let latestSettings = null;
let scanTimer = null;
let observer = null;
let scanning = false;
let queuedForceRefresh = false;
let nextNodeId = 1;
const nodeIds = new WeakMap();

let floatingDismissLockedUntil = Date.now() + 3000;
let floatingDismissLockTimer = null;

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    floatingDismissLockedUntil = Date.now() + 3000;
    clearInterval(floatingDismissLockTimer);
    floatingDismissLockTimer = null;
    if (latestSettings) {
      manageFloatingDismissButton(latestSettings);
    }
    scheduleScan(false, false);
  }
});

bootstrap().catch(() => {
  // Keep the page functional even if initialization fails.
});

browser.runtime.onMessage.addListener((message) => {
  if (!message || message.type !== "vidwebmatch:rescan") {
    return undefined;
  }
  scheduleScan(Boolean(message.forceRefresh), true);
  return Promise.resolve({ ok: true });
});

browser.runtime.onMessage.addListener((message) => {
  if (!message || message.type !== "vidwebmatch:showAddToListDialog") {
    return undefined;
  }
  showAddToListDialog(message.text || "");
  return Promise.resolve({ ok: true });
});

async function bootstrap() {
  latestSettings = await getSettings();
  installObserver();
  scheduleScan(false, true);
  // Once per document, independently of helper availability and DOM rescans.
  browser.runtime.sendMessage({ type: "vidwebmatch:pageLoaded" }).then((response) => {
    if (response && response.ok === false) {
      showBanner("Drive keep-alive failed: " + response.message);
    }
  }).catch((error) => {
    showBanner("Drive keep-alive failed: " + (error instanceof Error ? error.message : String(error)));
  });
}

async function getSettings() {
  try {
    const settings = await browser.runtime.sendMessage({ type: "vidwebmatch:getSettings" });
    return settings || {};
  } catch (_error) {
    return {};
  }
}

function installObserver() {
  if (observer) {
    observer.disconnect();
  }

  observer = new MutationObserver((records) => {
    if (shouldIgnoreMutationRecords(records)) {
      return;
    }
    scheduleScan(false, false);
  });

  observer.observe(document.documentElement || document.body, {
    childList: true,
    subtree: true,
    characterData: true
  });
}

function scheduleScan(forceRefresh, immediate) {
  queuedForceRefresh = queuedForceRefresh || forceRefresh;
  if (scanTimer) {
    clearTimeout(scanTimer);
    scanTimer = null;
  }

  const debounceMs = clampInteger(latestSettings && latestSettings.debounceMs, 50, 5000, 400);
  const delay = immediate ? 0 : debounceMs;
  scanTimer = setTimeout(() => {
    scanTimer = null;
    runScan().catch(() => {
      // Keep script resilient and non-fatal.
    });
  }, delay);
}

async function runScan() {
  if (scanning) {
    scheduleScan(false, false);
    return;
  }
  scanning = true;
  const forceRefresh = queuedForceRefresh;
  queuedForceRefresh = false;

  try {
    latestSettings = await getSettings();
    const extraction = extractCandidates(latestSettings);
    clearBanner();

    // Gather scoped nodes for title-based features (matching and dim/row actions).
    const titleSelector = normalizeSelector(latestSettings.titleScopeSelector, ".torrentNameInfo");
    const hasDimRows = Array.isArray(latestSettings.dimRows) && latestSettings.dimRows.length > 0;
    const hasDimStrings = Array.isArray(latestSettings.dimStrings) && latestSettings.dimStrings.length > 0;
    const hasDimDatePattern = Boolean(latestSettings.dimDatePattern);
    const hasDismissedTitles = Array.isArray(latestSettings.dismissedTitles) && latestSettings.dismissedTitles.length > 0;
    const hasFavourites = (Array.isArray(latestSettings.studiosList) && latestSettings.studiosList.length > 0)
      || (Array.isArray(latestSettings.actorsList) && latestSettings.actorsList.length > 0);
    const needsScopedNodes = Boolean(latestSettings.scanScopedTitles) || hasDimRows || hasDimStrings || hasDimDatePattern || hasDismissedTitles || hasFavourites;
    const allScopedNodes = needsScopedNodes ? Array.from(safeQuerySelectorAll(titleSelector)) : [];

    let statusByBase = null;
    let urlSkipped = false;
    if (extraction.uniqueFilenames.length > 0) {
      const response = await browser.runtime.sendMessage({
        type: "vidwebmatch:scanRequest",
        pageUrl: window.location.href,
        filenames: extraction.uniqueFilenames,
        forceRefresh
      });

      if (!response || response.ok !== true) {
        showBanner(response && response.message ? response.message : "helper unavailable - check extension popup");
      } else if (response.skipped) {
        urlSkipped = true;
      } else if (response.helperAvailable !== true) {
        const bannerText = response.error || (response.driveUnavailable
          ? "drive unavailable - mount drive and rescan"
          : "helper unavailable - check extension popup");
        showBanner(bannerText);
      } else {
        statusByBase = buildStatusMap(response.results || []);
      }
    }

    // Favourite badges and row highlights do not depend on the helper.
    if (!urlSkipped) {
      renderBadges(extraction.locations, statusByBase, latestSettings);
    }
    applyDimAnnotations(allScopedNodes, latestSettings);
    applyHighlightingToRows(urlSkipped ? [] : allScopedNodes, latestSettings);
    manageFloatingDismissButton(latestSettings);
  } finally {
    scanning = false;
  }
}

function extractCandidates(settings) {
  const scanLinks = Boolean(settings.scanLinks);
  const scanVisibleText = Boolean(settings.scanVisibleText);
  const scanScopedTitles = Boolean(settings.scanScopedTitles);
  const titleScopeSelector = normalizeSelector(settings.titleScopeSelector, ".torrentNameInfo");
  const maxCandidates = clampInteger(settings.maxCandidatesPerScan, 50, 10000, 2000);

  const locations = [];
  const byBase = new Map();
  if (!document.body) {
    return { locations, uniqueFilenames: [] };
  }

  if (scanLinks) {
    const links = document.querySelectorAll("a[href]");
    for (const link of links) {
      const candidates = [];
      candidates.push(...extractAviNames(link.textContent || ""));

      const hrefName = extractNameFromHref(link.getAttribute("href"));
      if (hrefName) {
        candidates.push(hrefName);
      }

      for (const candidate of candidates) {
        const base = getNormalizedBaseName(candidate);
        if (!base) {
          continue;
        }
        if (!byBase.has(base)) {
          byBase.set(base, candidate);
        }
        locations.push({
          filename: candidate,
          basename: base,
          anchorNode: link,
          sourceKind: "avi_name"
        });
      }

      if (byBase.size >= maxCandidates) {
        break;
      }
    }
  }

  if (scanVisibleText && byBase.size < maxCandidates) {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (!node || !node.parentElement) {
        continue;
      }
      const parentTag = node.parentElement.tagName;
      if (EXCLUDED_TAGS.has(parentTag)) {
        continue;
      }

      const names = extractAviNames(node.textContent || "");
      if (names.length === 0) {
        continue;
      }

      for (const name of names) {
        const base = getNormalizedBaseName(name);
        if (!base) {
          continue;
        }
        if (!byBase.has(base)) {
          byBase.set(base, name);
        }
        locations.push({
          filename: name,
          basename: base,
          anchorNode: node,
          sourceKind: "avi_name"
        });
      }

      if (byBase.size >= maxCandidates) {
        break;
      }
    }
  }

  if (scanScopedTitles && byBase.size < maxCandidates) {
    const scopedNodes = safeQuerySelectorAll(titleScopeSelector);
    for (const node of scopedNodes) {
      const titleText = getScopedTitleText(node);
      if (!titleText) {
        continue;
      }

      const syntheticFilename = titleText + ".avi";
      const base = getNormalizedBaseName(syntheticFilename);
      if (!base) {
        continue;
      }

      if (!byBase.has(base)) {
        byBase.set(base, syntheticFilename);
      }

      const badgeAnchor = getScopedTitleAnchor(node);
      locations.push({
        filename: titleText,
        basename: base,
        anchorNode: badgeAnchor,
        sourceKind: "scoped_title",
        scopedText: titleText
      });

      if (byBase.size >= maxCandidates) {
        break;
      }
    }
  }

  return {
    locations,
    uniqueFilenames: Array.from(byBase.values())
  };
}

function normalizeSelector(value, fallback) {
  if (typeof value !== "string") {
    return fallback;
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return fallback;
  }
  return trimmed;
}

function safeQuerySelectorAll(selector) {
  try {
    return document.querySelectorAll(selector);
  } catch (_error) {
    return [];
  }
}

function getScopedTitleAnchor(node) {
  if (!node || node.nodeType !== Node.ELEMENT_NODE) {
    return node;
  }
  if (node.tagName === "A") {
    return node;
  }
  const anchor = node.querySelector("a");
  return anchor || node;
}

function getScopedTitleText(node) {
  const anchor = getScopedTitleAnchor(node);
  const raw = anchor && typeof anchor.textContent === "string"
    ? anchor.textContent
    : (node && typeof node.textContent === "string" ? node.textContent : "");
  if (!raw) {
    return "";
  }

  let normalized = raw.replace(/\r?\n/g, " ");
  normalized = normalized.replace(/\s+/g, " ").trim();
  if (normalized.length === 0) {
    return "";
  }
  return normalized;
}

function getExtraBadgesForLocation(location, settings) {
  if (!location || location.sourceKind !== "scoped_title") {
    return [];
  }

  const text = location.scopedText || location.filename || "";
  if (!text) {
    return [];
  }

  const badges = [];
  const studioMatch = findListMatch(text, settings && settings.studiosList);
  if (studioMatch) {
    badges.push({
      kind: "studio",
      className: "tag-studio",
      text: "🎬⭐",
      title: "studio match: " + studioMatch
    });
  }

  const actorMatch = findListMatch(text, settings && settings.actorsList);
  if (actorMatch) {
    badges.push({
      kind: "actor",
      className: "tag-actor",
      text: "💃❤️",
      title: "actor match: " + actorMatch
    });
  }

  return badges;
}

function findListMatch(text, values) {
  if (!Array.isArray(values) || values.length === 0) {
    return "";
  }

  const normalizedText = normalizeLooseText(text);
  if (!normalizedText) {
    return "";
  }

  for (const rawValue of values) {
    if (typeof rawValue !== "string") {
      continue;
    }
    const trimmed = rawValue.trim();
    if (!trimmed) {
      continue;
    }
    const normalizedValue = normalizeLooseText(trimmed);
    if (!normalizedValue) {
      continue;
    }
    if (normalizedText.indexOf(normalizedValue) >= 0) {
      return trimmed;
    }
  }

  return "";
}

function normalizeLooseText(value) {
  const input = String(value || "").toLowerCase();
  return input.replace(/[.\-_\s]+/g, "");
}

function buildStatusMap(results) {
  const map = new Map();
  for (const item of results) {
    if (!item || typeof item.basename !== "string" || typeof item.status !== "string") {
      continue;
    }
    map.set(item.basename.toLowerCase(), item.status);
  }
  return map;
}

function renderBadges(locations, statusByBase, settings) {
  const seenKeys = new Set();
  const existingBadges = new Map();
  const currentBadges = document.querySelectorAll("." + BADGE_CLASS);
  for (const badge of currentBadges) {
    const key = badge.getAttribute("data-vidwebmatch-key");
    if (key) {
      existingBadges.set(key, badge);
    }
  }

  for (const location of locations || []) {
    const baseKey = getLocationKey(location);
    if (statusByBase) {
      const status = statusByBase.get(location.basename) || "missing";
      const statusKey = baseKey + "|status";
      seenKeys.add(statusKey);
      upsertBadge(existingBadges, location.anchorNode, statusKey, "status-" + status, status, location.filename + " -> " + status);
    }

    const extraBadges = getExtraBadgesForLocation(location, settings);
    for (const extra of extraBadges) {
      const extraKey = baseKey + "|" + extra.kind;
      seenKeys.add(extraKey);
      upsertBadge(existingBadges, location.anchorNode, extraKey, extra.className, extra.text, extra.title);
    }
  }

  for (const badge of existingBadges.values()) {
    const key = badge.getAttribute("data-vidwebmatch-key");
    if (!key || !seenKeys.has(key)) {
      badge.remove();
    }
  }

  function upsertBadge(existingBadges, anchorNode, key, className, text, title) {
    let badge = existingBadges.get(key);
    if (!badge) {
      badge = document.createElement("span");
      badge.className = BADGE_CLASS;
      badge.setAttribute("data-vidwebmatch-key", key);
      insertBadgeAfterNode(anchorNode, badge);
    }

    badge.className = BADGE_CLASS + " " + className;
    badge.textContent = text;
    badge.title = title;
    badge.setAttribute("data-vidwebmatch-key", key);
    existingBadges.delete(key);
  }
}

function applyHighlightingToRows(scopedNodes, settings) {
  const studios = settings && settings.studiosList;
  const actors = settings && settings.actorsList;
  const showOnlyHighlighted = Boolean(settings && settings.showOnlyHighlightedRows);

  const highlightRows = new Set();
  const plainRows = new Set();
  for (const node of scopedNodes || []) {
    const row = getDimTargetRow(node);
    if (!row) {
      continue;
    }
    const text = getScopedTitleText(node);
    if (text && (findListMatch(text, studios) || findListMatch(text, actors))) {
      highlightRows.add(row);
    } else {
      plainRows.add(row);
    }
  }

  // Only touch classes that actually change to avoid needless DOM churn.
  for (const row of document.querySelectorAll("." + HIGHLIGHT_ROW_CLASS)) {
    if (!highlightRows.has(row)) {
      row.classList.remove(HIGHLIGHT_ROW_CLASS);
    }
  }
  for (const row of document.querySelectorAll("." + HIDDEN_NONHIGHLIGHT_CLASS)) {
    if (!showOnlyHighlighted || highlightRows.has(row) || !plainRows.has(row)) {
      row.classList.remove(HIDDEN_NONHIGHLIGHT_CLASS);
    }
  }
  for (const row of highlightRows) {
    if (!row.classList.contains(HIGHLIGHT_ROW_CLASS)) {
      row.classList.add(HIGHLIGHT_ROW_CLASS);
    }
  }
  if (showOnlyHighlighted) {
    for (const row of plainRows) {
      if (!highlightRows.has(row) && !row.classList.contains(HIDDEN_NONHIGHLIGHT_CLASS)) {
        row.classList.add(HIDDEN_NONHIGHLIGHT_CLASS);
      }
    }
  }
}

function insertBadgeAfterNode(anchorNode, badge) {
  if (!anchorNode || !badge) {
    return;
  }

  const parentNode = anchorNode.parentNode;
  if (!parentNode) {
    return;
  }

  const nextNode = anchorNode.nextSibling;
  if (nextNode) {
    parentNode.insertBefore(badge, nextNode);
  } else {
    parentNode.appendChild(badge);
  }
}

function showBanner(text) {
  clearBanner();
  const banner = document.createElement("div");
  banner.id = BANNER_ID;
  banner.textContent = text;
  banner.style.position = "fixed";
  banner.style.right = "12px";
  banner.style.bottom = "12px";
  banner.style.padding = "6px 10px";
  banner.style.background = "#a00000";
  banner.style.color = "#ffffff";
  banner.style.borderRadius = "4px";
  banner.style.fontSize = "12px";
  banner.style.zIndex = "2147483647";
  banner.style.fontFamily = "Segoe UI, Arial, sans-serif";
  document.documentElement.appendChild(banner);
}

function clearBanner() {
  const existing = document.getElementById(BANNER_ID);
  if (existing) {
    existing.remove();
  }
}

function extractNameFromHref(href) {
  if (typeof href !== "string" || href.trim() === "") {
    return "";
  }

  try {
    const url = new URL(href, window.location.href);
    const pathname = decodeURIComponent(url.pathname || "");
    const slash = pathname.lastIndexOf("/");
    const leaf = slash >= 0 ? pathname.substring(slash + 1) : pathname;
    if (/\.avi$/i.test(leaf)) {
      return leaf;
    }
  } catch (_error) {
    return "";
  }

  return "";
}

function extractAviNames(text) {
  if (typeof text !== "string" || text.length === 0) {
    return [];
  }
  const matches = [];
  AVI_REGEX.lastIndex = 0;
  let match = AVI_REGEX.exec(text);
  while (match !== null) {
    matches.push(match[1]);
    match = AVI_REGEX.exec(text);
  }
  return matches;
}

function getNormalizedBaseName(filename) {
  const slashIndex = Math.max(filename.lastIndexOf("/"), filename.lastIndexOf("\\"));
  const leaf = slashIndex >= 0 ? filename.substring(slashIndex + 1) : filename;
  const dotIndex = leaf.lastIndexOf(".");
  const base = dotIndex >= 0 ? leaf.substring(0, dotIndex) : leaf;
  const trimmed = base.trim();
  if (trimmed.length === 0) {
    return "";
  }

  return trimmed.toLowerCase();
}

function getLocationKey(location) {
  const node = location && location.anchorNode ? location.anchorNode : null;
  if (!node) {
    return location.basename;
  }
  let nodeId = nodeIds.get(node);
  if (!nodeId) {
    nodeId = String(nextNodeId++);
    nodeIds.set(node, nodeId);
  }
  return nodeId + "|" + location.basename;
}

function shouldIgnoreMutationRecords(records) {
  if (!records || records.length === 0) {
    return true;
  }

  for (const record of records) {
    if (record.type === "characterData") {
      if (!isOurNode(record.target)) {
        return false;
      }
      continue;
    }

    const addedNodes = record.addedNodes ? Array.from(record.addedNodes) : [];
    const removedNodes = record.removedNodes ? Array.from(record.removedNodes) : [];
    for (const node of addedNodes.concat(removedNodes)) {
      if (!isOurNode(node)) {
        return false;
      }
    }
  }

  return true;
}

function isOurNode(node) {
  if (!node) {
    return true;
  }

  if (node.nodeType === Node.TEXT_NODE) {
    return isOurNode(node.parentNode);
  }

  if (node.nodeType !== Node.ELEMENT_NODE) {
    return false;
  }

  if (node.id === BANNER_ID) {
    return true;
  }

  if (node.classList && node.classList.contains(BADGE_CLASS)) {
    return true;
  }

  if (node.hasAttribute && node.hasAttribute(DIM_SPAN_ATTR)) {
    return true;
  }

  if (node.classList && node.classList.contains(DIMROW_CLASS)) {
    return true;
  }

  if (node.classList && node.classList.contains(HIGHLIGHT_ROW_CLASS)) {
    return true;
  }

  if (node.classList && node.classList.contains(HIDDEN_NONHIGHLIGHT_CLASS)) {
    return true;
  }

  if (node.classList && node.classList.contains(DISMISS_BUTTON_CLASS)) {
    return true;
  }

  if (node.id === FLOATING_DISMISS_ID) {
    return true;
  }

  if (node.classList && node.classList.contains(FLOATING_DISMISS_CLASS)) {
    return true;
  }

  if (node.tagName === "STYLE" && typeof node.textContent === "string" && node.textContent.indexOf(BADGE_CLASS) >= 0) {
    return true;
  }

  return false;
}

// --- Dim annotation helpers ---

function applyDimAnnotations(allScopedNodes, settings) {
  const scopedNodes = Array.isArray(allScopedNodes) ? allScopedNodes : [];

  const dimStrings = Array.isArray(settings && settings.dimStrings) ? settings.dimStrings.filter(Boolean) : [];
  const dimRows = Array.isArray(settings && settings.dimRows) ? settings.dimRows.filter(Boolean) : [];
  const dismissedTitles = Array.isArray(settings && settings.dismissedTitles) ? settings.dismissedTitles.filter(Boolean) : [];
  const dismissedTitleKeys = new Set();
  for (const item of dismissedTitles) {
    const key = normalizeTitleForExactMatch(item);
    if (key) {
      dismissedTitleKeys.add(key);
    }
  }
  const removeDimRows = Boolean(settings && settings.removeDimRows);
  const dimDatePattern = Boolean(settings && settings.dimDatePattern);

  // Disconnect observer while mutating so we don't trigger re-scans.
  const wasObserving = observer !== null;
  if (observer) {
    observer.disconnect();
  }

  try {
    const staleRows = document.querySelectorAll("." + DIMROW_CLASS + ", ." + HIDDENROW_CLASS);
    for (const row of staleRows) {
      row.classList.remove(DIMROW_CLASS);
      row.classList.remove(HIDDENROW_CLASS);
    }
    const staleDismissButtons = document.querySelectorAll("." + DISMISS_BUTTON_CLASS);
    for (const button of staleDismissButtons) {
      button.remove();
    }
    const staleDimSpans = document.querySelectorAll("[" + DIM_SPAN_ATTR + "]");
    for (const span of staleDimSpans) {
      if (span.parentNode) {
        span.parentNode.replaceChild(document.createTextNode(span.textContent || ""), span);
      }
    }

    for (const node of scopedNodes) {
      const rowTarget = getDimTargetRow(node);
      const titleText = getScopedTitleText(node);
      const titleKey = normalizeTitleForExactMatch(titleText);

      upsertDismissButton(node, titleText);

      // Dim/remove row: apply class on the parent table row when available.
      const isPatternRowMatch = dimRows.length > 0 && findListMatch(titleText, dimRows);
      const isDismissedExactMatch = titleKey && dismissedTitleKeys.has(titleKey);
      if (isPatternRowMatch || isDismissedExactMatch) {
        if (removeDimRows) {
          rowTarget.classList.add(HIDDENROW_CLASS);
        } else {
          rowTarget.classList.add(DIMROW_CLASS);
        }
      }

      // Dim strings: wrap matching substrings inside the anchor with low-opacity spans.
      const anchor = getScopedTitleAnchor(node);
      if (!anchor) {
        continue;
      }
      clearDimSpans(anchor);
      if (dimStrings.length > 0 || dimDatePattern) {
        applyDimStringsToElement(anchor, dimStrings, dimDatePattern);
      }
    }
  } finally {
    if (wasObserving) {
      installObserver();
    }
  }
}

function getDimTargetRow(node) {
  if (!node || node.nodeType !== Node.ELEMENT_NODE) {
    return node;
  }
  const row = node.closest("tr");
  return row || node;
}

function normalizeTitleForExactMatch(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.replace(/\s+/g, " ").trim().toLowerCase();
}

function upsertDismissButton(scopedNode, scopedTitle) {
  const anchor = getScopedTitleAnchor(scopedNode);
  if (!anchor || !anchor.parentNode) {
    return;
  }

  let button = null;
  const siblings = anchor.parentNode.querySelectorAll("." + DISMISS_BUTTON_CLASS);
  for (const candidate of siblings) {
    if (candidate.getAttribute("data-vidwebmatch-owner-id") === getNodeOwnerId(scopedNode)) {
      button = candidate;
      break;
    }
  }

  if (!button) {
    button = document.createElement("button");
    button.type = "button";
    button.className = DISMISS_BUTTON_CLASS;
    button.textContent = "x";
    button.title = "Dismiss this exact title";
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      const title = button.getAttribute("data-vidwebmatch-title") || "";
      dismissTitleFromPage(title).catch(() => {
        // Keep page functional even if dismiss persistence fails.
      });
    });
    insertBadgeAfterNode(anchor, button);
  }

  button.setAttribute("data-vidwebmatch-owner-id", getNodeOwnerId(scopedNode));
  button.setAttribute("data-vidwebmatch-title", scopedTitle || "");
}

function getNodeOwnerId(node) {
  let nodeId = nodeIds.get(node);
  if (!nodeId) {
    nodeId = String(nextNodeId++);
    nodeIds.set(node, nodeId);
  }
  return nodeId;
}

async function dismissTitleFromPage(rawTitle) {
  const normalized = typeof rawTitle === "string" ? rawTitle.replace(/\s+/g, " ").trim() : "";
  if (!normalized) {
    return;
  }
  const response = await browser.runtime.sendMessage({
    type: "vidwebmatch:addDismissedTitle",
    title: normalized
  });
  if (!response || response.ok !== true) {
    throw new Error("Failed to persist dismissed title.");
  }
  scheduleScan(false, true);
}

function manageFloatingDismissButton(settings) {
  const title = getFloatingDismissTitleFromDom();
  if (!title) {
    removeFloatingDismissButton();
    return;
  }

  const dismissedList = Array.isArray(settings && settings.dismissedTitles) ? settings.dismissedTitles : [];
  const isAlreadyDismissed = isTitleInDismissedList(title, dismissedList);
  upsertFloatingDismissButton(title, isAlreadyDismissed);
}

function getFloatingDismissTitleFromDom() {
  const headers = Array.from(document.querySelectorAll("h2.tdm-section-header__title"));
  for (const header of headers) {
    const marker = header.querySelector("i.fa.fa-file-text-o");
    if (!marker) {
      continue;
    }
    const title = normalizeHeaderDismissTitle(header.textContent || "");
    if (title) {
      return title;
    }
  }
  return "";
}

function normalizeHeaderDismissTitle(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function isTitleInDismissedList(title, dismissedList) {
  const target = normalizeTitleForExactMatch(title);
  if (!target) {
    return false;
  }
  for (const item of dismissedList) {
    if (normalizeTitleForExactMatch(item) === target) {
      return true;
    }
  }
  return false;
}

function upsertFloatingDismissButton(title, isDismissed) {
  let button = document.getElementById(FLOATING_DISMISS_ID);
  if (!button) {
    button = document.createElement("button");
    button.id = FLOATING_DISMISS_ID;
    button.type = "button";
    button.className = FLOATING_DISMISS_CLASS;
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      handleFloatingDismissClick(button).catch(() => {
        // Keep page usable if dismiss action fails.
      });
    });
    (document.documentElement || document.body).appendChild(button);
  }

  button.setAttribute("data-vidwebmatch-title", title);
  const displayTitle = getDisplayTitleText(title, 72);
  const locked = Date.now() < floatingDismissLockedUntil;

  function applyLockedLabel() {
    const remaining = Math.max(0, Math.ceil((floatingDismissLockedUntil - Date.now()) / 1000));
    button.disabled = true;
    button.style.opacity = "0.5";
    button.style.cursor = "not-allowed";
    if (isDismissed) {
      button.textContent = "Dismissed: " + displayTitle + " (" + remaining + "s)";
    } else {
      button.textContent = "Dismiss title: " + displayTitle + " (" + remaining + "s)";
    }
  }

  function applyUnlockedLabel() {
    button.disabled = false;
    button.style.opacity = "";
    button.style.cursor = "";
    if (isDismissed) {
      button.setAttribute("data-vidwebmatch-dismissed", "true");
      button.textContent = "Dismissed: " + displayTitle + " - click to close tab";
      button.title = "Already dismissed title: " + title + ". Click to close this tab.";
    } else {
      button.setAttribute("data-vidwebmatch-dismissed", "false");
      button.textContent = "Dismiss title: " + displayTitle;
      button.title = "Add this exact title to dismissed list: " + title;
    }
  }

  if (locked) {
    clearInterval(floatingDismissLockTimer);
    floatingDismissLockTimer = null;
    applyLockedLabel();
    floatingDismissLockTimer = setInterval(() => {
      if (Date.now() >= floatingDismissLockedUntil) {
        clearInterval(floatingDismissLockTimer);
        floatingDismissLockTimer = null;
        applyUnlockedLabel();
      } else {
        applyLockedLabel();
      }
    }, 500);
  } else {
    clearInterval(floatingDismissLockTimer);
    floatingDismissLockTimer = null;
    applyUnlockedLabel();
  }
}

async function handleFloatingDismissClick(button) {
  if (Date.now() < floatingDismissLockedUntil) {
    return;
  }
  const dismissed = button.getAttribute("data-vidwebmatch-dismissed") === "true";
  if (!dismissed) {
    const title = button.getAttribute("data-vidwebmatch-title") || "";
    await dismissTitleFromPage(title);
    const displayTitle = getDisplayTitleText(title, 72);
    button.setAttribute("data-vidwebmatch-dismissed", "true");
    button.textContent = "Dismissed: " + displayTitle + " - click to close tab";
    button.title = "Already dismissed title: " + title + ". Click to close this tab.";
    return;
  }

  await browser.runtime.sendMessage({ type: "vidwebmatch:closeActiveTab" });
}

function getDisplayTitleText(title, maxLength) {
  const normalized = normalizeHeaderDismissTitle(title);
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return normalized.substring(0, maxLength - 3) + "...";
}

function removeFloatingDismissButton() {
  const button = document.getElementById(FLOATING_DISMISS_ID);
  if (button) {
    button.remove();
  }
}

function clearDimSpans(container) {
  if (!container) {
    return;
  }
  const spans = container.querySelectorAll("[" + DIM_SPAN_ATTR + "]");
  for (const span of spans) {
    if (span.parentNode) {
      span.parentNode.replaceChild(document.createTextNode(span.textContent || ""), span);
    }
  }
  container.normalize();
}

function applyDimStringsToElement(element, dimStrings, includeDatePattern) {
  // Collect text nodes first (walking modifies the tree).
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  const textNodes = [];
  while (walker.nextNode()) {
    textNodes.push(walker.currentNode);
  }
  for (const textNode of textNodes) {
    applyDimStringsToTextNode(textNode, dimStrings, includeDatePattern);
  }
}

function applyDimStringsToTextNode(textNode, dimStrings, includeDatePattern) {
  const text = textNode.nodeValue || "";
  if (!text) {
    return;
  }

  const lowerText = text.toLowerCase();
  const intervals = [];

  if (includeDatePattern) {
    const datePattern = /\b\d{2}\s\d{2}\s\d{2}\b/g;
    let dateMatch = datePattern.exec(text);
    while (dateMatch !== null) {
      intervals.push([dateMatch.index, dateMatch.index + dateMatch[0].length]);
      dateMatch = datePattern.exec(text);
    }
  }

  for (const s of dimStrings) {
    if (typeof s !== "string" || !s) {
      continue;
    }
    const lowerS = s.toLowerCase();
    let idx = 0;
    while (idx < lowerText.length) {
      const pos = lowerText.indexOf(lowerS, idx);
      if (pos < 0) {
        break;
      }
      intervals.push([pos, pos + lowerS.length]);
      idx = pos + 1;
    }
  }

  if (intervals.length === 0) {
    return;
  }

  // Merge overlapping intervals.
  intervals.sort((a, b) => a[0] - b[0]);
  const merged = [[intervals[0][0], intervals[0][1]]];
  for (let i = 1; i < intervals.length; i++) {
    const last = merged[merged.length - 1];
    if (intervals[i][0] <= last[1]) {
      last[1] = Math.max(last[1], intervals[i][1]);
    } else {
      merged.push([intervals[i][0], intervals[i][1]]);
    }
  }

  const fragment = document.createDocumentFragment();
  let pos = 0;
  for (const interval of merged) {
    const start = interval[0];
    const end = interval[1];
    if (pos < start) {
      fragment.appendChild(document.createTextNode(text.slice(pos, start)));
    }
    const span = document.createElement("span");
    span.setAttribute(DIM_SPAN_ATTR, "true");
    span.textContent = text.slice(start, end);
    fragment.appendChild(span);
    pos = end;
  }
  if (pos < text.length) {
    fragment.appendChild(document.createTextNode(text.slice(pos)));
  }

  if (textNode.parentNode) {
    textNode.parentNode.replaceChild(fragment, textNode);
  }
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

function showAddToListDialog(text) {
  if (!text || typeof text !== "string") {
    return;
  }

  const trimmed = text.trim();
  if (!trimmed) {
    return;
  }

  // Create a simple modal dialog
  const modal = document.createElement("div");
  modal.id = "vidwebmatch-add-to-list-modal";
  modal.style.position = "fixed";
  modal.style.top = "0";
  modal.style.left = "0";
  modal.style.width = "100%";
  modal.style.height = "100%";
  modal.style.backgroundColor = "rgba(0, 0, 0, 0.5)";
  modal.style.zIndex = "2147483646";
  modal.style.display = "flex";
  modal.style.alignItems = "center";
  modal.style.justifyContent = "center";
  modal.style.fontFamily = "Segoe UI, Arial, sans-serif";

  const dialog = document.createElement("div");
  dialog.style.backgroundColor = "#2a2a2a";
  dialog.style.color = "#f0f0f0";
  dialog.style.borderRadius = "8px";
  dialog.style.padding = "20px";
  dialog.style.maxWidth = "400px";
  dialog.style.boxShadow = "0 4px 20px rgba(0, 0, 0, 0.7)";

  const title = document.createElement("h3");
  title.textContent = "Add to list";
  title.style.marginTop = "0";
  title.style.marginBottom = "12px";

  const textDisplay = document.createElement("div");
  textDisplay.textContent = "Text: " + trimmed;
  textDisplay.style.marginBottom = "16px";
  textDisplay.style.padding = "8px";
  textDisplay.style.backgroundColor = "#1a1a1a";
  textDisplay.style.borderRadius = "4px";
  textDisplay.style.wordBreak = "break-word";

  const listLabel = document.createElement("label");
  listLabel.textContent = "Choose a list:";
  listLabel.style.display = "block";
  listLabel.style.marginBottom = "8px";

  const select = document.createElement("select");
  select.style.width = "100%";
  select.style.padding = "8px";
  select.style.marginBottom = "16px";
  select.style.backgroundColor = "#1a1a1a";
  select.style.color = "#f0f0f0";
  select.style.border = "1px solid #555";
  select.style.borderRadius = "4px";

  const options = [
    { value: "studiosList", label: "Favourite producers" },
    { value: "actorsList", label: "Favourite performers" },
    { value: "dimStrings", label: "Dimmed strings" },
    { value: "dimRows", label: "Dimmed rows" }
  ];

  for (const opt of options) {
    const option = document.createElement("option");
    option.value = opt.value;
    option.textContent = opt.label;
    select.appendChild(option);
  }

  const buttons = document.createElement("div");
  buttons.style.display = "flex";
  buttons.style.gap = "8px";
  buttons.style.justifyContent = "flex-end";

  const cancelButton = document.createElement("button");
  cancelButton.textContent = "Cancel";
  cancelButton.style.padding = "8px 16px";
  cancelButton.style.backgroundColor = "#555";
  cancelButton.style.color = "#f0f0f0";
  cancelButton.style.border = "none";
  cancelButton.style.borderRadius = "4px";
  cancelButton.style.cursor = "pointer";
  cancelButton.addEventListener("click", () => {
    modal.remove();
  });

  const addButton = document.createElement("button");
  addButton.textContent = "Add";
  addButton.style.padding = "8px 16px";
  addButton.style.backgroundColor = "#0066cc";
  addButton.style.color = "#fff";
  addButton.style.border = "none";
  addButton.style.borderRadius = "4px";
  addButton.style.cursor = "pointer";
  addButton.addEventListener("click", async () => {
    const list = select.value;
    try {
      const settings = await browser.runtime.sendMessage({ type: "vidwebmatch:getSettings" });
      if (settings && Array.isArray(settings[list])) {
        if (!settings[list].includes(trimmed)) {
          settings[list].push(trimmed);
          await browser.runtime.sendMessage({
            type: "vidwebmatch:saveSettings",
            settings: settings
          });
        }
      }
      modal.remove();
      scheduleScan(false, true);
    } catch (error) {
      alert("Failed to add to list: " + (error instanceof Error ? error.message : String(error)));
    }
  });

  buttons.appendChild(cancelButton);
  buttons.appendChild(addButton);

  dialog.appendChild(title);
  dialog.appendChild(textDisplay);
  dialog.appendChild(listLabel);
  dialog.appendChild(select);
  dialog.appendChild(buttons);
  modal.appendChild(dialog);
  document.documentElement.appendChild(modal);
}

const style = document.createElement("style");
style.textContent = `
.${BADGE_CLASS} {
  display: inline-block;
  margin-left: 6px;
  margin-right: 4px;
  padding: 1px 6px;
  border-radius: 10px;
  font-size: 11px;
  line-height: 16px;
  font-family: Segoe UI, Arial, sans-serif;
  color: #fff;
  background: #4a4a4a;
  vertical-align: baseline;
}
.${BADGE_CLASS}.status-missing { background: #9b1c1c; }
.${BADGE_CLASS}.status-avi_only { background: #b36a00; }
.${BADGE_CLASS}.status-mp4_only { background: #0066cc; }
.${BADGE_CLASS}.status-both { background: #1f7a1f; }
.${BADGE_CLASS}.tag-studio { background: #5a2ca0; }
.${BADGE_CLASS}.tag-actor { background: #d63384; }
[${DIM_SPAN_ATTR}] { opacity: 0.35; }
.${DIMROW_CLASS} { opacity: 0.3; }
.${HIDDENROW_CLASS} { display: none !important; }
.${HIGHLIGHT_ROW_CLASS},
.${HIGHLIGHT_ROW_CLASS} > td,
.${HIGHLIGHT_ROW_CLASS} > th {
  background-color: #daa520 !important;
}
@media (prefers-color-scheme: light) {
  .${HIGHLIGHT_ROW_CLASS},
  .${HIGHLIGHT_ROW_CLASS} > td,
  .${HIGHLIGHT_ROW_CLASS} > th {
    background-color: #8b6914 !important;
  }
}
.${HIDDEN_NONHIGHLIGHT_CLASS} { display: none !important; }
.${DISMISS_BUTTON_CLASS} {
  margin-left: 6px;
  border: 1px solid #888;
  background: #202020;
  color: #ddd;
  border-radius: 10px;
  font-size: 11px;
  line-height: 1;
  padding: 1px 6px;
  cursor: pointer;
}
.${DISMISS_BUTTON_CLASS}:hover {
  background: #3a3a3a;
}
.${FLOATING_DISMISS_CLASS} {
  position: fixed;
  left: 14px;
  bottom: 14px;
  z-index: 2147483647;
  border: 1px solid #777;
  background: #1e1e1e;
  color: #f0f0f0;
  border-radius: 18px;
  padding: 12px 16px;
  font-size: 14px;
  line-height: 1.3;
  font-weight: 600;
  max-width: 520px;
  font-family: Segoe UI, Arial, sans-serif;
  cursor: pointer;
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.35);
  text-align: left;
}
.${FLOATING_DISMISS_CLASS}:hover {
  background: #303030;
}
`;
document.documentElement.appendChild(style);
