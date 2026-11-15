'use strict';
// The computer's network addresses, best first (home Wi-Fi / cable first, then Tailscale).
const os = require('os');

const VIRTUAL = /(vEthernet|VMware|VirtualBox|Hyper-V|docker|br-|veth|WSL|Loopback|utun|awdl|llw)/i;

function kindOf(ip) {
  const [a, b] = ip.split('.').map(Number);
  if (a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31)) return 'lan';
  if (a === 100 && b >= 64 && b <= 127) return 'tailscale';
  return 'other';
}

function lanAddresses() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const [name, list] of Object.entries(ifaces)) {
    for (const i of list || []) {
      const v4 = i.family === 'IPv4' || i.family === 4;
      if (!v4 || i.internal) continue;
      if (i.address.startsWith('169.254.')) continue;
      out.push({ address: i.address, name, kind: kindOf(i.address), virtual: VIRTUAL.test(name) });
    }
  }
  const rank = (x) => (x.kind === 'lan' ? 0 : x.kind === 'tailscale' ? 2 : 1) + (x.virtual ? 3 : 0);
  out.sort((x, y) => rank(x) - rank(y));
  return out;
}

/** The address to put in the QR code. */
function bestHost() {
  const list = lanAddresses();
  return list.length ? list[0].address : '127.0.0.1';
}

module.exports = { lanAddresses, bestHost, kindOf };
