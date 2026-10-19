import express from 'express';
import http from 'http';
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';

const TOKEN = process.env.TOKEN || 'CHANGE_ME';
const NTFY  = process.env.NTFY  || '';
const KEY   = crypto.createHash('sha256').update(TOKEN).digest();
const CLIP_DIR = 'clips';
fs.mkdirSync(CLIP_DIR, { recursive: true });

const app = express();
app.use(express.static('public'));
app.use('/clips', express.static(CLIP_DIR));

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

let device = null;
const viewers = new Set();
const state = { photo: null, gps: null, keys: [], alerts: [], clips: [], settings: {}, online: false };

const dec = (s) => {
  try {
    const b = Buffer.from(s, 'base64');
    const iv = b.subarray(0, 12), tag = b.subarray(b.length - 16), ct = b.subarray(12, b.length - 16);
    const d = crypto.createDecipheriv('aes-256-gcm', KEY, iv);
    d.setAuthTag(tag);
    return JSON.parse(Buffer.concat([d.update(ct), d.final()]).toString());
  } catch { try { return JSON.parse(s); } catch { return null; } }
};

const enc = (o) => {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', KEY, iv);
  const ct = Buffer.concat([c.update(JSON.stringify(o)), c.final()]);
  return Buffer.concat([iv, ct, c.getAuthTag()]).toString('base64');
};

function push(title, body, prio = 'default') {
  if (!NTFY) return;
  fetch(NTFY, { method: 'POST', headers: { Title: title, Priority: prio, Tags: 'eyes' }, body }).catch(() => {});
}

app.post('/upload', express.raw({ type: '*/*', limit: '20mb' }), (req, res) => {
  if (req.query.token !== TOKEN) return res.status(403).end();
  const name = path.basename(String(req.query.name || `clip-${Date.now()}.wav`));
  fs.writeFile(path.join(CLIP_DIR, name), req.body, (err) => {
    if (err) return res.status(500).end();
    const clip = { type: 'clip', name, seconds: Number(req.query.seconds) || 0,
                   session: String(req.query.session || '-'), bytes: req.body.length, at: Date.now() };
    state.clips.unshift(clip);
    state.clips = state.clips.slice(0, 500);
    viewers.forEach(v => v.readyState === 1 && v.send(JSON.stringify(clip)));
    res.status(200).end();
  });
});

wss.on('connection', (ws, req) => {
  const u = new URL(req.url, 'http://x');
  if (u.searchParams.get('token') !== TOKEN) return ws.close();
  const role = u.searchParams.get('role');

  if (role === 'device') {
    device = ws; state.online = true;
    const bools = {}, scalars = {};
    for (const [k, v] of Object.entries(state.settings)) {
      if (typeof v === 'boolean') bools[k] = v; else scalars[k] = v;
    }
    ws.send(enc({ type: 'settings', values: bools, ...scalars }));
    ws.on('close', () => { if (device === ws) { device = null; state.online = false; } });
  } else {
    viewers.add(ws);
    ws.on('close', () => viewers.delete(ws));
    ws.send(JSON.stringify({ type: 'snapshot', ...state }));
  }

  ws.on('message', (data, isBinary) => {
    if (role === 'device') {
      if (isBinary) { viewers.forEach(v => v.readyState === 1 && v.send(data)); return; }
      const m = dec(data.toString());
      if (!m) return;
      if (m.type === 'photo') state.photo = m.b64;
      if (m.type === 'gps') state.gps = m;
      if (m.type === 'keys') state.keys = m.lines;
      if (m.type === 'settings') Object.assign(state.settings, m.values || {});
      if (m.type === 'alert') {
        state.alerts.unshift(m);
        state.alerts = state.alerts.slice(0, 200);
        push(m.title || 'Alert', `${m.feature || ''} - ${m.reason || ''}`, m.ok === false ? 'high' : 'default');
      }
      viewers.forEach(v => v.readyState === 1 && v.send(JSON.stringify(m)));
    } else {
      let m; try { m = JSON.parse(data.toString()); } catch { return; }
      if (m.type === 'settings') {
        Object.assign(state.settings, m.values || {});
        for (const [k, v] of Object.entries(m)) if (k !== 'type' && k !== 'values') state.settings[k] = v;
      }
      if (device && device.readyState === 1) device.send(enc(m));
      viewers.forEach(v => v.readyState === 1 && v.send(JSON.stringify(m)));
    }
  });
});

setInterval(() => {
  const days = state.settings.clipRetentionDays || 7;
  const cut = Date.now() - days * 86400000;
  fs.readdir(CLIP_DIR, (_, files) => (files || []).forEach(f => {
    const p = path.join(CLIP_DIR, f);
    fs.stat(p, (_, st) => { if (st && st.mtimeMs < cut) fs.unlink(p, () => {}); });
  }));
  state.clips = state.clips.filter(c => c.at > cut);
}, 3600000);

server.listen(8080, () => console.log('relay on :8080'));
