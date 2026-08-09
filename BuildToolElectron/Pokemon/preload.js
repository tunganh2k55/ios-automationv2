// preload.js — cầu nối an toàn giữa renderer (UI) và main (mạng). Không mở nodeIntegration.
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("poke", {
  appVersion: () => ipcRenderer.invoke("app:version"),
  updateCheck: () => ipcRenderer.invoke("update:check"),
  updateDownload: (info) => ipcRenderer.invoke("update:download", info),
  updateApply: (filePath) => ipcRenderer.invoke("update:apply", { path: filePath }),
  onUpdateProgress: (cb) => {
    const h = (_e, d) => cb(d);
    ipcRenderer.on("update:progress", h);
    return () => ipcRenderer.removeListener("update:progress", h);
  },
  scanDevices: (mode) => ipcRenderer.invoke("devices:scan", { mode }),
  usbTooling: () => ipcRenderer.invoke("usb:tooling"),
  checkLicense: (serial) => ipcRenderer.invoke("license:check", { serial }),
  deviceAppLicense: (host, port) => ipcRenderer.invoke("device:appLicense", { host, port }),
  deviceLog: (host, port, offset) => ipcRenderer.invoke("device:log", { host, port, offset }),
  deviceStop: (host, port) => ipcRenderer.invoke("device:stop", { host, port }),
  deviceStatus: (host, port) => ipcRenderer.invoke("device:status", { host, port }),
  openView: (host, port, name) => ipcRenderer.invoke("device:openView", { host, port, name }),
  openExternal: (url) => ipcRenderer.invoke("shell:open", { url }),
  clipboardWrite: (text) => ipcRenderer.invoke("clipboard:write", { text }),
  scriptsList: () => ipcRenderer.invoke("scripts:list"),
  scriptRun: (host, port, scriptId) => ipcRenderer.invoke("scripts:run", { host, port, scriptId }),
  devicesRunning: (list) => ipcRenderer.invoke("devices:running", { list }),
  scriptUpload: (host, port, scriptId) => ipcRenderer.invoke("scripts:upload", { host, port, scriptId }),
  settingsGet: () => ipcRenderer.invoke("settings:get"),
  settingsSet: (patch) => ipcRenderer.invoke("settings:set", patch),
  configLoad: () => ipcRenderer.invoke("config:load"),
  configSave: (text) => ipcRenderer.invoke("config:save", { text }),
  configPush: (text, devices) => ipcRenderer.invoke("config:push", { text, devices }),
  onScanProgress: (cb) => {
    const h = (_e, payload) => cb(payload);
    ipcRenderer.on("scan:progress", h);
    return () => ipcRenderer.removeListener("scan:progress", h);
  },
  win: {
    minimize: () => ipcRenderer.invoke("win:minimize"),
    maximize: () => ipcRenderer.invoke("win:maximize"),
    close: () => ipcRenderer.invoke("win:close"),
    isMaximized: () => ipcRenderer.invoke("win:isMaximized"),
  },
});
