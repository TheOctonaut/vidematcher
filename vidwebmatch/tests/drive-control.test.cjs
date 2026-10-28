const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const extensionDir = path.join(__dirname, "..", "extension");
const popupUrl = "moz-extension://test/popup.html";

function createHost(settings = { baseUrl: "https://example.test/jellymw/", key: "test key&value" }) {
  const state = { requests: [], settings, timers: [] };
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
      runtime: {
        getURL(file) { return "moz-extension://test/" + file; },
        onInstalled: { addListener() {} },
        onMessage: { addListener() {} }
      },
      storage: {
        local: {
          async get(key) {
            return key === "driveControl" ? { driveControl: state.settings } : { settings: {} };
          }
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

test("timeout and overlapping requests do not report success or cause duplicate actions", async () => {
  const host = createHost();
  host.state.fetch = (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("aborted")));
  });
  const pending = host.request("start");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal((await host.request("stop")).ok, false);
  assert.equal(host.state.requests.length, 1);
  host.state.timers.at(-1).callback();
  const response = await pending;
  assert.equal(response.ok, false);
  assert.match(response.message, /timed out.*outcome is unknown/);
  host.state.fetch = null;
  assert.equal((await host.request("start")).ok, true);
});

test("popup confirms unmount, prevents repeated clicks and refreshes helper status", async () => {
  const elements = Object.fromEntries([
    "helperStatus", "startHint", "rescanButton", "openOptionsButton",
    "mountDriveButton", "unmountDriveButton", "driveStatus"
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
    browser: { runtime: {
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
