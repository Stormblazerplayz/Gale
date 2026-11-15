'use strict';
// The only bridge between the window and the computer. The window gets these functions and nothing else.
const { contextBridge, ipcRenderer } = require('electron');

const channels = new Set(['pair:changed', 'devices:changed', 'pair:paired', 'update:ready']);

contextBridge.exposeInMainWorld('galeAPI', {
  hubInfo: () => ipcRenderer.invoke('hub:info'),
  pairStart: () => ipcRenderer.invoke('pair:start'),
  pairStop: () => ipcRenderer.invoke('pair:stop'),
  devices: () => ipcRenderer.invoke('devices:list'),
  removeDevice: (id) => ipcRenderer.invoke('devices:remove', id),
  saveFile: (opts) => ipcRenderer.invoke('file:save', opts),
  pickFolder: () => ipcRenderer.invoke('file:pickFolder'),
  writeInFolder: (opts) => ipcRenderer.invoke('file:writeInFolder', opts),
  importGale: () => ipcRenderer.invoke('file:importGale'),
  openDocs: () => ipcRenderer.invoke('shell:openDocs'),
  showProject: (id) => ipcRenderer.invoke('shell:showProject', id),
  installUpdate: () => ipcRenderer.invoke('update:install'),
  on: (channel, cb) => {
    if (!channels.has(channel)) return () => {};
    const fn = (_e, data) => cb(data);
    ipcRenderer.on(channel, fn);
    return () => ipcRenderer.removeListener(channel, fn);
  },
});
