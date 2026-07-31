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
  dismissedTitles: [],
  removeDimRows: false,
  dimDatePattern: false,
  batchSize: 150,
  maxCandidatesPerScan: 2000,
  debounceMs: 400
};

const urlPatternsInput = document.getElementById("urlPatterns");
const scanLinksInput = document.getElementById("scanLinks");
const scanVisibleTextInput = document.getElementById("scanVisibleText");
const scanScopedTitlesInput = document.getElementById("scanScopedTitles");
const dimDatePatternInput = document.getElementById("dimDatePattern");
const removeDimRowsInput = document.getElementById("removeDimRows");
const titleScopeSelectorInput = document.getElementById("titleScopeSelector");
const producersListEditor = createListEditor("producersList");
const performersListEditor = createListEditor("performersList");
const dimStringsEditor = createListEditor("dimStrings");
const dimRowsEditor = createListEditor("dimRows");
const copyDimRowsButton = document.getElementById("copyDimRowsButton");
const dismissedSearchInput = document.getElementById("dismissedSearchInput");
const dismissedMeta = document.getElementById("dismissedMeta");
const dismissedList = document.getElementById("dismissedList");
const dismissedPrevButton = document.getElementById("dismissedPrevButton");
const dismissedNextButton = document.getElementById("dismissedNextButton");
const dismissedPageInfo = document.getElementById("dismissedPageInfo");
const batchSizeInput = document.getElementById("batchSize");
const maxCandidatesPerScanInput = document.getElementById("maxCandidatesPerScan");
const debounceMsInput = document.getElementById("debounceMs");
const saveButton = document.getElementById("saveButton");
const statusElement = document.getElementById("status");
let isLoading = false;
let cachedDismissedTitles = [];
let dismissedFilterText = "";
let dismissedPageIndex = 0;
const DISMISSED_PAGE_SIZE = 40;

saveButton.addEventListener("click", async () => {
  clearStatus();
  try {
    await persistSettings(true, true);
    statusElement.textContent = "Saved.";
  } catch (_error) {
    statusElement.textContent = "Save failed.";
  }
});

copyDimRowsButton.addEventListener("click", async () => {
  clearStatus();
  try {
    dimRowsEditor.addPending();
    const terms = dimRowsEditor.getValues();
    if (terms.length === 0) {
      statusElement.textContent = "Nothing to copy.";
      return;
    }
    const filterText = terms.map((term) => "-" + term).join(" ");
    await navigator.clipboard.writeText(filterText);
    statusElement.textContent = "Copied.";
  } catch (_error) {
    statusElement.textContent = "Copy failed.";
  }
});

dismissedSearchInput.addEventListener("input", () => {
  dismissedFilterText = String(dismissedSearchInput.value || "").trim().toLowerCase();
  dismissedPageIndex = 0;
  renderDismissedTitles();
});

dismissedPrevButton.addEventListener("click", () => {
  if (dismissedPageIndex <= 0) {
    return;
  }
  dismissedPageIndex -= 1;
  renderDismissedTitles();
});

dismissedNextButton.addEventListener("click", () => {
  const pageCount = getDismissedPageCount();
  if (dismissedPageIndex >= pageCount - 1) {
    return;
  }
  dismissedPageIndex += 1;
  renderDismissedTitles();
});

dismissedList.addEventListener("click", (event) => {
  const target = event.target;
  if (!target || !(target instanceof Element)) {
    return;
  }
  const removeIndexRaw = target.getAttribute("data-dismissed-remove-index");
  if (removeIndexRaw === null) {
    return;
  }
  const index = Number.parseInt(removeIndexRaw, 10);
  if (Number.isNaN(index) || index < 0 || index >= cachedDismissedTitles.length) {
    return;
  }
  cachedDismissedTitles.splice(index, 1);
  saveListEdit();
  renderDismissedTitles();
});

load().catch(() => {
  statusElement.textContent = "Failed to load settings.";
});

async function load() {
  isLoading = true;
  try {
    const value = await browser.storage.local.get("settings");
    const settings = mergeSettings(value.settings || {});
    urlPatternsInput.value = (settings.urlPatterns || []).join("\n");
    scanLinksInput.checked = Boolean(settings.scanLinks);
    scanVisibleTextInput.checked = Boolean(settings.scanVisibleText);
    scanScopedTitlesInput.checked = Boolean(settings.scanScopedTitles);
    dimDatePatternInput.checked = Boolean(settings.dimDatePattern);
    removeDimRowsInput.checked = Boolean(settings.removeDimRows);
    titleScopeSelectorInput.value = String(settings.titleScopeSelector || ".torrentNameInfo");
    producersListEditor.setValues(settings.producersList || []);
    performersListEditor.setValues(settings.performersList || []);
    dimStringsEditor.setValues(settings.dimStrings || []);
    dimRowsEditor.setValues(settings.dimRows || []);
    cachedDismissedTitles = Array.isArray(settings.dismissedTitles) ? settings.dismissedTitles.slice() : [];
    dismissedPageIndex = 0;
    renderDismissedTitles();
    batchSizeInput.value = String(settings.batchSize || 150);
    maxCandidatesPerScanInput.value = String(settings.maxCandidatesPerScan || 2000);
    debounceMsInput.value = String(settings.debounceMs || 400);
  } finally {
    isLoading = false;
  }
}

function createListEditor(prefix) {
  const pillsContainer = document.getElementById(prefix + "Pills");
  const input = document.getElementById(prefix + "Input");
  const addButton = document.getElementById(prefix + "AddButton");
  let values = [];
  const changeHandlers = [];

  function setValues(nextValues) {
    values = dedupeList(nextValues);
    render();
  }

  function getValues() {
    return values.slice();
  }

  function render() {
    while (pillsContainer.firstChild) {
      pillsContainer.removeChild(pillsContainer.firstChild);
    }

    if (values.length === 0) {
      const empty = document.createElement("span");
      empty.className = "pill-empty";
      empty.textContent = "No entries";
      pillsContainer.appendChild(empty);
      return;
    }

    for (let i = 0; i < values.length; i++) {
      const value = values[i];
      const pill = document.createElement("span");
      pill.className = "pill";

      const text = document.createElement("span");
      text.textContent = value;
      pill.appendChild(text);

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "pill-remove";
      remove.textContent = "x";
      remove.title = "Remove";
      remove.setAttribute("data-remove-index", String(i));
      pill.appendChild(remove);

      pillsContainer.appendChild(pill);
    }
  }

  function addFromInput() {
    const raw = String(input.value || "").trim();
    if (!raw) {
      return false;
    }
    values = dedupeList(values.concat([raw]));
    input.value = "";
    render();
    notifyChanged();
    return true;
  }

  addButton.addEventListener("click", () => {
    addFromInput();
  });

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      addFromInput();
    }
  });

  pillsContainer.addEventListener("click", (event) => {
    const target = event.target;
    if (!target || !(target instanceof Element)) {
      return;
    }
    const rawIndex = target.getAttribute("data-remove-index");
    if (rawIndex === null) {
      return;
    }
    const index = Number.parseInt(rawIndex, 10);
    if (Number.isNaN(index) || index < 0 || index >= values.length) {
      return;
    }
    values.splice(index, 1);
    render();
    notifyChanged();
  });

  function notifyChanged() {
    for (const handler of changeHandlers) {
      handler();
    }
  }

  function onChange(handler) {
    if (typeof handler === "function") {
      changeHandlers.push(handler);
    }
  }

  render();

  return {
    getValues,
    setValues,
    addPending: addFromInput,
    onChange
  };
}

producersListEditor.onChange(() => {
  saveListEdit();
});
performersListEditor.onChange(() => {
  saveListEdit();
});
dimStringsEditor.onChange(() => {
  saveListEdit();
});
dimRowsEditor.onChange(() => {
  saveListEdit();
});

function saveListEdit() {
  if (isLoading) {
    return;
  }
  persistSettings(false, false).catch(() => {
    // Keep options UI usable if autosave fails.
  });
}

function getFilteredDismissedTitles() {
  if (!dismissedFilterText) {
    return cachedDismissedTitles.map((title, index) => ({ title, index }));
  }
  const out = [];
  for (let i = 0; i < cachedDismissedTitles.length; i++) {
    const title = cachedDismissedTitles[i];
    if (String(title).toLowerCase().indexOf(dismissedFilterText) >= 0) {
      out.push({ title, index: i });
    }
  }
  return out;
}

function getDismissedPageCount() {
  const total = getFilteredDismissedTitles().length;
  return Math.max(1, Math.ceil(total / DISMISSED_PAGE_SIZE));
}

function renderDismissedTitles() {
  const filtered = getFilteredDismissedTitles();
  const totalFiltered = filtered.length;
  const totalAll = cachedDismissedTitles.length;
  const pageCount = Math.max(1, Math.ceil(totalFiltered / DISMISSED_PAGE_SIZE));
  if (dismissedPageIndex >= pageCount) {
    dismissedPageIndex = pageCount - 1;
  }
  if (dismissedPageIndex < 0) {
    dismissedPageIndex = 0;
  }

  const pageStart = dismissedPageIndex * DISMISSED_PAGE_SIZE;
  const pageEnd = Math.min(pageStart + DISMISSED_PAGE_SIZE, totalFiltered);
  const pageItems = filtered.slice(pageStart, pageEnd);

  while (dismissedList.firstChild) {
    dismissedList.removeChild(dismissedList.firstChild);
  }

  if (pageItems.length === 0) {
    const empty = document.createElement("div");
    empty.className = "dismissed-empty";
    empty.textContent = totalAll === 0 ? "No dismissed titles." : "No dismissed titles match the filter.";
    dismissedList.appendChild(empty);
  } else {
    const fragment = document.createDocumentFragment();
    for (const item of pageItems) {
      const row = document.createElement("div");
      row.className = "dismissed-item";

      const text = document.createElement("span");
      text.className = "dismissed-item-text";
      text.textContent = item.title;
      text.title = item.title;
      row.appendChild(text);

      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "Remove";
      remove.setAttribute("data-dismissed-remove-index", String(item.index));
      row.appendChild(remove);

      fragment.appendChild(row);
    }
    dismissedList.appendChild(fragment);
  }

  if (dismissedFilterText) {
    dismissedMeta.textContent = String(totalAll) + " total, " + String(totalFiltered) + " matched filter";
  } else {
    dismissedMeta.textContent = String(totalAll) + " entries";
  }

  dismissedPageInfo.textContent = "Page " + String(dismissedPageIndex + 1) + " of " + String(pageCount);
  dismissedPrevButton.disabled = dismissedPageIndex <= 0;
  dismissedNextButton.disabled = dismissedPageIndex >= pageCount - 1;
}

function collectSettings(includePending) {
  if (includePending) {
    producersListEditor.addPending();
    performersListEditor.addPending();
    dimStringsEditor.addPending();
    dimRowsEditor.addPending();
  }

  return mergeSettings({
    urlPatterns: splitPatterns(urlPatternsInput.value),
    scanLinks: scanLinksInput.checked,
    scanVisibleText: scanVisibleTextInput.checked,
    scanScopedTitles: scanScopedTitlesInput.checked,
    dimDatePattern: dimDatePatternInput.checked,
    removeDimRows: removeDimRowsInput.checked,
    titleScopeSelector: String(titleScopeSelectorInput.value || "").trim(),
    producersList: producersListEditor.getValues(),
    performersList: performersListEditor.getValues(),
    dimStrings: dimStringsEditor.getValues(),
    dimRows: dimRowsEditor.getValues(),
    dismissedTitles: cachedDismissedTitles,
    batchSize: clampInteger(batchSizeInput.value, 1, 500, 150),
    maxCandidatesPerScan: clampInteger(maxCandidatesPerScanInput.value, 50, 10000, 2000),
    debounceMs: clampInteger(debounceMsInput.value, 50, 5000, 400)
  });
}

async function persistSettings(_showStatus, includePending) {
  const settings = collectSettings(includePending);
  await browser.storage.local.set({ settings });
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
  merged.dimDatePattern = Boolean(merged.dimDatePattern);
  merged.removeDimRows = Boolean(merged.removeDimRows);
  merged.titleScopeSelector = String(merged.titleScopeSelector || ".torrentNameInfo").trim() || ".torrentNameInfo";
  merged.producersList = dedupeList(merged.producersList);
  merged.performersList = dedupeList(merged.performersList);
  merged.dimStrings = dedupeList(merged.dimStrings);
  merged.dimRows = dedupeList(merged.dimRows);
  merged.dismissedTitles = dedupeList(merged.dismissedTitles);
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
