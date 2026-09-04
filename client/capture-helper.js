#!/usr/bin/env node
// StreamRelay Screen Capture Helper - conecta DIRETO no relay local (sem Tor loop)
import { execSync } from 'child_process';
import fs from 'fs';
import WebSocket from 'ws';

const RELAY_PORT = parseInt(process.env.RELAY_PORT || '8080');
const FPS = parseInt(process.env.FPS || '10');
const INTERVAL_MS = 1000 / FPS;

let roomId = null;
let monitors = [];
let wsMap = new Map();
let frameCounts = new Map();

function getMonitors() {
    try {
        const out = execSync(`hyprctl monitors -j 2>/dev/null || wlr-randr --json 2>/dev/null || echo '[]'`, { encoding: 'utf8', timeout: 2000 });
        const j = JSON.parse(out);
        if (Array.isArray(j) && j.length > 0) {
            const names = j.map(m => m.name || m.model || "").filter(Boolean);
            if (names.length) return names;
        }
    } catch {}
    try {
        const out = execSync(`wlr-randr 2>/dev/null | grep -E "^[^ ]" | awk '{print $1}'`, { encoding: 'utf8', timeout: 2000 });
        const names = out.split('\n').map(s => s.trim()).filter(Boolean);
        if (names.length) return names;
    } catch {}
    return [];
}

function connectMonitor(monitor, room) {
    return new Promise((resolve, reject) => {
        const s = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
        s.on('open', () => s.send(JSON.stringify({ type: 'host', room })));
        s.on('message', (data) => {
            try {
                const msg = JSON.parse(data.toString());
                if (msg.type === 'room') {
                    console.log(`[Helper] Sala ${room} (${monitor || 'full'}) criada`);
                    wsMap.set(room, s);
                    frameCounts.set(room, 0);
                    resolve(room);
                }
            } catch {}
        });
        s.on('error', (e) => { console.error(`[Helper] Erro WS ${room}:`, e.message); reject(e); });
        s.on('close', () => console.log(`[Helper] Desconectado ${room}`));
    });
}

async function connectAll(baseRoom) {
    monitors = getMonitors();
    if (monitors.length <= 1) {
        const ws = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
        return new Promise((resolve, reject) => {
            ws.on('open', () => ws.send(JSON.stringify({ type: 'host', room: baseRoom || undefined })));
            ws.on('message', (data) => {
                try {
                    const msg = JSON.parse(data.toString());
                    if (msg.type === 'room') {
                        roomId = msg.id;
                        console.log(`[Helper] Sala criada: ${roomId} (compartilhe este ID)`);
                        console.log(`[Helper] Conectado direto ao relay :${RELAY_PORT}`);
                        wsMap.set(roomId, ws);
                        monitors = [""];
                        resolve(roomId);
                    }
                } catch {}
            });
            ws.on('error', reject);
            ws.on('close', () => console.log('[Helper] Desconectado'));
        });
    } else {
        console.log(`[Helper] Detectados ${monitors.length} monitores: ${monitors.join(', ')}`);
        const base = await connectMonitor(null, baseRoom || `base-${Math.random().toString(36).slice(2, 6)}`);
        roomId = base;
        for (const mon of monitors) {
            const r = `${base}-${mon}`;
            await connectMonitor(mon, r);
        }
        console.log(`[Helper] Salas: ${Array.from(wsMap.keys()).join(', ')}`);
        return base;
    }
}

function captureFrame(monitor) {
    try {
        const target = monitor ? `-o ${monitor}` : "";
        const buf = execSync(`grim ${target} -t jpeg -q 60 - 2>/dev/null`, { timeout: 3000, maxBuffer: 10*1024*1024 });
        if (!buf || buf.length < 100) return null;
        const header = Buffer.alloc(13);
        header.write('SRF1', 0); header.writeUInt8(0, 4);
        header.writeUInt16LE(1920, 5); header.writeUInt16LE(1080, 7); header.writeUInt32LE(Date.now() % 4294967296, 9);
        return Buffer.concat([header, buf]);
    } catch (e) {
        return null;
    }
}

async function main() {
    console.log(`[Helper] StreamRelay Screen Capture`);
    console.log(`[Helper] FPS: ${FPS}, Relay: 127.0.0.1:${RELAY_PORT}`);
    await connectAll(null);
    console.log(`[Helper] Capturando ${monitors.length} tela(s)... Pressione Ctrl+C para parar`);
    setInterval(() => {
        for (const [room, s] of wsMap) {
            if (s.readyState !== WebSocket.OPEN) continue;
            const mon = room === roomId ? null : room.replace(roomId + "-", "");
            const pkt = captureFrame(monitors.length > 1 ? mon : null);
            if (pkt) {
                s.send(pkt);
                const c = (frameCounts.get(room) || 0) + 1;
                frameCounts.set(room, c);
                if (c % 30 === 0) console.log(`[Helper] ${room}: ${c} frames`);
            }
        }
    }, INTERVAL_MS);
    process.on('SIGINT', () => {
        console.log(`\n[Helper] Parado. Salas ${Array.from(wsMap.keys()).join(', ')}`);
        for (const s of wsMap.values()) try { s.close(); } catch {}
        process.exit(0);
    });
}
main();
