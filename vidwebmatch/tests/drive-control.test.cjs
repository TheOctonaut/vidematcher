const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const extensionDir = path.join(__dirname, "..", "extension");
const popupUrl = "moz-extension://test/popup.html";

function createHost(settings = { baseUrl: "https://example.test/jellymw/", key: "test key&value" }) {
  const state = { requests: [], settings, timers: [], storage: {} };
  const context = vm.createContext({
    URL, AbortController, console,
    setTimeout(callback, delay) {
      state.timers.push({ callback, delay });
      return state.timers.length;
    },
    clearTimeout() {},
    async fetch(url, options) {
      state.requests.push({ url, options });
      if (state.fetch) {
        return state.fetch(url, options);
      }
      return { ok: true, async json() { return { mounted: true }; } };
    },
    browser: {
      contextMenus: { onClicked: { addListener() {} } },
      runtime: {
        getURL(file) { return "moz-extension://test/" + file; },
        onInstalled: { addListener() {} },
        onMessage: { addListener() {} }
      },
      storage: {
        local: {
          async get(key) {
            return key === "driveControl" ? { driveControl: state.settings } : { [key]: state.storage[key] };
          },
          async set(values) { Object.assign(state.storage, values); }
        }
      }
    }
  });
  for (const file of ["drive-control.js", "background.js"]) {
    vm.runInContext(fs.readFileSync(path.join(extensionDir, file), "utf8"), context);
  }
  return { context, state, request: action => context.handleMessage(
    { type: "vidwebmatch:driveControl", action }, { url: popupUrl }
  ) };
}

test("start/stop use the configured path and encode keys without cookies or redirects", async () => {
  const host = createHost();
  for (const action of ["start", "stop"]) {
    const response = await host.request(action);
    assert.equal(response.ok, true);
    const request = host.state.requests.at(-1);
    const url = new URL(request.url);
    assert.equal(url.pathname, "/jellymw/" + action);
    assert.equal(url.searchParams.get("key"), host.state.settings.key);
    assert.equal(request.options.method, "GET");
    assert.equal(request.options.credentials, "omit");
    assert.equal(request.options.redirect, "error");
    assert.equal(request.options.cache, "no-store");
    assert.equal(request.options.referrerPolicy, "no-referrer");
    assert.equal(host.state.timers.at(-1).delay, 30000);
  }
});

test("unconfigured, incomplete and unsafe settings fail without sending requests", async () => {
  for (const settings of [
    {}, { baseUrl: "https://example.test/" },
    { baseUrl: "file:///library", key: "secret" },
    { baseUrl: "https://user:pass@example.test/", key: "secret" },
    { baseUrl: "https://example.test/?key=secret", key: "secret" },
    { baseUrl: "https://example.test/#fragment", key: "secret" },
    { baseUrl: "not a URL", key: "secret" }
  ]) {
    const host = createHost(settings);
    const result = await host.request("start");
    assert.equal(result.ok, false);
    assert.ok(result.message);
    assert.equal(host.state.requests.length, 0);
  }
  const host = createHost({ baseUrl: "https://example.test/jellymw", key: "secret" });
  assert.equal((await host.request("start")).ok, true);
  assert.equal(new URL(host.state.requests[0].url).pathname, "/jellymw/start");
});

test("web pages cannot control the drive and scan settings exclude the key", async () => {
  const host = createHost();
  for (const sender of [{ url: "https://example.test/" }, {}, { url: "moz-extension://test/options.html" }]) {
    const result = await host.context.handleMessage({ type: "vidwebmatch:driveControl", action: "stop" }, sender);
    assert.equal(result.ok, false);
  }
  assert.equal(host.state.requests.length, 0);
  const settings = await host.context.handleMessage({ type: "vidwebmatch:getSettings" }, { url: "https://example.test/" });
  assert.equal(settings.driveControl, undefined);
  assert.equal(settings.key, undefined);
  assert.equal((await host.request("../stop")).ok, false);
});

test("HTTP, JSON, network and service failures are explicit and secrets are redacted", async () => {
  const host = createHost();
  host.state.fetch = async () => ({ ok: false, status: 403 });
  assert.match((await host.request("start")).message, /HTTP 403/);
  host.state.fetch = async () => ({ ok: true, async json() { throw new SyntaxError("bad json"); } });
  assert.match((await host.request("start")).message, /invalid JSON/);
  host.state.fetch = async () => { throw new Error("Failed URL with secret"); };
  assert.match((await host.request("start")).message, /Check connectivity/);
  for (const failure of [{ ok: false }, { success: false }, { error: "denied" }]) {
    host.state.fetch = async () => ({ ok: true, async json() { return failure; } });
    assert.equal((await host.request("stop")).ok, false);
  }
  for (const key of ['test key&value', 'secret"quoted']) {
    host.state.settings.key = key;
    host.state.fetch = async url => ({
      ok: true, async json() { return { key, url, encoded: encodeURIComponent(key) }; }
    });
    const result = await host.request("start");
    assert.equal(result.ok, true);
    assert.ok(!result.message.includes(key));
    assert.ok(!result.message.includes(encodeURIComponent(key)));
    assert.ok(!result.message.includes(JSON.stringify(key).slice(1, -1)));
    assert.match(result.message, /\[redacted\]/);
  }
});

test("timeouts report unknown outcome and manual stop waits for an in-flight start", async () => {
  const host = createHost();
  host.state.fetch = (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("aborted")));
  });
  const pending = host.request("start");
  await new Promise(resolve => setImmediate(resolve));
  const stop = host.request("stop");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(host.state.requests.length, 1);
  host.state.fetch = null;
  host.state.timers.at(-1).callback();
  const response = await pending;
  assert.equal(response.ok, false);
  assert.match(response.message, /timed out.*outcome is unknown/);
  assert.equal((await stop).ok, true);
  assert.equal(new URL(host.state.requests[1].url).pathname, "/jellymw/stop");
  assert.equal(host.state.storage.driveKeepAlive.enabled, false);
  assert.equal((await host.request("start")).ok, true);
});

function pageLoad(host, sender = { url: "https://watched.test/list", tab: { id: 1 }, frameId: 0 }) {
  return host.context.handleMessage({
    type: "vidwebmatch:pageLoaded", pageUrl: "https://watched.test/forged", action: "stop"
  }, sender);
}

test("keep-alive is opt-in, persists separately, and sends one start for each watched page load", async () => {
  const host = createHost();
  host.state.storage.settings = { urlPatterns: ["https://watched.test/*"] };
  assert.equal((await pageLoad(host)).skipped, true);
  assert.equal(host.state.requests.length, 0);
  assert.equal((await host.request("start")).ok, true);
  assert.equal(host.state.storage.driveKeepAlive.enabled, true);
  for (let i = 0; i < 2; i++) {
    assert.equal((await pageLoad(host)).ok, true);
    assert.equal(new URL(host.state.requests.at(-1).url).pathname, "/jellymw/start");
  }
  assert.equal(host.state.requests.length, 3);
  // Reload the background with the persisted state, without contacting the helper.
  const restarted = createHost();
  restarted.state.storage = structuredClone(host.state.storage);
  assert.equal((await pageLoad(restarted)).ok, true);
  assert.equal(restarted.state.requests.length, 1);
  assert.equal(restarted.state.storage.settings.driveKeepAlive, undefined);
});

test("keep-alive trusts the actual top-level sender URL and enabled scan modes", async () => {
  const host = createHost();
  await host.request("start");
  host.state.storage.settings = { urlPatterns: ["https://watched.test/*"] };
  for (const sender of [
    { url: "https://unwatched.test/", tab: { id: 1 }, frameId: 0 },
    { url: "https://watched.test/", tab: { id: 1 }, frameId: 1 },
    { url: "https://watched.test/", frameId: 0 },
    { url: "file:///watched.test/", tab: { id: 1 }, frameId: 0 },
    {}
  ]) {
    const result = await pageLoad(host, sender);
    assert.ok(result.skipped || result.ok === false);
  }
  host.state.storage.settings = {
    urlPatterns: ["https://watched.test/*"],
    scanLinks: false, scanVisibleText: false, scanScopedTitles: false
  };
  assert.equal((await pageLoad(host)).skipped, true);
  assert.equal(host.state.requests.length, 1);
});

test("failed mounts do not enable keep-alive and automatic failures stay visible without disarming it", async () => {
  const host = createHost();
  host.state.fetch = async () => ({ ok: false, status: 502 });
  assert.equal((await host.request("start")).ok, false);
  assert.equal(host.state.storage.driveKeepAlive.enabled, false);
  assert.equal((await pageLoad(host)).skipped, true);
  host.state.fetch = null;
  await host.request("start");
  host.state.fetch = async () => ({ ok: false, status: 502 });
  assert.equal((await pageLoad(host)).ok, false);
  assert.equal(host.state.storage.driveKeepAlive.enabled, true);
  assert.match(host.state.storage.driveKeepAlive.lastError, /HTTP 502/);
  host.state.fetch = null;
  await pageLoad(host);
  assert.equal(host.state.storage.driveKeepAlive.lastError, "");
});

test("stop disables keep-alive even on service failure and queued page loads cannot remount", async () => {
  const host = createHost();
  await host.request("start");
  let release;
  host.state.fetch = () => new Promise(resolve => { release = resolve; });
  const active = pageLoad(host);
  await new Promise(resolve => setImmediate(resolve));
  const stop = host.request("stop");
  const queued = pageLoad(host);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(host.state.requests.length, 2);
  host.state.fetch = async () => ({ ok: false, status: 503 });
  release({ ok: true, async json() { return { mounted: true }; } });
  await active;
  assert.equal((await stop).ok, false);
  assert.equal((await queued).skipped, true);
  assert.equal(new URL(host.state.requests.at(-1).url).pathname, "/jellymw/stop");
  assert.equal(host.state.requests.length, 3);
  assert.equal(host.state.storage.driveKeepAlive.enabled, false);
  await pageLoad(host);
  assert.equal(host.state.requests.length, 3);
});

test("content script sends page-load once without waiting for keep-alive, not on rescans", async () => {
  const messages = [];
  const timers = [];
  const context = vm.createContext({
    console, setTimeout(callback) { timers.push(callback); return timers.length; },
    clearTimeout() {},
    document: {
      addEventListener() {},
      createElement() { return {}; },
      documentElement: { appendChild() {} }
    },
    browser: { runtime: {
      onMessage: { addListener() {} },
      async sendMessage(message) {
        messages.push(message);
        if (message.type === "vidwebmatch:getSettings") {
          return {};
        }
        return new Promise(() => {}); // The drive service never replies.
      }
    } }
  });
  const source = fs.readFileSync(path.join(extensionDir, "content-script.js"), "utf8");
  vm.runInContext(source + "\ninstallObserver = () => {}; runScan = async () => {};", context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(messages.filter(m => m.type === "vidwebmatch:pageLoaded").length, 1);
  assert.equal(timers.length, 1); // Scanning is scheduled even while start is pending.
  timers[0]();
  context.scheduleScan(false, true);
  timers.at(-1)();
  assert.equal(messages.filter(m => m.type === "vidwebmatch:pageLoaded").length, 1);
});

test("popup confirms unmount, prevents repeated clicks and refreshes helper status", async () => {
  const elements = Object.fromEntries([
    "helperStatus", "startHint", "rescanButton", "openOptionsButton",
    "mountDriveButton", "unmountDriveButton", "driveStatus", "keepAliveStatus"
  ].map(id => [id, {
    style: {}, classList: { remove() {}, add() {} },
    addEventListener(event, handler) { this[event] = handler; }
  }]));
  const requests = [];
  let confirmed = false;
  let resolveRequest;
  const context = vm.createContext({
    document: { getElementById(id) { return elements[id]; } },
    window: { confirm() { return confirmed; } },
    browser: { storage: { local: { async get() {
      return { driveKeepAlive: { enabled: true, lastError: "HTTP 502" } };
    } } }, runtime: {
      async sendMessage(message) {
        requests.push(message);
        if (message.type === "vidwebmatch:driveControl") {
          return new Promise(resolve => { resolveRequest = resolve; });
        }
        return { ok: true, response: { search_root: "Z:\\" } };
      }
    } }
  });
  vm.runInContext(fs.readFileSync(path.join(extensionDir, "popup.js"), "utf8"), context);
  await new Promise(resolve => setImmediate(resolve));
  assert.match(elements.keepAliveStatus.textContent, /keep-alive on.*HTTP 502/);
  elements.unmountDriveButton.click();
  assert.equal(requests.filter(r => r.type === "vidwebmatch:driveControl").length, 0);
  confirmed = true;
  elements.unmountDriveButton.click();
  assert.equal(elements.mountDriveButton.disabled, true);
  assert.equal(elements.unmountDriveButton.disabled, true);
  assert.equal(requests.at(-1).action, "stop");
  resolveRequest({ ok: true, message: '{"stopped":true}' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(elements.driveStatus.textContent, '{"stopped":true}');
  assert.equal(elements.mountDriveButton.disabled, false);
  assert.equal(requests.at(-1).type, "vidwebmatch:pingHelper");
});

test("Options save/load drive settings separately and list autosave leaves them unchanged", async () => {
  const state = {
    settings: { nativeHostName: "custom.host", urlPatterns: ["https://example.test/*"] },
    driveControl: { baseUrl: "https://example.test/jellymw/", key: "existing-secret" }
  };
  function node() {
    return {
      value: "", children: [], style: {},
      get firstChild() { return this.children[0]; },
      appendChild(child) { this.children.push(child); },
      removeChild(child) { this.children.splice(this.children.indexOf(child), 1); },
      addEventListener() {}, setAttribute() {}
    };
  }
  const elements = {};
  const context = vm.createContext({
    URL, console,
    document: {
      getElementById(id) { return elements[id] || (elements[id] = node()); },
      createElement: node, createDocumentFragment: node
    },
    browser: { storage: { local: {
      async get(keys) {
        return Object.fromEntries((Array.isArray(keys) ? keys : [keys]).map(key => [key, state[key]]));
      },
      async set(values) { Object.assign(state, values); }
    } } }
  });
  for (const file of ["drive-control.js", "options.js"]) {
    vm.runInContext(fs.readFileSync(path.join(extensionDir, file), "utf8"), context);
  }
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(elements.driveControlKey.value, "existing-secret");
  elements.driveControlBaseUrl.value = "https://new.example.test/service";
  elements.driveControlKey.value = "new-secret";
  await context.persistSettings(false, false);
  assert.equal(state.driveControl.key, "existing-secret");
  await context.persistSettings(true, false);
  assert.equal(state.driveControl.key, "new-secret");
  assert.equal(state.driveControl.baseUrl, "https://new.example.test/service/");
  assert.equal(state.settings.nativeHostName, "custom.host");
  assert.equal(state.settings.key, undefined);
  elements.driveControlBaseUrl.value = "bad URL";
  await assert.rejects(context.persistSettings(true, false), /valid HTTP/);
  assert.equal(state.driveControl.key, "new-secret");
  elements.driveControlBaseUrl.value = "";
  elements.driveControlKey.value = "";
  await context.persistSettings(true, false);
  assert.equal(state.driveControl.baseUrl, "");
  assert.equal(state.driveControl.key, "");
});
