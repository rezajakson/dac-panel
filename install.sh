#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${PURPLE}====================================================${NC}"
echo -e "${PURPLE}       DAC Panel - Full Version Installer            ${NC}"
echo -e "${PURPLE}====================================================${NC}"

sudo apt-get update -y > /dev/null 2>&1
sudo apt-get install -y curl wget git build-essential python3 -y > /dev/null 2>&1

if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - > /dev/null 2>&1
    sudo apt-get install -y nodejs > /dev/null 2>&1
fi

rm -rf /root/dac-panel
mkdir -p /root/dac-panel/{server,client/src,client/public}
cd /root/dac-panel

# ==========================================
# Backend (Server + Database + 3x-ui API)
# ==========================================
echo -e "${CYAN}[1/3] Installing Backend & Database logic...${NC}"

cat << 'EOF' > server/package.json
{
  "name": "dac-panel-server",
  "version": "2.0.0",
  "type": "module",
  "scripts": { "start": "node index.js" },
  "dependencies": {
    "express": "^4.18.2", "cors": "^2.8.5", "better-sqlite3": "^9.4.3",
    "axios": "^1.6.2", "express-session": "^1.17.3", "uuid": "^9.0.0"
  }
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
app.use(session({ secret: 'dac_panel_secret_key', resave: false, saveUninitialized: true, cookie: { secure: false } }));

const db = new Database(path.join(__dirname, 'dac.db'));
db.pragma('journal_mode = WAL');

// Create Tables
db.exec(`
  CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS agents (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password TEXT, name TEXT, phone TEXT, balance REAL DEFAULT 0, default_inbound_id INTEGER);
  CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, days_limit INTEGER, gb_limit REAL, price_user REAL, price_agent REAL, is_unlimited_time INTEGER DEFAULT 0, is_unlimited_data INTEGER DEFAULT 0);
  CREATE TABLE IF NOT EXISTS user_mappings (xui_uuid TEXT PRIMARY KEY, agent_id INTEGER, created_by TEXT);
`);

// Encryption
const ENC_KEY = crypto.randomBytes(32);
const ENC_IV = crypto.randomBytes(16);
function enc(text) { let c = crypto.createCipheriv('aes-256-cbc', ENC_KEY, ENC_IV); return c.update(text, 'utf8', 'hex') + c.final('hex'); }
function dec(text) { try { let d = crypto.createDecipheriv('aes-256-cbc', ENC_KEY, ENC_IV); return d.update(text, 'hex', 'utf8') + d.final('utf8'); } catch(e) { return ""; } }

// X-UI API Wrapper
async function getXui() {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get('xui_conn');
    if (!row) throw new Error("اتصال به پنل برقرار نیست");
    const s = JSON.parse(row.value);
    const res = await axios.post(`${s.url}/login`, { username: s.username, password: dec(s.password) });
    const cookie = res.headers['set-cookie'].find(c => c.startsWith('session='))?.split(';')[0];
    return { baseURL: s.url, headers: { Cookie: cookie, 'Content-Type': 'application/json', 'Accept': 'application/json' } };
}

// --- ROUTES ---

// Auth
app.post('/api/auth/login', async (req, res) => {
    try {
        const { url, username, password } = req.body;
        const resXui = await axios.post(`${url}/login`, { username, password });
        if (resXui.data.success) {
            const encPass = enc(password);
            db.prepare(`INSERT INTO settings (key, value) VALUES ('xui_conn', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
                .run(JSON.stringify({ url, username, password: encPass }));
            req.session.loggedIn = true;
            res.json({ success: true });
        } else { res.status(401).json({ success: false, message: 'نام کاربری یا رمز اشتباه است' }); }
    } catch (e) { res.status(500).json({ success: false, message: 'خطا در اتصال به پنل' }); }
});

app.get('/api/auth/check', (req, res) => { res.json({ loggedIn: !!req.session.loggedIn }); });
app.post('/api/auth/logout', (req, res) => { req.session.destroy(); res.json({ success: true }); });

// Get Inbounds & Users (Merged)
app.get('/api/data', async (req, res) => {
    try {
        const xui = await getXui();
        const inboundsRes = await axios.get(`${xui.baseURL}/panel/inbound/list`, { headers: xui.headers });
        const inbounds = inboundsRes.data.obj || [];
        
        let allUsers = [];
        inbounds.forEach(ib => {
            (ib.clientStats || []).forEach(cs => {
                const client = ib.clients.find(c => c.id === cs.email);
                if (client) {
                    const mapping = db.prepare('SELECT * FROM user_mappings WHERE xui_uuid = ?').get(client.id);
                    const agent = mapping ? db.prepare('SELECT name, username FROM agents WHERE id = ?').get(mapping.agent_id) : null;
                    
                    let status = 'active';
                    if (!client.enable) status = 'disabled';
                    else if ((client.expiryTime > 0 && client.expiryTime < Date.now()/1000) || (client.totalGB > 0 && cs.up + cs.down >= client.totalGB * 1073741824)) status = 'expired';

                    allUsers.push({
                        id: client.id, inboundId: ib.id, inboundTag: ib.tag, protocol: ib.protocol,
                        name: client.id, email: client.email, enable: client.enable,
                        expiryTime: client.expiryTime, totalGB: client.totalGB,
                        up: cs.up, down: cs.down, status: status,
                        agentName: agent ? agent.name : 'مدیر سیستم', subLink: client.subId ? `${xui.baseURL}/sub/${client.subId}` : null
                    });
                }
            });
        });
        res.json({ inbounds, users: allUsers });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// Create User
app.post('/api/users/create', async (req, res) => {
    try {
        const { name, inboundId, daysLimit, gbLimit, startOnFirstConnect, agentId } = req.body;
        const xui = await getXui();
        
        let expiryTime = 0;
        if (!startOnFirstConnect && daysLimit > 0) expiryTime = Math.floor(Date.now()/1000) + (daysLimit * 86400);

        const newUser = {
            id: name || `dac_${uuidv4().split('-')[0]}`,
            email: `${name || uuidv4().split('-')[0]}@dac.ir`,
            enable: true, expiryTime: expiryTime, totalGB: gbLimit,
            subId: uuidv4()
        };

        // Fetch inbound, add client, push back
        const ibRes = await axios.get(`${xui.baseURL}/panel/inbound/list/${inboundId}`, { headers: xui.headers });
        const ib = ibRes.data.obj;
        ib.clients.push(newUser);
        await axios.post(`${xui.baseURL}/panel/inbound/update/${inboundId}`, ib, { headers: xui.headers });

        if (agentId) db.prepare('INSERT OR IGNORE INTO user_mappings (xui_uuid, agent_id, created_by) VALUES (?, ?, ?)').run(newUser.id, agentId, 'agent');

        res.json({ success: true, user: newUser });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// Add Volume / Renew
app.post('/api/users/action', async (req, res) => {
    try {
        const { userId, inboundId, action, value } = req.body; // action: 'addVolume', 'renew', 'toggle'
        const xui = await getXui();
        
        const ibRes = await axios.get(`${xui.baseURL}/panel/inbound/list/${inboundId}`, { headers: xui.headers });
        const ib = ibRes.data.obj;
        const clientIdx = ib.clients.findIndex(c => c.id === userId);
        if (clientIdx === -1) throw new Error("کاربر یافت نشد");

        if (action === 'addVolume') {
            ib.clients[clientIdx].totalGB += parseFloat(value);
        } else if (action === 'renew') {
            let currentExpiry = ib.clients[clientIdx].expiryTime;
            let baseTime = currentExpiry > Date.now()/1000 ? currentExpiry : Math.floor(Date.now()/1000);
            ib.clients[clientIdx].expiryTime = baseTime + (parseInt(value) * 86400);
            ib.clients[clientIdx].enable = true;
        } else if (action === 'toggle') {
            ib.clients[clientIdx].enable = !ib.clients[clientIdx].enable;
        }

        await axios.post(`${xui.baseURL}/panel/inbound/update/${inboundId}`, ib, { headers: xui.headers });
        res.json({ success: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// Agent CRUD
app.get('/api/agents', (req, res) => { res.json(db.prepare('SELECT * FROM agents').all()); });
app.post('/api/agents', (req, res) => {
    try {
        const { username, password, name, phone, default_inbound_id } = req.body;
        db.prepare('INSERT INTO agents (username, password, name, phone, default_inbound_id) VALUES (?, ?, ?, ?, ?)').run(username, password, name, phone, default_inbound_id);
        res.json({ success: true });
    } catch(e) { res.status(400).json({error: e.message}); }
});
app.post('/api/agents/charge', (req, res) => {
    db.prepare('UPDATE agents SET balance = balance + ? WHERE id = ?').run(req.body.amount, req.body.id);
    res.json({ success: true });
});

// Serve Frontend
app.use(express.static(path.join(__dirname, '../client/dist')));
app.get('*', (req, res) => res.sendFile(path.join(__dirname, '../client/dist/index.html')));

app.listen(PORT, '0.0.0.0', () => console.log(`\n🚀 DAC Panel v2.0 running on http://YOUR_SERVER_IP:${PORT}\n`));
SERVERCODE

cd server && npm install > /dev/null 2>&1 && cd ..

# ==========================================
# Frontend (React + Full UI)
# ==========================================
echo -e "${CYAN}[2/3] Building UI (Glassmorphism + Features)...${NC}"

cat << 'EOF' > client/package.json
{
  "name": "dac-ui", "private": true, "version": "2.0.0", "type": "module",
  "scripts": { "dev": "vite", "build": "vite build" },
  "dependencies": { "react": "^18.2.0", "react-dom": "^18.2.0", "axios": "^1.6.2", "lucide-react": "^0.294.0", "framer-motion": "^10.16.5", "qrcode.react": "^3.1.0" },
  "devDependencies": { "@vitejs/plugin-react": "^4.2.0", "autoprefixer": "^10.4.16", "postcss": "^8.4.32", "tailwindcss": "^3.3.6", "vite": "^5.0.4" }
}
EOF

cat << 'EOF' > client/vite.config.js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({ plugins: [react()], server: { host: '0.0.0.0', port: 5173 } })
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
@import url('https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/Vazirmatn-font-face.css');
@tailwind base; @tailwind components; @tailwind utilities;
body { margin: 0; font-family: 'Vazirmatn', sans-serif; background: #0f0c29; direction: rtl; }
@keyframes pulse-green { 0% { box-shadow: 0 0 0 0 rgba(74, 222, 128, 0.7); } 70% { box-shadow: 0 0 0 8px rgba(74, 222, 128, 0); } 100% { box-shadow: 0 0 0 0 rgba(74, 222, 128, 0); } }
.pulse-green { animation: pulse-green 2s infinite; }
.bg-animated { background: linear-gradient(-45deg, #0f0c29, #302b63, #1a1a2e, #16213e); background-size: 400% 400%; animation: gradientShift 15s ease infinite; }
@keyframes gradientShift { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
EOF

# --- THE MASSIVE APP COMPONENT ---
cat << 'FRONTENDCODE' > client/src/App.jsx
import { useState, useEffect } from 'react';
import axios from 'axios';
import { motion, AnimatePresence } from 'framer-motion';
import { QRCodeSVG } from 'qrcode.react';
import { LayoutDashboard, Users, UserPlus, Handshake, Settings, LogOut, Menu, X, Plus, RefreshCw, Ban, Trash2, QrCode, Wifi } from 'lucide-react';

const api = axios.create({ baseURL: '/api', withCredentials: true });

function formatBytes(bytes) { if (bytes === 0) return '0 B'; const k = 1024; const sizes = ['B', 'MB', 'GB', 'TB']; const i = Math.floor(Math.log(bytes) / Math.log(k)); return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i]; }

export default function App() {
    const [loggedIn, setLoggedIn] = useState(false);
    const [authForm, setAuthForm] = useState({ url: '', username: '', password: '' });
    const [page, setPage] = useState('dashboard');
    const [data, setData] = useState({ inbounds: [], users: [] });
    const [agents, setAgents] = useState([]);
    const [drawer, setDrawer] = useState({ open: false, user: null });
    const [modal, setModal] = useState({ open: false, type: '' }); // type: 'createUser', 'createAgent'
    const [sidebarOpen, setSidebarOpen] = useState(false);

    // Form States
    const [userForm, setUserForm] = useState({ name: '', inboundId: '', daysLimit: 30, gbLimit: 10, startOnFirstConnect: true, agentId: '' });
    const [agentForm, setAgentForm] = useState({ username: '', password: '', name: '', phone: '', default_inbound_id: '' });

    useEffect(() => { api.get('/auth/check').then(r => { if(r.data.loggedIn) fetchAll(); else setLoggedIn(false); }); }, []);

    const login = async (e) => {
        e.preventDefault();
        try { const r = await api.post('/auth/login', authForm); if(r.data.success) { setLoggedIn(true); fetchAll(); } } catch(e) { alert("خطا در اتصال"); }
    };

    const fetchAll = () => {
        api.get('/data').then(r => setData(r.data));
        api.get('/agents').then(r => setAgents(r.data));
    };

    const handleCreateUser = async () => {
        await api.post('/users/create', userForm);
        setModal({open:false, type:''}); fetchAll();
    };

    const handleUserAction = async (action, value) => {
        await api.post('/users/action', { userId: drawer.user.id, inboundId: drawer.user.inboundId, action, value });
        setDrawer({open:false, user:null}); fetchAll();
    };

    const handleCreateAgent = async () => {
        await api.post('/agents', agentForm);
        setModal({open:false, type:''}); fetchAll();
    };

    const StatusLight = ({ status }) => {
        const c = { active: 'bg-green-400 pulse-green', disabled: 'bg-blue-900', expired: 'bg-red-500' };
        return <div className={`w-3 h-3 rounded-full ${c[status] || 'bg-gray-500'}`}></div>;
    };

    const ProgressBar = ({ value, max }) => {
        const p = max === 0 ? 100 : Math.min((value / max) * 100, 100);
        const c = p > 50 ? 'from-emerald-500 to-green-400' : p > 20 ? 'from-yellow-500 to-orange-400' : 'from-red-500 to-rose-400';
        return <div className="w-24 h-1.5 bg-gray-700/50 rounded-full overflow-hidden"><motion.div initial={{width:0}} animate={{width:`${p}%`}} transition={{duration:1}} className={`h-full bg-gradient-to-l ${c} rounded-full`}/></div>;
    };

    if (!loggedIn) return (
        <div className="min-h-screen bg-animated flex items-center justify-center p-4">
            <motion.form onSubmit={login} initial={{opacity:0, y:50}} animate={{opacity:1,y:0}} className="w-full max-w-md bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-8 shadow-2xl">
                <h1 className="text-3xl font-bold bg-gradient-to-l from-purple-400 to-blue-400 bg-clip-text text-transparent mb-8 text-center">DAC Panel</h1>
                <p className="text-gray-400 text-xs text-center mb-6">با اطلاعات ورود پنل 3X-UI خود وارد شوید</p>
                <input required placeholder="آدرس پنل (مثل http://ip:2053)" value={authForm.url} onChange={e=>setAuthForm({...authForm, url:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white mb-4 focus:outline-none focus:border-purple-500"/>
                <input required placeholder="نام کاربری" value={authForm.username} onChange={e=>setAuthForm({...authForm, username:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white mb-4 focus:outline-none focus:border-purple-500"/>
                <input required type="password" placeholder="رمز عبور" value={authForm.password} onChange={e=>setAuthForm({...authForm, password:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white mb-6 focus:outline-none focus:border-purple-500"/>
                <button type="submit" className="w-full py-3 rounded-xl bg-gradient-to-l from-purple-600 to-blue-600 text-white font-bold hover:opacity-90 transition">ورود به پنل</button>
            </motion.form>
        </div>
    );

    return (
        <div className="flex min-h-screen font-vazir text-white overflow-hidden relative">
            <div className="bg-animated absolute inset-0 z-0" />
            
            {/* Sidebar */}
            <motion.aside initial={{x:300}} animate={{x: sidebarOpen ? 0 : (window.innerWidth > 768 ? 0 : 300)}} className="fixed md:relative z-30 w-72 h-screen p-4 flex flex-col gap-2 bg-white/5 backdrop-blur-xl border-l border-white/10">
                <div className="flex items-center justify-between p-4 border-b border-white/10 mb-4">
                    <h1 className="text-xl font-bold text-purple-400">DAC Panel</h1>
                    <button className="md:hidden" onClick={()=>setSidebarOpen(false)}><X size={24}/></button>
                </div>
                <nav className="flex flex-col gap-1 flex-1">
                    {[
                        {id:'dashboard', l:'داشبورد', i:<LayoutDashboard size={20}/>},
                        {id:'users', l:'کاربران', i:<Users size={20}/>},
                        {id:'agents', l:'نمایندگان', i:<Handshake size={20}/>},
                        {id:'settings', l:'تنظیمات', i:<Settings size={20}/>}
                    ].map(m=>(
                        <motion.div key={m.id} whileHover={{x:-5}} onClick={()=>{setPage(m.id); setSidebarOpen(false);}} className={`flex items-center gap-3 p-3 rounded-xl cursor-pointer text-gray-300 hover:bg-white/10 hover:text-white transition-all border-r-2 ${page===m.id?'bg-white/10 border-purple-500':'border-transparent'}`}>
                            {m.i}<span className="text-sm">{m.l}</span>
                        </motion.div>
                    ))}
                </nav>
                <button onClick={()=>api.post('/auth/logout').then(()=>setLoggedIn(false))} className="flex items-center gap-3 p-3 rounded-xl text-red-400 hover:bg-red-500/10 mt-auto"><LogOut size={20}/>خروج</button>
            </motion.aside>

            {/* Main Content */}
            <main className="flex-1 relative z-10 p-6 md:p-10 overflow-y-auto">
                <button className="mb-6 md:hidden bg-white/10 p-2 rounded-lg" onClick={()=>setSidebarOpen(true)}><Menu size={24}/></button>

                {page === 'dashboard' && (
                    <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} className="space-y-6">
                        <h2 className="text-2xl font-bold">داشبورد</h2>
                        <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
                            {[{t:'کل کاربران', v:data.users.length, c:'text-blue-400'}, {t:'فعال', v:data.users.filter(u=>u.status==='active').length, c:'text-green-400'}, {t:'منقضی/غیرفعال', v:data.users.filter(u=>u.status!=='active').length, c:'text-red-400'}, {t:'نمایندگان', v:agents.length, c:'text-purple-400'}].map((c,i)=>(
                                <div key={i} className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-6 hover:bg-white/10 transition"><p className="text-gray-400 text-sm">{c.t}</p><p className={`text-3xl font-bold mt-2 ${c.c}`}>{c.v}</p></div>
                            ))}
                        </div>
                    </motion.div>
                )}

                {page === 'users' && (
                    <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} className="space-y-4">
                        <div className="flex justify-between items-center">
                            <h2 className="text-2xl font-bold">کاربران</h2>
                            <motion.button whileTap={{scale:0.9}} onClick={()=>{setUserForm({name:'', inboundId: data.inbounds[0]?.id||'', daysLimit:30, gbLimit:10, startOnFirstConnect:true, agentId:''}); setModal({open:true, type:'createUser'});}} className="flex items-center gap-2 px-4 py-2 rounded-xl bg-emerald-500/20 text-emerald-300 border border-emerald-500/30"><UserPlus size={18}/>ساخت کاربر</motion.button>
                        </div>
                        <div className="space-y-3">
                            {data.users.map(u=>{
                                const daysLeft = u.expiryTime > 0 ? Math.ceil((u.expiryTime*1000 - Date.now())/(86400000)) : '∞';
                                const usedGb = (u.up + u.down) / 1073741824;
                                const totalGb = u.totalGB === 0 ? '∞' : u.totalGB;
                                return (
                                    <motion.div key={u.id} whileHover={{scale:1.01}} onClick={()=>setDrawer({open:true, user:u})} className="flex items-center justify-between bg-white/5 backdrop-blur-xl border border-white/10 rounded-xl p-4 cursor-pointer hover:bg-white/10 transition-all">
                                        <div className="flex items-center gap-3"><StatusLight status={u.status}/><div><p className="font-bold text-sm">{u.name}</p><p className="text-xs text-gray-500">{u.agentName} | {u.protocol}</p></div></div>
                                        <div className="hidden md:flex items-center gap-6">
                                            <div className="flex items-center gap-2"><span className="text-xs text-gray-400 w-12">{daysLeft} روز</span>{typeof daysLeft === 'number' && <ProgressBar value={daysLeft} max={30}/>}</div>
                                            <div className="flex items-center gap-2"><span className="text-xs text-gray-400 w-20">{usedGb.toFixed(1)}/{totalGb} GB</span>{typeof totalGb === 'number' && <ProgressBar value={totalGb - usedGb} max={totalGb}/>}</div>
                                        </div>
                                        <button className="px-4 py-1.5 rounded-lg bg-purple-500/20 text-purple-300 text-xs border border-purple-500/30">مدیریت</button>
                                    </motion.div>
                                );
                            })}
                        </div>
                    </motion.div>
                )}

                {page === 'agents' && (
                    <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} className="space-y-4">
                        <div className="flex justify-between items-center">
                            <h2 className="text-2xl font-bold">نمایندگان</h2>
                            <motion.button whileTap={{scale:0.9}} onClick={()=>{setAgentForm({username:'',password:'',name:'',phone:'',default_inbound_id:''}); setModal({open:true, type:'createAgent'});}} className="flex items-center gap-2 px-4 py-2 rounded-xl bg-blue-500/20 text-blue-300 border border-blue-500/30"><Plus size={18}/>افزودن نماینده</motion.button>
                        </div>
                        <div className="grid md:grid-cols-2 gap-4">
                            {agents.map(a=>(
                                <div key={a.id} className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-xl p-6">
                                    <h3 className="font-bold text-lg text-purple-400">{a.name}</h3>
                                    <p className="text-gray-400 text-sm">@{a.username} | {a.phone}</p>
                                    <p className="mt-4">موجودی: <span className="text-green-400 font-bold">{a.balance} تومان</span></p>
                                    <div className="flex gap-2 mt-4">
                                        <button onClick={()=>{const v=prompt('مبلغ شارژ به تومان:'); if(v) api.post('/agents/charge',{id:a.id,amount:v}).then(fetchAll);}} className="text-xs px-3 py-1 bg-yellow-500/20 text-yellow-300 rounded-lg">شارژ حساب</button>
                                    </div>
                                </div>
                            ))}
                        </div>
                    </motion.div>
                )}
            </main>

            {/* USER DRAWER (Slide In) */}
            <AnimatePresence>
                {drawer.open && drawer.user && (
                    <>
                        <motion.div initial={{opacity:0}} animate={{opacity:1}} exit={{opacity:0}} className="fixed inset-0 bg-black/60 backdrop-blur-sm z-40" onClick={()=>setDrawer({open:false, user:null})}/>
                        <motion.div initial={{x:500}} animate={{x:0}} exit={{x:500}} transition={{type:"spring", damping:25}} className="fixed left-0 top-0 h-full w-full max-w-md bg-slate-900/90 backdrop-blur-xl border-l border-white/10 z-50 p-6 shadow-2xl overflow-y-auto">
                            <h2 className="text-xl font-bold mb-6 text-purple-400">{drawer.user.name}</h2>
                            <p className="text-sm text-gray-400 mb-6">لینک ساب: <span className="text-blue-400 break-all">{drawer.user.subLink || 'ندارد'}</span></p>
                            
                            {drawer.user.subLink && (
                                <div className="flex justify-center mb-6 bg-white/5 p-4 rounded-xl">
                                    <QRCodeSVG value={drawer.user.subLink} size={180} bgColor="transparent" fgColor="#ffffff"/>
                                </div>
                            )}

                            <div className="space-y-3">
                                <button onClick={()=>handleUserAction('addVolume', prompt('مقدار حجم (GB):'))} className="w-full py-3 rounded-xl bg-blue-500/20 text-blue-300 border border-blue-500/30 hover:bg-blue-500/30 transition flex items-center justify-center gap-2"><Plus size={18}/>افزودن حجم</button>
                                <button onClick={()=>handleUserAction('renew', prompt('تعداد روز تمدید:'))} className="w-full py-3 rounded-xl bg-emerald-500/20 text-emerald-300 border border-emerald-500/30 hover:bg-emerald-500/30 transition flex items-center justify-center gap-2"><RefreshCw size={18}/>تمدید اشتراک</button>
                                <button onClick={()=>handleUserAction('toggle')} className={`w-full py-3 rounded-xl border transition flex items-center justify-center gap-2 ${drawer.user.enable ? 'bg-red-500/20 text-red-300 border-red-500/30' : 'bg-green-500/20 text-green-300 border-green-500/30'}`}>{drawer.user.enable ? <Ban size={18}/> : <Wifi size={18}/>}{drawer.user.enable ? 'غیرفعال کردن' : 'فعال کردن'}</button>
                                <button onClick={()=>{handleUserAction('delete');}} className="w-full py-3 rounded-xl bg-rose-500/10 text-rose-400 border border-rose-500/20 hover:bg-rose-500/20 transition mt-8 flex items-center justify-center gap-2"><Trash2 size={18}/>حذف کاربر</button>
                            </div>
                        </motion.div>
                    </>
                )}
            </AnimatePresence>

            {/* MODALS (Create User / Agent) */}
            <AnimatePresence>
                {modal.open && (
                    <>
                        <motion.div initial={{opacity:0}} animate={{opacity:1}} exit={{opacity:0}} className="fixed inset-0 bg-black/60 backdrop-blur-sm z-40" onClick={()=>setModal({open:false, type:''})}/>
                        <motion.div initial={{scale:0.9, opacity:0}} animate={{scale:1, opacity:1}} exit={{scale:0.9, opacity:0}} className="fixed inset-0 m-auto w-fit h-fit bg-slate-900/90 backdrop-blur-xl border border-white/10 rounded-2xl p-8 z-50 shadow-2xl">
                            
                            {modal.type === 'createUser' && (
                                <div className="w-96 space-y-4">
                                    <h2 className="text-xl font-bold text-purple-400">ساخت کاربر جدید</h2>
                                    <input placeholder="نام کاربری (خالی = خودکار)" value={userForm.name} onChange={e=>setUserForm({...userForm, name:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                    <select value={userForm.inboundId} onChange={e=>setUserForm({...userForm, inboundId:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white">
                                        {data.inbounds.map(ib=><option key={ib.id} value={ib.id} className="bg-slate-800">{ib.tag} ({ib.protocol})</option>)}
                                    </select>
                                    <div className="grid grid-cols-2 gap-4">
                                        <input type="number" placeholder="روز اشتراک" value={userForm.daysLimit} onChange={e=>setUserForm({...userForm, daysLimit:e.target.value})} className="bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                        <input type="number" placeholder="حجم (GB)" value={userForm.gbLimit} onChange={e=>setUserForm({...userForm, gbLimit:e.target.value})} className="bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                    </div>
                                    <label className="flex items-center gap-2 text-sm text-gray-300 cursor-pointer"><input type="checkbox" checked={userForm.startOnFirstConnect} onChange={e=>setUserForm({...userForm, startOnFirstConnect: e.target.checked})} className="accent-purple-500"/>شروع از زمان اولین اتصال</label>
                                    
                                    <select value={userForm.agentId} onChange={e=>setUserForm({...userForm, agentId:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white">
                                        <option value="" className="bg-slate-800">بدون نماینده (مدیر)</option>
                                        {agents.map(a=><option key={a.id} value={a.id} className="bg-slate-800">{a.name}</option>)}
                                    </select>

                                    <button onClick={handleCreateUser} className="w-full py-3 rounded-xl bg-gradient-to-l from-purple-600 to-blue-600 text-white font-bold">ساخت کاربر</button>
                                </div>
                            )}

                            {modal.type === 'createAgent' && (
                                <div className="w-96 space-y-4">
                                    <h2 className="text-xl font-bold text-blue-400">افزودن نماینده</h2>
                                    <input placeholder="نام و نام خانوادگی" value={agentForm.name} onChange={e=>setAgentForm({...agentForm, name:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                    <input placeholder="نام کاربری" value={agentForm.username} onChange={e=>setAgentForm({...agentForm, username:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                    <input placeholder="رمز عبور" value={agentForm.password} onChange={e=>setAgentForm({...agentForm, password:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                    <input placeholder="شماره موبایل" value={agentForm.phone} onChange={e=>setAgentForm({...agentForm, phone:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white"/>
                                    <select value={agentForm.default_inbound_id} onChange={e=>setAgentForm({...agentForm, default_inbound_id:e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white">
                                        <option value="" className="bg-slate-800">اینباند پیش‌فرض انتخاب نشده</option>
                                        {data.inbounds.map(ib=><option key={ib.id} value={ib.id} className="bg-slate-800">{ib.tag}</option>)}
                                    </select>
                                    <button onClick={handleCreateAgent} className="w-full py-3 rounded-xl bg-gradient-to-l from-blue-600 to-cyan-600 text-white font-bold">ثبت نماینده</button>
                                </div>
                            )}
                        </motion.div>
                    </>
                )}
            </AnimatePresence>
        </div>
    );
}
FRONTENDCODE

echo -e "${CYAN}[3/3] Compiling Final Production Build...${NC}"
cd client && npm install > /dev/null 2>&1 && npm run build > /dev/null 2>&1 && cd ..

clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}             ✅ DAC Panel v2.0 Installed!             ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${NC}"
echo -e "پنل با تمام ویژگی‌های پایه نصب شد."
echo -e "برای اجرا: ${PURPLE}cd /root/dac-panel/server && npm start${NC}"
echo -e "آدرس: ${CYAN}http://YOUR_SERVER_IP:3000${NC}"
echo -e "${RED}توصیه: حتما از دستور 'npm i -g pm2' و سپس 'pm2 start index.js --name dac' استفاده کنید تا پنل خاموش نشود.${NC}"

cd server && npm start
