#!/bin/bash

# رنگ‌ها برای زیبایی ترمینال
RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${PURPLE}"
echo "===================================================="
echo "        DAC Panel - Professional Installer          "
echo "===================================================="
echo -e "${NC}"

# 1. رفع خطاهای احتمالی سرور (نصب پیش‌نیازهای سیستمی که باعث خطای نصب پکیج‌ها میشن)
echo -e "${CYAN}[1/6] Fixing server dependencies & installing build tools...${NC}"
sudo apt-get update -y
sudo apt-get install -y curl wget git build-essential python3 -y > /dev/null 2>&1

# 2. نصب Node.js نسخه 20 بدون اخطار
echo -e "${CYAN}[2/6] Installing Node.js v20...${NC}"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - > /dev/null 2>&1
    sudo apt-get install -y nodejs > /dev/null 2>&1
fi

# 3. ساخت پوشه پروژه
echo -e "${CYAN}[3/6] Creating project directories...${NC}"
mkdir -p /root/dac-panel/server
mkdir -p /root/dac-panel/client/src
mkdir -p /root/dac-panel/client/public
cd /root/dac-panel

# ==========================================
# بخش بک‌اند (Server)
# ==========================================
echo -e "${CYAN}[4/6] Configuring Backend...${NC}"

# فایل package.json سرور
cat << 'EOF' > server/package.json
{
  "name": "dac-panel-server",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "better-sqlite3": "^9.4.3",
    "axios": "^1.6.2"
  }
}
EOF

# فایل اصلی سرور (اتصال به دیتابیس، ذخیره تنظیمات رمزنگاری شده، سرویس فرانت)
cat << 'EOF' > server/index.js
import express from 'express';
import cors from 'cors';
import path from 'path';
import { fileURLToPath } from 'url';
import Database from 'better-sqlite3';
import axios from 'axios';
import crypto from 'crypto';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = 3000;
app.use(cors());
app.use(express.json());

// دیتابیس
const db = new Database(path.join(__dirname, 'dac.db'));
db.exec(`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)`);

// رمزنگاری (برای امنیت رمز x-ui در دیتابیس)
const ENC_KEY = crypto.randomBytes(32);
const IV = crypto.randomBytes(16);
const cipher = crypto.createCipheriv('aes-256-cbc', ENC_KEY, IV);
const decipher = crypto.createDecipheriv('aes-256-cbc', ENC_KEY, IV);

function encrypt(text) {
    let encrypted = cipher.update(text, 'utf8', 'hex');
    encrypted += cipher.final('hex');
    return encrypted;
}
function decrypt(text) {
    try {
        let dec = decipher.update(text, 'hex', 'utf8');
        dec += decipher.final('utf8');
        return dec;
    } catch (e) { return ""; }
}

// API دریافت تنظیمات
app.get('/api/settings/xui', (req, res) => {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get('xui_conn');
    if (row) {
        const s = JSON.parse(row.value);
        s.password = decrypt(s.password);
        res.json(s);
    } else {
        res.json({ url: '', username: '', password: '' });
    }
});

// API ذخیره تنظیمات
app.post('/api/settings/xui', (req, res) => {
    const { url, username, password } = req.body;
    const encPass = encrypt(password);
    db.prepare(`INSERT INTO settings (key, value) VALUES ('xui_conn', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .run(JSON.stringify({ url, username, password: encPass }));
    res.json({ message: 'تنظیمات با موفقیت ذخیره شد' });
});

// سرویس فایل‌های ساخته شده فرانت‌اند
app.use(express.static(path.join(__dirname, '../client/dist')));
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, '../client/dist/index.html'));
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`\n🚀 DAC Panel is running on: http://YOUR_SERVER_IP:${PORT}\n`);
});
EOF

cd server
npm install > /dev/null 2>&1
cd ..

# ==========================================
# بخش فرانت‌اند (Client - React + Vite)
# ==========================================
echo -e "${CYAN}[5/6] Building Beautiful Frontend (This may take a minute)...${NC}"

# فایل‌های پایه ری‌اکت
cat << 'EOF' > client/package.json
{
  "name": "dac-panel-client",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "axios": "^1.6.2",
    "lucide-react": "^0.294.0",
    "framer-motion": "^10.16.5"
  },
  "devDependencies": {
    "@types/react": "^18.2.37",
    "@types/react-dom": "^18.2.15",
    "@vitejs/plugin-react": "^4.2.0",
    "autoprefixer": "^10.4.16",
    "postcss": "^8.4.32",
    "tailwindcss": "^3.3.6",
    "vite": "^5.0.4"
  }
}
EOF

cat << 'EOF' > client/vite.config.js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({
  plugins: [react()],
  server: { host: '0.0.0.0', port: 5173 }
})
EOF

cat << 'EOF' > client/tailwind.config.js
/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      fontFamily: { vazir: ['Vazirmatn', 'sans-serif'] },
    },
  },
  plugins: [],
}
EOF

cat << 'EOF' > client/postcss.config.js
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
EOF

cat << 'EOF' > client/index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/vite.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>DAC Panel</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat << 'EOF' > client/src/main.jsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
import './index.css'
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>)
EOF

# فایل CSS (فونت وزیر آنلاین، گلس‌مورفیسم، انیمیشن پالس)
cat << 'EOF' > client/src/index.css
@import url('https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/Vazirmatn-font-face.css');
@tailwind base;
@tailwind components;
@tailwind utilities;
body { margin: 0; font-family: 'Vazirmatn', sans-serif; background: #0f0c29; direction: rtl; }
@keyframes pulse-green { 0% { box-shadow: 0 0 0 0 rgba(74, 222, 128, 0.7); } 70% { box-shadow: 0 0 0 8px rgba(74, 222, 128, 0); } 100% { box-shadow: 0 0 0 0 rgba(74, 222, 128, 0); } }
.pulse-green { animation: pulse-green 2s infinite; }
@keyframes gradientShift { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
.bg-animated { background: linear-gradient(-45deg, #0f0c29, #302b63, #1a1a2e, #16213e); background-size: 400% 400%; animation: gradientShift 15s ease infinite; }
EOF

# فایل اصلی اپلیکیشن (تمام ظاهر گلس‌مورفیسم، منو، فرم تنظیمات، لیست کاربران نمونه)
cat << 'EOF' > client/src/App.jsx
import { useState, useEffect } from 'react';
import { LayoutDashboard, Users, Settings, Save, Wifi, WifiOff, UserX, Ban, Menu, X, ChevronLeft } from 'lucide-react';
import { motion, AnimatePresence } from 'framer-motion';
import axios from 'axios';

const api = axios.create({ baseURL: 'http://localhost:3000/api' });

// دیتای فیک برای نمایش زیبایی لیست کاربران (بعداً از x-ui خوانده میشه)
const mockUsers = [
  { id: 1, name: 'user_ali', status: 'online', daysLeft: 25, totalGb: 10, usedGb: 3.5 },
  { id: 2, name: 'user_sara', status: 'offline', daysLeft: 10, totalGb: 5, usedGb: 2 },
  { id: 3, name: 'user_reza', status: 'expired', daysLeft: 0, totalGb: 20, usedGb: 20 },
  { id: 4, name: 'user_mina', status: 'disabled', daysLeft: 15, totalGb: 10, usedGb: 1 },
];

const StatusLight = ({ status }) => {
  const config = {
    online: { color: 'bg-green-400 pulse-green', icon: <Wifi size={12} className="text-green-400" /> },
    offline: { color: 'bg-gray-500', icon: <WifiOff size={12} className="text-gray-400" /> },
    expired: { color: 'bg-red-500', icon: <UserX size={12} className="text-red-400" /> },
    disabled: { color: 'bg-blue-900', icon: <Ban size={12} className="text-blue-400" /> },
  };
  return <div className={`w-3 h-3 rounded-full ${config[status].color} flex items-center justify-center`}></div>;
};

const ProgressBar = ({ value, max, type }) => {
  const percent = max === 0 ? 0 : Math.min((value / max) * 100, 100);
  const color = percent > 50 ? 'from-emerald-500 to-green-400' : percent > 20 ? 'from-yellow-500 to-orange-400' : 'from-red-500 to-rose-400';
  return (
    <div className="w-24 h-1.5 bg-gray-700/50 rounded-full overflow-hidden">
      <motion.div initial={{ width: 0 }} animate={{ width: `${percent}%` }} transition={{ duration: 1 }} className={`h-full bg-gradient-to-l ${color} rounded-full`} />
    </div>
  );
};

function App() {
  const [page, setPage] = useState('dashboard');
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [settings, setSettings] = useState({ url: '', username: '', password: '' });
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    api.get('/settings/xui').then(res => setSettings(res.data));
  }, []);

  const saveSettings = async () => {
    await api.post('/settings/xui', settings);
    setSaved(true);
    setTimeout(() => setSaved(false), 3000);
  };

  const menus = [
    { id: 'dashboard', label: 'داشبورد', icon: <LayoutDashboard size={20} /> },
    { id: 'users', label: 'کاربران', icon: <Users size={20} /> },
    { id: 'settings', label: 'تنظیمات', icon: <Settings size={20} /> },
  ];

  return (
    <div className="flex min-h-screen font-vazir text-white overflow-hidden relative">
      <div className="bg-animated absolute inset-0 z-0" />
      
      <AnimatePresence>
        {sidebarOpen && <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="fixed inset-0 bg-black/60 z-20 md:hidden" onClick={() => setSidebarOpen(false)} />}
      </AnimatePresence>

      {/* سایدبار */}
      <motion.aside initial={{ x: 300 }} animate={{ x: sidebarOpen ? 0 : (window.innerWidth > 768 ? 0 : 300) }} className="fixed md:relative z-30 w-72 h-screen p-4 flex flex-col gap-2 bg-white/5 backdrop-blur-xl border-l border-white/10">
        <div className="flex items-center justify-between p-4 border-b border-white/10 mb-4">
          <h1 className="text-xl font-bold bg-gradient-to-l from-purple-400 to-blue-400 bg-clip-text text-transparent tracking-wide">DAC Panel</h1>
          <button className="md:hidden text-gray-400" onClick={() => setSidebarOpen(false)}><X size={24} /></button>
        </div>
        <nav className="flex flex-col gap-1 flex-1">
          {menus.map(item => (
            <motion.div key={item.id} whileHover={{ x: -5 }} whileTap={{ scale: 0.95 }} onClick={() => { setPage(item.id); setSidebarOpen(false); }}
              className={`flex items-center gap-3 p-3 rounded-xl cursor-pointer text-gray-300 hover:bg-white/10 hover:text-white transition-all border-r-2 ${page === item.id ? 'bg-white/10 border-purple-500' : 'border-transparent'}`}>
              {item.icon} <span className="text-sm">{item.label}</span>
              <ChevronLeft className="mr-auto opacity-50" size={16} />
            </motion.div>
          ))}
        </nav>
      </motion.aside>

      {/* محتوا */}
      <main className="flex-1 relative z-10 p-6 md:p-10 overflow-y-auto">
        <button className="mb-6 md:hidden bg-white/10 p-2 rounded-lg" onClick={() => setSidebarOpen(true)}><Menu size={24} /></button>

        <AnimatePresence mode="wait">
          {page === 'dashboard' && (
            <motion.div key="dash" initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="grid grid-cols-1 md:grid-cols-3 gap-6">
              {[
                { title: 'کاربران فعال', val: '۱۲۰', color: 'text-green-400' },
                { title: 'کاربران منقضی', val: '۴۵', color: 'text-red-400' },
                { title: 'کل ترافیک سرور', val: '1.2 TB', color: 'text-blue-400' },
              ].map((card, i) => (
                <div key={i} className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-6 hover:bg-white/10 transition-all duration-300 hover:shadow-lg hover:shadow-purple-500/10">
                  <p className="text-gray-400 text-sm">{card.title}</p>
                  <p className={`text-3xl font-bold mt-2 ${card.color}`}>{card.val}</p>
                </div>
              ))}
            </motion.div>
          )}

          {page === 'users' && (
            <motion.div key="users" initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="space-y-3">
              <h2 className="text-xl font-bold mb-6">لیست کاربران</h2>
              {mockUsers.map(u => (
                <motion.div key={u.id} whileHover={{ scale: 1.01 }} className="flex items-center justify-between bg-white/5 backdrop-blur-xl border border-white/10 rounded-xl p-4 hover:bg-white/10 transition-all">
                  <div className="flex items-center gap-3">
                    <StatusLight status={u.status} />
                    <span className="font-bold text-sm">{u.name}</span>
                  </div>
                  <div className="hidden md:flex items-center gap-6">
                    <div className="flex items-center gap-2"><span className="text-xs text-gray-400 w-12">{u.daysLeft} روز</span><ProgressBar value={u.daysLeft} max={30} /></div>
                    <div className="flex items-center gap-2"><span className="text-xs text-gray-400 w-20">{u.usedGb}/{u.totalGb} GB</span><ProgressBar value={u.totalGb - u.usedGb} max={u.totalGb} /></div>
                  </div>
                  <button className="px-4 py-1.5 rounded-lg bg-purple-500/20 text-purple-300 text-xs border border-purple-500/30 hover:bg-purple-500/30 transition">مدیریت</button>
                </motion.div>
              ))}
            </motion.div>
          )}

          {page === 'settings' && (
            <motion.div key="settings" initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="max-w-2xl mx-auto">
              <div className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-8">
                <h2 className="text-xl font-bold mb-6 text-purple-400">اتصال به پنل 3X-UI</h2>
                <p className="text-gray-400 text-xs mb-6">اطلاعات پنل اصلی خود را وارد کنید. رمز عبور به صورت امن در دیتابیس رمزنگاری می‌شود.</p>
                
                <div className="space-y-4">
                  <div>
                    <label className="text-sm text-gray-300 block mb-1">آدرس پنل (مثل: http://1.2.3.4:2053)</label>
                    <input type="text" value={settings.url} onChange={e => setSettings({...settings, url: e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white focus:outline-none focus:border-purple-500 transition" />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <label className="text-sm text-gray-300 block mb-1">نام کاربری</label>
                      <input type="text" value={settings.username} onChange={e => setSettings({...settings, username: e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white focus:outline-none focus:border-purple-500 transition" />
                    </div>
                    <div>
                      <label className="text-sm text-gray-300 block mb-1">رمز عبور</label>
                      <input type="password" value={settings.password} onChange={e => setSettings({...settings, password: e.target.value})} className="w-full bg-white/5 border border-white/10 rounded-lg p-3 text-white focus:outline-none focus:border-purple-500 transition" />
                    </div>
                  </div>
                  
                  <motion.button whileTap={{ scale: 0.95 }} onClick={saveSettings} className="w-full mt-4 py-3 rounded-xl bg-gradient-to-l from-purple-600 to-blue-600 text-white font-bold flex items-center justify-center gap-2 hover:opacity-90 transition">
                    <Save size={18} /> ذخیره تنظیمات
                  </motion.button>

                  {saved && <p className="text-green-400 text-sm text-center mt-2">✅ تنظیمات با موفقیت رمزنگاری و ذخیره شد!</p>}
                </div>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </main>
    </div>
  );
}

export default App;
EOF

# نصب پکیج‌های فرانت‌اند
cd client
npm install > /dev/null 2>&1

# بیلد نهایی فرانت‌اند (تبدیل به فایل‌های استاتیک برای سرور)
echo -e "${CYAN}[6/6] Building Production Files...${NC}"
npm run build > /dev/null 2>&1
cd ..

# ==========================================
# پایان و راه‌اندازی
# ==========================================
clear
echo -e "${GREEN}"
echo "===================================================="
echo "             ✅ DAC Panel Installed!                "
echo "===================================================="
echo -e "${NC}"
echo -e "پنل با موفقیت روی سرور شما نصب و بیلد شد."
echo -e "برای اجرای پنل، دستور زیر را بزنید:"
echo -e "${PURPLE}cd /root/dac-panel/server && npm start${NC}"
echo ""
echo -e "سپس در مرورگر خود آی‌پی سرور را با پورت ${CYAN}3000${NC} باز کنید:"
echo -e "${CYAN}http://YOUR_SERVER_IP:3000${NC}"
echo ""
echo -e "${RED}توجه: برای اینکه پنل با بستن ترمینال خاموش نشود، بهتر است از ابزارهایی مثل screen یا pm2 استفاده کنید.${NC}"

# اجرای خودکار برای اولین بار
echo -e "${CYAN}Starting DAC Panel for the first time...${NC}"
cd server && npm start
