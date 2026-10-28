"use strict";

function validateDriveControl(value) {
  const baseUrl = typeof value.baseUrl === "string" ? value.baseUrl.trim() : "";
  const key = typeof value.key === "string" ? value.key.trim() : "";
  if (!baseUrl && !key) {
    return { baseUrl: "", key: "" };
  }
  if (!baseUrl || !key) {
    throw new Error("Drive control requires both a base URL and a key.");
  }
  let url;
  try {
    url = new URL(baseUrl);
  } catch (_error) {
    throw new Error("Drive control base URL must be a valid HTTP or HTTPS URL.");
  }
  if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error("Use an HTTP or HTTPS base URL without credentials, query parameters or a fragment.");
  }
  if (!url.pathname.endsWith("/")) {
    url.pathname += "/";
  }
  return { baseUrl: url.href, key };
}
