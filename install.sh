#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${PURPLE}====================================================${NC}"
echo -e "${PURPLE}       DAC Panel - Final Stable Version              ${NC}"
echo -e "${PURPLE}====================================================${NC}"

sudo apt-get update -y > /dev/null 2>&1
sudo apt-get install -y curl wget git build-essential python3 -y > /dev/null 2>&1

if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - > /dev/null 2>&1
    sudo apt-get install -y nodejs > /dev/null 2>&1
fi

rm -rf /root/dac-panel
mkdir -p /root/dac-panel/{server,client/src,client/public/fonts}
cd /root/dac-panel

echo -e "${CYAN}[1/4] Downloading Local Fonts...${NC}"
FONT_BASE_URL="https://raw.githubusercontent.com/YOUR_USERNAME/DAC-Panel/main"
curl -L -o client/public/fonts/Vazirmatn-Regular.woff2 "$FONT_BASE_URL/Vazirmatn-Regular.woff2" 2>/dev/null
curl -L -o client/public/fonts/Vazirmatn-Bold.woff2 "$FONT_BASE_URL/Vazirmatn-Bold.woff2" 2>/dev/null

echo -e "${CYAN}[2/4] Installing Backend...${NC}"

cat << 'EOF' > server/package.json
{
  "name": "dac-panel-server", "version": "2.2.0", "type": "module",
  "scripts": { "start": "node index.js" },
  "dependencies": { "express": "^4.18.2", "cors": "^2.8.5", "better-sqlite3": "^9.4.3", "axios": "^1.6.2", "express-session": "^1.17.3", "uuid": "^9.0.0" }
}
EOF

cat << 'SERVERCODE' > server/index.js
import express from 'express';
import cors from 'cors';
import path from 'path';
import { fileURLToPath } from 'url';
import Database from 'better-sqlite3';
import axios from 'axios';
import crypto from 'crypto';
import session from 'express-session';
import { v4 as uuidv4 } from 'uuid';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const app = express();
const PORT = 3000;

app.use(cors({ origin: true, credentials: true }));
app.use(express.json());
app.use(session({ secret: 'dac_secret_v2', resave: false, saveUninitialized: true, cookie: { secure: false } }));

const db = new Database(path.join(__dirname, 'dac.db'));
db.pragma('journal_mode = WAL');
db.exec(`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS agents (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password TEXT, name TEXT, phone TEXT, balance REAL DEFAULT 0, default_inbound_id INTEGER); CREATE TABLE IF NOT EXISTS user_mappings (xui_uuid TEXT PRIMARY KEY, agent_id INTEGER, created_by TEXT);`);

const ENC_KEY = crypto.randomBytes(32);
const ENC_IV = crypto.randomBytes(16);
function enc(t) { let c = crypto.createCipheriv('aes-256-cbc', ENC_KEY, ENC_IV); return c.update(t, 'utf8', 'hex') + c.final('hex'); }
function dec(t) { try { let d = crypto.createDecipheriv('aes-256-cbc', ENC_KEY, ENC_IV); return d.update(t, 'hex', 'utf8') + d.final('utf8'); } catch(e) { return ""; } }

async function getXui() {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get('xui_conn');
    if (!row) throw new Error("Not connected");
    const s = JSON.parse(row.value);
    const res = await axios.post(`${s.url}/login`, { username: s.username, password: dec(s.password) });
    const cookie = res.headers['set-cookie'].find(c => c.startsWith('session='))?.split(';')[0];
    return { baseURL: s.url, headers: { Cookie: cookie, 'Content-Type': 'application/json', 'Accept': 'application/json' } };
}

app.post('/api/auth/login', async (req, res) => {
    try {
        const { url, username, password } = req.body;
        const r = await axios.post(`${url}/login`, { username, password });
        if (r.data.success) { db.prepare(`INSERT INTO settings (key, value) VALUES ('xui_conn', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`).run(JSON.stringify({ url, username, password: enc(password) })); req.session.loggedIn = true; res.json({ success: true }); }
        else res.status(401).json({ success: false });
    } catch (e) { res.status(500).json({ success: false }); }
});
app.get('/api/auth/check', (req, res) => res.json({ loggedIn: !!req.session.loggedIn }));
app.post('/api/auth/logout', (req, res) => { req.session.destroy(); res.json({ success: true }); });

app.get('/api/data', async (req, res) => {
    try {
        const xui = await getXui();
        const ibs = (await axios.get(`${xui.baseURL}/panel/inbound/list`, { headers: xui.headers })).data.obj || [];
        let users = [];
        ibs.forEach(ib => { (ib.clientStats || []).forEach(cs => { const cl = ib.clients.find(c => c.id === cs.email); if (cl) { const m = db.prepare('SELECT * FROM user_mappings WHERE xui_uuid = ?').get(cl.id); const a = m ? db.prepare('SELECT name FROM agents WHERE id = ?').get(m.agent_id) : null; let st = 'active'; if (!cl.enable) st = 'disabled'; else if ((cl.expiryTime > 0 && cl.expiryTime < Date.now()/1000) || (cl.totalGB > 0 && cs.up + cs.down >= cl.totalGB * 1073741824)) st = 'expired'; users.push({ id: cl.id, inboundId: ib.id, tag: ib.tag, proto: ib.protocol, name: cl.id, enable: cl.enable, exp: cl.expiryTime, total: cl.totalGB, up: cs.up, down: cs.down, status: st, agent: a ? a.name : 'مدیر سیستم', sub: cl.subId ? `${xui.baseURL}/sub/${cl.subId}` : null }); } }); });
        res.json({ inbounds: ibs, users });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/users/create', async (req, res) => {
    try {
        const { name, inboundId, daysLimit, gbLimit, startOnFirstConnect, agentId } = req.body;
        const xui = await getXui();
        let exp = 0; if (!startOnFirstConnect && daysLimit > 0) exp = Math.floor(Date.now()/1000) + (daysLimit * 86400);
        const nu = { id: name || `dac_${uuidv4().split('-')[0]}`, email: `${name||uuidv4().split('-')[0]}@dac.ir`, enable: true, expiryTime: exp, totalGB: gbLimit, subId: uuidv4() };
        const ib = (await axios.get(`${xui.baseURL}/panel/inbound/list/${inboundId}`, { headers: xui.headers })).data.obj;
        ib.clients.push(nu);
        await axios.post(`${xui.baseURL}/panel/inbound/update/${inboundId}`, ib, { headers: xui.headers });
        if (agentId) db.prepare('INSERT OR IGNORE INTO user_mappings (xui_uuid, agent_id, created_by) VALUES (?, ?, ?)').run(nu.id, agentId, 'agent');
        res.json({ success: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/users/action', async (req, res) => {
    try {
        const { userId, inboundId, action, value } = req.body;
        const xui = await getXui();
        const ib = (await axios.get(`${xui.baseURL}/panel/inbound/list/${inboundId}`, { headers: xui.headers })).data.obj;
        const idx = ib.clients.findIndex(c => c.id === userId);
        if (idx === -1) throw new Error("Not found");
        if (action === 'addVolume') ib.clients[idx].totalGB += parseFloat(value);
        else if (action === 'renew') { let b = ib.clients[idx].expiryTime > Date.now()/1000 ? ib.clients[idx].expiryTime : Math.floor(Date.now()/1000); ib.clients[idx].expiryTime = b + (parseInt(value) * 86400); ib.clients[idx].enable = true; }
        else if (action === 'toggle') ib.clients[idx].enable = !ib.clients[idx].enable;
        else if (action === 'delete') ib.clients.splice(idx, 1);
        await axios.post(`${xui.baseURL}/panel/inbound/update/${inboundId}`, ib, { headers: xui.headers });
        res.json({ success: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/agents', (req, res) => res.json(db.prepare('SELECT * FROM agents').all()));
app.post('/api/agents', (req, res) => { try { const u = req.body; db.prepare('INSERT INTO agents (username, password, name, phone, default_inbound_id) VALUES (?, ?, ?, ?, ?)').run(u.username, u.password, u.name, u.phone, u.default_inbound_id); res.json({ success: true }); } catch(e) { res.status(400).json({error:e.message}); } });
app.post('/api/agents/charge', (req, res) => { db.prepare('UPDATE agents SET balance = balance + ? WHERE id = ?').run(req.body.amount, req.body.id); res.json({ success: true }); });

app.use(express.static(path.join(__dirname, '../client/dist')));
app.get('*', (req, res) => res.sendFile(path.join(__dirname, '../client/dist/index.html')));
app.listen(PORT, '0.0.0.0', () => console.log(`\n🚀 DAC Panel running on port ${PORT}\n`));
SERVERCODE

cd server && npm install > /dev/null 2>&1 && cd ..

echo -e "${CYAN}[3/4] Installing Frontend...${NC}"

cat << 'EOF' > client/package.json
{
  "name": "dac-ui", "private": true, "version": "2.2.0", "type": "module",
  "scripts": { "build": "vite build" },
  "dependencies": { "react": "^18.2.0", "react-dom": "^18.2.0", "axios": "^1.6.2", "lucide-react": "^0.294.0", "framer-motion": "^10.16.5", "qrcode.react": "^3.1.0" },
  "devDependencies": { "@vitejs/plugin-react": "^4.2.0", "autoprefixer": "^10.4.16", "postcss": "^8.4.32", "tailwindcss": "^3.3.6", "vite": "^5.0.4" }
}
EOF

cat << 'EOF' > client/vite.config.js
import { defineConfig } from 'vite'; import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()] })
EOF
cat << 'EOF' > client/tailwind.config.js
export default { content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"], theme: { extend: { fontFamily: { vazir: ['Vazirmatn', 'sans-serif'] } } }, plugins: [] }
EOF
cat << 'EOF' > client/postcss.config.js
export default { plugins: { tailwindcss: {}, autoprefixer: {} } }
EOF
cat << 'EOF' > client/index.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width, initial-scale=1.0"/><title>DAC Panel</title></head><body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body></html>
EOF
cat << 'EOF' > client/src/main.jsx
import React from 'react'; import ReactDOM from 'react-dom/client'; import App from './App.jsx'; import './index.css';
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
EOF

cat << 'EOF' > client/src/index.css
@font-face { font-family: 'Vazirmatn'; src: url('/fonts/Vazirmatn-Regular.woff2') format('woff2'); font-weight: 400; font-display: swap; }
@font-face { font-family: 'Vazirmatn'; src: url('/fonts/Vazirmatn-Bold.woff2') format('woff2'); font-weight: 700; font-display: swap; }
@tailwind base; @tailwind components; @tailwind utilities;
body { margin: 0; font-family: 'Vazirmatn', sans-serif; background: #0f0c29; direction: rtl; }
@keyframes pulse-green { 0% { box-shadow: 0 0 0 0 rgba(74, 222, 128, 0.7); } 70% { box-shadow: 0 0 0 8px rgba(74, 222, 128, 0); } 100% { box-shadow: 0 0 0 0 rgba(74, 222, 128, 0); } }
.pulse-green { animation: pulse-green 2s infinite; }
.bg-animated { background: linear-gradient(-45deg, #0f0c29, #302b63, #1a1a2e, #16213e); background-size: 400% 400%; animation: gradientShift 15s ease infinite; }
@keyframes gradientShift { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
EOF

# فایل فرانت با رفع کامل باگ آیکون
cat << 'FRONTENDCODE' > client/src/App.jsx
import { useState, useEffect } from 'react';
import axios from 'axios';
import { motion, AnimatePresence } from 'framer-motion';
import { QRCodeSVG } from 'qrcode.react';
// ✅ آیکون Handshake حذف شد و UserCog جایگزین شد
import { LayoutDashboard, Users, UserPlus, UserCog, Settings, LogOut, Menu, X, Plus, RefreshCw, Ban, Trash2, Wifi } from 'lucide-react';

const api = axios.create({ baseURL: '/api', withCredentials: true });

export default function App() {
    const [loggedIn, setLoggedIn] = useState(false);
    const [auth, setAuth] = useState({ url: '', username: '', password: '' });
    const [page, setPage] = useState('dashboard');
    const [data, setData] = useState({ inbounds: [], users: [] });
    const [agents, setAgents] = useState([]);
    const [drawer, setDrawer] = useState({ open: false, user: null });
    const [modal, setModal] = useState({ open: false, type: '' });
    const [side, setSide] = useState(false);
    const [uForm, setUForm] = useState({ name: '', inboundId: '', daysLimit: 30, gbLimit: 10, startOnFirstConnect: true, agentId: '' });
    const [aForm, setAForm] = useState({ username: '', password: '', name: '', phone: '', default_inbound_id: '' });

    useEffect(() => { api.get('/auth/check').then(r => { if(r.data.loggedIn) fetch(); else setLoggedIn(false); }); }, []);

    const login = async (e) => { e.preventDefault(); try { const r = await api.post('/auth/login', auth); if(r.data.success) { setLoggedIn(true); fetch(); } } catch(e) { alert("خطا در اتصال"); } };
    const fetch = () => { api.get('/data').then(r => setData(r.data)); api.get('/agents').then(r => setAgents(r.data)); };
    const mkUser = async () => { await api.post('/users/create', uForm); setModal({open:false, type:''}); fetch(); };
    const uAct = async (a, v) => { await api.post('/users/action', { userId: drawer.user.id, inboundId: drawer.user.inboundId, action: a, value: v }); setDrawer({open:false, user:null}); fetch(); };
    const mkAgent = async () => { await api.post('/agents', aForm); setModal({open:false, type:''}); fetch(); };

    const Light = ({ s }) => { const c = { active: 'bg-green-400 pulse-green', disabled: 'bg-blue-900', expired: 'bg-red-500' }; return <div className={`w-3 h-3 rounded-full ${c[s] || 'bg-gray-500'}`}></div>; };
    const Bar = ({ v, m }) => { const p = m === 0 ? 100 : Math.min((v / m) * 100, 100); const c = p > 50 ? 'from-emerald-500 to-green-400' : p > 20 ? 'from-yellow-500 to-orange-400' : 'from-red-500 to-rose-400'; return <div className="w-24 h-1.5 bg-gray-700/50 rounded-full overflow-hidden"><motion.div initial={{width:0}} animate={{width:`${p}%`}} transition={{duration:1}} className={`h-full bg-gradient-to-l ${c} rounded-full`}/></div>; };

    if (!loggedIn) return (
        <div className="min-h-screen bg-animated flex items-center justify-center p-4">
            <motion.form onSubmit={login} initial={{opacity:0, y:50}} animate={{opacity:1,y:0}} className="w-full max-w-md bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-8 shadow-2xl">
                <h1 className="text-3xl font-bold bg-gradient-to-l from-purple-400 to-blue-400 bg-clip-text text-transparent mb-8 text-center">DAC Panel</h1>
                <input required placeholder="آدرس پنل (مثل http://ip:2053)" value={auth.url} onChange={e=>setAuth({...auth, url:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white mb-4 focus:outline-none focus:border-purple-500"/>
                <input required placeholder="نام کاربری" value={auth.username} onChange={e=>setAuth({...auth, username:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white mb-4 focus:outline-none focus:border-purple-500"/>
                <input required type="password" placeholder="رمز عبور" value={auth.password} onChange={e=>setAuth({...auth, password:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white mb-6 focus:outline-none focus:border-purple-500"/>
                <button type="submit" className="w-full py-3 rounded-xl bg-gradient-to-l from-purple-600 to-blue-600 text-white font-bold hover:opacity-90 transition">ورود</button>
            </motion.form>
        </div>
    );

    return (
        <div className="flex min-h-screen font-vazir text-white overflow-hidden relative">
            <div className="bg-animated absolute inset-0 z-0" />
            <motion.aside initial={{x:300}} animate={{x: side ? 0 : (window.innerWidth > 768 ? 0 : 300)}} className="fixed md:relative z-30 w-72 h-screen p-4 flex flex-col gap-2 bg-white/5 backdrop-blur-xl border-l border-white/10">
                <div className="flex items-center justify-between p-4 border-b border-white/10 mb-4"><h1 className="text-xl font-bold text-purple-400">DAC Panel</h1><button className="md:hidden" onClick={()=>setSide(false)}><X size={24}/></button></div>
                <nav className="flex flex-col gap-1 flex-1">
                    {[{id:'dashboard', l:'داشبورد', i:<LayoutDashboard size={20}/>},{id:'users', l:'کاربران', i:<Users size={20}/>},{id:'agents', l:'نمایندگان', i:<UserCog size={20}/>},{id:'settings', l:'تنظیمات', i:<Settings size={20}/>}].map(m=>(
                        <motion.div key={m.id} whileHover={{x:-5}} onClick={()=>{setPage(m.id); setSide(false);}} className={`flex items-center gap-3 p-3 rounded-xl cursor-pointer text-gray-300 hover:bg-white/10 hover:text-white transition-all border-r-2 ${page===m.id?'bg-white/10 border-purple-500':'border-transparent'}`}>{m.i}<span className="text-sm">{m.l}</span></motion.div>
                    ))}
                </nav>
                <button onClick={()=>api.post('/auth/logout').then(()=>setLoggedIn(false))} className="flex items-center gap-3 p-3 rounded-xl text-red-400 hover:bg-red-500/10 mt-auto"><LogOut size={20}/>خروج</button>
            </motion.aside>

            <main className="flex-1 relative z-10 p-6 md:p-10 overflow-y-auto">
                <button className="mb-6 md:hidden bg-white/10 p-2 rounded-lg" onClick={()=>setSide(true)}><Menu size={24}/></button>

                {page === 'dashboard' && (
                    <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} className="space-y-6">
                        <h2 className="text-2xl font-bold">داشبورد</h2>
                        <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
                            {[{t:'کل کاربران', v:data.users.length, c:'text-blue-400'},{t:'فعال', v:data.users.filter(u=>u.status==='active').length, c:'text-green-400'},{t:'منقضی/غیرفعال', v:data.users.filter(u=>u.status!=='active').length, c:'text-red-400'},{t:'نمایندگان', v:agents.length, c:'text-purple-400'}].map((c,i)=>(
                                <div key={i} className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-6 hover:bg-white/10 transition"><p className="text-gray-400 text-sm">{c.t}</p><p className={`text-3xl font-bold mt-2 ${c.c}`}>{c.v}</p></div>
                            ))}
                        </div>
                    </motion.div>
                )}

                {page === 'users' && (
                    <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} className="space-y-4">
                        <div className="flex justify-between items-center"><h2 className="text-2xl font-bold">کاربران</h2>
                            <motion.button whileTap={{scale:0.9}} onClick={()=>{setUForm({name:'', inboundId: data.inbounds[0]?.id||'', daysLimit:30, gbLimit:10, startOnFirstConnect:true, agentId:''}); setModal({open:true, type:'user'});}} className="flex items-center gap-2 px-4 py-2 rounded-xl bg-emerald-500/20 text-emerald-300 border border-emerald-500/30"><UserPlus size={18}/>ساخت کاربر</motion.button>
                        </div>
                        <div className="space-y-3">
                            {data.users.map(u=>{ const d = u.exp > 0 ? Math.ceil((u.exp*1000 - Date.now())/(86400000)) : '∞'; const used = (u.up + u.down) / 1073741824; const tot = u.total === 0 ? '∞' : u.total; return (
                                <motion.div key={u.id} whileHover={{scale:1.01}} onClick={()=>setDrawer({open:true, user:u})} className="flex items-center justify-between bg-white/5 backdrop-blur-xl border border-white/10 rounded-xl p-4 cursor-pointer hover:bg-white/10 transition-all">
                                    <div className="flex items-center gap-3"><Light s={u.status}/><div><p className="font-bold text-sm">{u.name}</p><p className="text-xs text-gray-500">{u.agent} | {u.proto}</p></div></div>
                                    <div className="hidden md:flex items-center gap-6">
                                        <div className="flex items-center gap-2"><span className="text-xs text-gray-400 w-12">{d} روز</span>{typeof d === 'number' && <Bar value={d} max={30}/>}</div>
                                        <div className="flex items-center gap-2"><span className="text-xs text-gray-400 w-20">{used.toFixed(1)}/{tot} GB</span>{typeof tot === 'number' && <Bar value={tot - used} max={tot}/>}</div>
                                    </div>
                                    <button className="px-4 py-1.5 rounded-lg bg-purple-500/20 text-purple-300 text-xs border border-purple-500/30">مدیریت</button>
                                </motion.div>
                            ); })}
                        </div>
                    </motion.div>
                )}

                {page === 'agents' && (
                    <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} className="space-y-4">
                        <div className="flex justify-between items-center"><h2 className="text-2xl font-bold">نمایندگان</h2>
                            <motion.button whileTap={{scale:0.9}} onClick={()=>{setAForm({username:'',password:'',name:'',phone:'',default_inbound_id:''}); setModal({open:true, type:'agent'});}} className="flex items-center gap-2 px-4 py-2 rounded-xl bg-blue-500/20 text-blue-300 border border-blue-500/30"><Plus size={18}/>افزودن نماینده</motion.button>
                        </div>
                        <div className="grid md:grid-cols-2 gap-4">{agents.map(a=>(<div key={a.id} className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-xl p-6"><h3 className="font-bold text-lg text-purple-400">{a.name}</h3><p className="text-gray-400 text-sm">@{a.username} | {a.phone}</p><p className="mt-4">موجودی: <span className="text-green-400 font-bold">{a.balance} تومان</span></p><button onClick={()=>{const v=prompt('مبلغ شارژ:'); if(v) api.post('/agents/charge',{id:a.id,amount:v}).then(fetch);}} className="text-xs mt-4 px-3 py-1 bg-yellow-500/20 text-yellow-300 rounded-lg">شارژ</button></div>))}</div>
                    </motion.div>
                )}
            </main>

            <AnimatePresence>{drawer.open && drawer.user && (<><motion.div initial={{opacity:0}} animate={{opacity:1}} exit={{opacity:0}} className="fixed inset-0 bg-black/60 backdrop-blur-sm z-40" onClick={()=>setDrawer({open:false, user:null})}/><motion.div initial={{x:500}} animate={{x:0}} exit={{x:500}} transition={{type:"spring", damping:25}} className="fixed left-0 top-0 h-full w-full max-w-md bg-slate-900/90 backdrop-blur-xl border-l border-white/10 z-50 p-6 shadow-2xl overflow-y-auto"><h2 className="text-xl font-bold mb-6 text-purple-400">{drawer.user.name}</h2><p className="text-sm text-gray-400 mb-6 break-all">ساب: <span className="text-blue-400">{drawer.user.sub || 'ندارد'}</span></p>{drawer.user.sub && (<div className="flex justify-center mb-6 bg-white/5 p-4 rounded-xl"><QRCodeSVG value={drawer.user.sub} size={180} bgColor="transparent" fgColor="#ffffff"/></div>)}<div className="space-y-3"><button onClick={()=>uAct('addVolume', prompt('حجم (GB):'))} className="w-full py-3 rounded-xl bg-blue-500/20 text-blue-300 border border-blue-500/30 hover:bg-blue-500/30 transition flex items-center justify-center gap-2"><Plus size={18}/>افزودن حجم</button><button onClick={()=>uAct('renew', prompt('روز تمدید:'))} className="w-full py-3 rounded-xl bg-emerald-500/20 text-emerald-300 border border-emerald-500/30 hover:bg-emerald-500/30 transition flex items-center justify-center gap-2"><RefreshCw size={18}/>تمدید</button><button onClick={()=>uAct('toggle')} className={`w-full py-3 rounded-xl border transition flex items-center justify-center gap-2 ${drawer.user.enable ? 'bg-red-500/20 text-red-300 border-red-500/30' : 'bg-green-500/20 text-green-300 border-green-500/30'}`}>{drawer.user.enable ? <Ban size={18}/> : <Wifi size={18}/>}{drawer.user.enable ? 'غیرفعال' : 'فعال'}</button><button onClick={()=>uAct('delete')} className="w-full py-3 rounded-xl bg-rose-500/10 text-rose-400 border border-rose-500/20 hover:bg-rose-500/20 transition mt-8 flex items-center justify-center gap-2"><Trash2 size={18}/>حذف</button></div></motion.div></>)}</AnimatePresence>

            <AnimatePresence>{modal.open && (<><motion.div initial={{opacity:0}} animate={{opacity:1}} exit={{opacity:0}} className="fixed inset-0 bg-black/60 backdrop-blur-sm z-40" onClick={()=>setModal({open:false, type:''})}/><motion.div initial={{scale:0.9, opacity:0}} animate={{scale:1, opacity:1}} exit={{scale:0.9, opacity:0}} className="fixed inset-0 m-auto w-fit h-fit bg-slate-900/90 backdrop-blur-xl border border-white/10 rounded-2xl p-8 z-50 shadow-2xl">
                {modal.type === 'user' && (<div className="w-96 space-y-4"><h2 className="text-xl font-bold text-purple-400">ساخت کاربر</h2><input placeholder="نام (خالی=خودکار)" value={uForm.name} onChange={e=>setUForm({...uForm, name:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/><select value={uForm.inboundId} onChange={e=>setUForm({...uForm, inboundId:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white">{data.inbounds.map(ib=><option key={ib.id} value={ib.id} className="bg-slate-800">{ib.tag} ({ib.protocol})</option>)}</select><div className="grid grid-cols-2 gap-4"><input type="number" placeholder="روز" value={uForm.daysLimit} onChange={e=>setUForm({...uForm, daysLimit:e.target.value})} className="bg-white/5 border border-white/10 rounded-lg p-3 text-white"/><input type="number" placeholder="حجم(GB)" value={uForm.gbLimit} onChange={e=>setUForm({...uForm, gbLimit:e.target.value})} className="bg-white/5 border border-white/10 rounded-lg p-3 text-white"/></div><label className="flex items-center gap-2 text-sm text-gray-300 cursor-pointer"><input type="checkbox" checked={uForm.startOnFirstConnect} onChange={e=>setUForm({...uForm, startOnFirstConnect: e.target.checked})} className="accent-purple-500"/>شروع از اولین اتصال</label><select value={uForm.agentId} onChange={e=>setUForm({...uForm, agentId:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"><option value="" className="bg-slate-800">مدیر سیستم</option>{agents.map(a=><option key={a.id} value={a.id} className="bg-slate-800">{a.name}</option>)}</select><button onClick={mkUser} className="w-full py-3 rounded-xl bg-gradient-to-l from-purple-600 to-blue-600 text-white font-bold">ساخت</button></div>)}
                {modal.type === 'agent' && (<div className="w-96 space-y-4"><h2 className="text-xl font-bold text-blue-400">افزودن نماینده</h2><input placeholder="نام" value={aForm.name} onChange={e=>setAForm({...aForm, name:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/><input placeholder="یوزرنیم" value={aForm.username} onChange={e=>setAForm({...aForm, username:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/><input placeholder="رمز" value={aForm.password} onChange={e=>setAForm({...aForm, password:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/><input placeholder="شماره" value={aForm.phone} onChange={e=>setAForm({...aForm, phone:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/><select value={aForm.default_inbound_id} onChange={e=>setAForm({...aForm, default_inbound_id:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"><option value="" className="bg-slate-800">اینباند پیش‌فرض</option>{data.inbounds.map(ib=><option key={ib.id} value={ib.id} className="bg-slate-800">{ib.tag}</option>)}</select><button onClick={mkAgent} className="w-full py-3 rounded-xl bg-gradient-to-l from-blue-600 to-cyan-600 text-white font-bold">ثبت</button></div>)}
            </motion.div></>)}</AnimatePresence>
        </div>
    );
}
FRONTENDCODE

echo -e "${CYAN}[4/4] Building UI...${NC}"
cd client
npm install > /dev/null 2>&1
export NODE_OPTIONS="--max-old-space-size=512" # کاهش دادن مصرف رم موقت برای بیلد
npm run build 2>&1 | tee build.log

# عیب‌یابی هوشمند
if [ ! -f "dist/index.html" ]; then
    clear
    if grep -q "FATAL ERROR\|heap limit" build.log; then
        echo -e "${RED}❌ خطا: سرور شما رم (RAM) کمتر از 512 مگابایت دارد و قادر به بیلد نیست.${NC}"
        echo -e "${YELLOW}راه حل: رم سرور را افزایش دهید یا از یک سرور با حداقل 1 گیگابایت رم استفاده کنید.${NC}"
    else
        echo -e "${RED}❌ خطای کدنویسی در فرانت‌اند:${NC}"
    fi
    echo -e "${NC}لاگ خطا:"
    cat build.log
    exit 1
fi

cd ..
clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}             ✅ DAC Panel Installed Successfully!     ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${NC}Run persistently:${PURPLE} npm i -g pm2 && pm2 start /root/dac-panel/server/index.js --name dac${NC}"
echo -e "${CYAN}URL: http://YOUR_SERVER_IP:3000${NC}"

cd server && npm start
