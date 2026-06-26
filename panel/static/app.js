// 抖音 → YouTube 转推控制面板 - 前端脚本

const API = {
    async request(method, url, body = null) {
        const opts = { method, headers: { 'Content-Type': 'application/json' } };
        if (body) opts.body = JSON.stringify(body);
        const res = await fetch(url, opts);
        if (res.status === 401) { window.location.href = '/login'; throw new Error('Unauthorized'); }
        const data = await res.json();
        if (!res.ok) throw new Error(data.detail || 'Request failed');
        return data;
    },
    get(url) { return this.request('GET', url); },
    post(url, body) { return this.request('POST', url, body); },
    put(url, body) { return this.request('PUT', url, body); },
    del(url) { return this.request('DELETE', url); },
};

function toast(msg, type = 'info') {
    const container = document.getElementById('toast-container') || (() => {
        const c = document.createElement('div');
        c.id = 'toast-container';
        c.className = 'toast-container';
        document.body.appendChild(c);
        return c;
    })();
    const el = document.createElement('div');
    el.className = `toast toast-${type}`;
    el.textContent = msg;
    container.appendChild(el);
    setTimeout(() => { el.remove(); }, 4000);
}

function setCookie(name, value, days = 7) {
    const d = new Date(); d.setTime(d.getTime() + days * 86400000);
    document.cookie = `${name}=${value};expires=${d.toUTCString()};path=/`;
}

function getCookie(name) {
    const match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
    return match ? match[2] : null;
}

function formatTime(iso) {
    if (!iso) return '-';
    const d = new Date(iso);
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// Auth helpers
async function doLogin(username, password) {
    const data = await API.post('/api/auth/login', { username, password });
    setCookie('access_token', data.token, 7);
    window.location.href = '/dashboard';
}

async function doRegister(username, password) {
    const data = await API.post('/api/auth/register', { username, password });
    setCookie('access_token', data.token, 7);
    window.location.href = '/dashboard';
}

function doLogout() {
    setCookie('access_token', '', -1);
    window.location.href = '/login';
}
