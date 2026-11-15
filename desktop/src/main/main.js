'use strict';
// Gale for computers: the window, the live-sync hub and auto-update.

const { app, BrowserWindow, ipcMain, dialog, shell, Menu } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const QRCode = require('qrcode');
const { GaleHub, DEFAULT_PORT } = require('../hub/hub');
const Model = require('../shared/model');

const isDev = !app.isPackaged;
let win = null;
let hub = null;
let hubError = null;
let localToken = null;
let deviceId = null;
const pickedFolders = [];
let quitting = false;

function log(msg) {
  if (isDev) console.log(msg);
  try {
    fs.appendFileSync(path.join(app.getPath('userData'), 'gale.log'), `${new Date().toISOString()} ${msg}\n`);
  } catch (_) { /* no log file, that's fine */ }
}

function computerName() {
  const n = os.hostname().replace(/\.local$/i, '').trim();
  return n || 'Computer';
}

function send(channel, data) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, data);
}

async function startHub() {
  const dataDir = path.join(app.getPath('userData'), 'hub');
  const docsDir = path.join(app.getPath('documents'), 'Gale');
  const make = (port) => new GaleHub({ dataDir, docsDir, port, serverName: computerName(), announce: port === DEFAULT_PORT, log });
  hub = make(DEFAULT_PORT);
  try {
    await hub.start();
  } catch (err) {
    log(`Hub couldn't use port ${DEFAULT_PORT}: ${err.message}`);
    hubError = err.code === 'EADDRINUSE'
      ? `Another app is using port ${DEFAULT_PORT}, so iPads and iPhones can't connect right now. Close that app and restart Gale.`
      : `Live sync couldn't start (${err.message}). Restart Gale to try again.`;
    // Keep drawing working on this computer with a private port.
    hub = make(0);
    hub.host = '127.0.0.1';
    await hub.start();
  }
  deviceId = `desktop-${hub.serverId.slice(0, 10)}`;
  localToken = hub.createLocalToken(deviceId, computerName());
  hub.on('pairing', (info) => send('pair:changed', info));
  hub.on('devices', (list) => send('devices:changed', list));
  hub.on('paired', (d) => send('pair:paired', d));
}

function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 960,
    minHeight: 620,
    title: 'Gale',
    backgroundColor: '#14141c',
    icon: path.join(__dirname, '..', '..', 'build', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  win.on('closed', () => {
    win = null;
  });
}

function setupMenu() {
  if (process.platform === 'darwin') {
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      { role: 'appMenu' },
      { label: 'Edit', submenu: [{ role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
      { role: 'windowMenu' },
    ]));
  } else {
    Menu.setApplicationMenu(null);
  }
}

function setupUpdater() {
  if (isDev) return;
  let autoUpdater;
  try {
    // eslint-disable-next-line global-require
    ({ autoUpdater } = require('electron-updater'));
  } catch (err) {
    log(`Updater missing: ${err.message}`);
    return;
  }
  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.logger = { info: log, warn: log, error: log, debug: () => {} };
  autoUpdater.on('update-downloaded', (info) => send('update:ready', { version: info && info.version }));
  autoUpdater.on('error', (err) => log(`Update check failed: ${err && err.message}`));
  const check = () => autoUpdater.checkForUpdates().catch((err) => log(`Update check failed: ${err.message}`));
  setTimeout(check, 5000);
  setInterval(check, 4 * 60 * 60 * 1000);
  ipcMain.handle('update:install', async () => {
    quitting = true;
    if (hub) await hub.stop().catch(() => {});
    setImmediate(() => autoUpdater.quitAndInstall());
  });
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function setupIpc() {
  ipcMain.handle('hub:info', () => ({
    port: hub.port,
    token: localToken,
    deviceId,
    deviceName: computerName(),
    serverId: hub.serverId,
    serverName: hub.serverName,
    error: hubError,
    docsDir: path.join(app.getPath('documents'), 'Gale'),
    version: app.getVersion(),
  }));

  ipcMain.handle('pair:start', async () => {
    const info = hub.startPairing();
    const qr = await QRCode.toDataURL(info.url, { margin: 1, width: 320, errorCorrectionLevel: 'M' });
    return { ...info, qr, hubError };
  });
  ipcMain.handle('pair:stop', () => hub.stopPairing());
  ipcMain.handle('devices:list', () => hub.devices());
  ipcMain.handle('devices:remove', (_e, id) => hub.removeDevice(String(id)));

  ipcMain.handle('file:save', async (_e, { name, data, kind }) => {
    const filters = kind === 'gif' ? [{ name: 'GIF picture', extensions: ['gif'] }] : [{ name: 'File', extensions: ['*'] }];
    const r = await dialog.showSaveDialog(win, { defaultPath: path.join(app.getPath('pictures'), String(name || 'Gale')), filters });
    if (r.canceled || !r.filePath) return null;
    fs.writeFileSync(r.filePath, Buffer.from(data));
    return r.filePath;
  });

  ipcMain.handle('file:pickFolder', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'], defaultPath: app.getPath('pictures') });
    if (r.canceled || !r.filePaths[0]) return null;
    pickedFolders.push(r.filePaths[0]);
    return { id: pickedFolders.length - 1, path: r.filePaths[0] };
  });

  ipcMain.handle('file:writeInFolder', (_e, { id, name, data }) => {
    const folder = pickedFolders[id];
    if (!folder) throw new Error('Pick a folder first');
    if (typeof name !== 'string' || !/^[\p{L}\p{N} _.-]{1,120}\.png$/u.test(name) || name.includes('..')) throw new Error('Bad file name');
    fs.writeFileSync(path.join(folder, name), Buffer.from(data));
    return true;
  });

  // Reads a .gale folder (or its project.json) and copies its media into the hub.
  ipcMain.handle('file:importGale', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: 'Open a .gale project',
      defaultPath: path.join(app.getPath('documents'), 'Gale'),
      properties: ['openFile', 'openDirectory'],
      filters: [{ name: 'Gale project', extensions: ['json', 'gale'] }],
    });
    if (r.canceled || !r.filePaths[0]) return null;
    let file = r.filePaths[0];
    if (fs.statSync(file).isDirectory()) file = path.join(file, 'project.json');
    if (!fs.existsSync(file)) return { error: 'That folder has no project.json in it.' };
    if (fs.statSync(file).size > 200 * 1024 * 1024) return { error: 'That project is too big to open.' };
    let json;
    try {
      json = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (_) {
      return { error: 'That project.json is damaged, so it can\'t be opened.' };
    }
    const folder = path.dirname(file);
    const project = Model.readProject(json);
    for (const m of project.media) {
      if (!m.file || /[\\/]/.test(m.file) || m.file.startsWith('.')) continue;
      const src = path.join(folder, 'media', m.file);
      try {
        if (!fs.existsSync(src) || fs.statSync(src).size > 1024 * 1024 * 1024) continue;
        const sha = sha256File(src);
        if (!hub.store.hasBlob(sha)) fs.copyFileSync(src, hub.store.blobPath(sha));
        m.sha256 = sha;
      } catch (err) {
        log(`Couldn't copy media ${m.file}: ${err.message}`);
      }
    }
    return { project };
  });

  ipcMain.handle('shell:openDocs', async () => {
    const dir = path.join(app.getPath('documents'), 'Gale');
    fs.mkdirSync(dir, { recursive: true });
    return shell.openPath(dir);
  });
  ipcMain.handle('shell:showProject', (_e, id) => {
    hub.files && hub.files.write(String(id));
    const p = hub.files && hub.files.pathOf(String(id));
    if (p && fs.existsSync(p)) shell.showItemInFolder(path.join(p, 'project.json'));
    return !!p;
  });
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  app.whenReady().then(async () => {
    if (isDev) {
      try {
        // eslint-disable-next-line global-require
        require('../../scripts/bundle').build();
      } catch (err) {
        log(`Bundle failed: ${err.message}`);
      }
    }
    setupMenu();
    await startHub();
    setupIpc();
    setupUpdater();
    createWindow();
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });

  app.on('before-quit', (e) => {
    if (quitting || !hub) return;
    e.preventDefault();
    quitting = true;
    hub.stop().catch(() => {}).finally(() => app.quit());
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}
