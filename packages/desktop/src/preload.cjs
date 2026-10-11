// Preload for the panel and dashboard windows: a deliberately tiny, explicit surface.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("shepherdDesktop", {
  hide: () => ipcRenderer.send("panel:hide"),
  openSession: (id) => {
    if (typeof id === "string") ipcRenderer.send("panel:open-session", id);
  },
  shown: () => ipcRenderer.send("panel:shown-ack"),
  onShow: (cb) => ipcRenderer.on("panel:show", () => cb()),
});

// The dashboard asks to switch session; surface it as a DOM event the page can listen for.
ipcRenderer.on("dashboard:select", (_e, id) => {
  window.dispatchEvent(new CustomEvent("shepherd-select", { detail: id }));
});
