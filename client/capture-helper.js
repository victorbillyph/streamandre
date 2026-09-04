#!/usr/bin/env node
// StreamRelay Screen Capture Helper - conecta DIRETO no relay local (sem Tor loop)
import { execSync } from 'child_process';
import fs from 'fs';
import WebSocket from 'ws';

const RELAY_PORT = parseInt(process.env.RELAY_PORT || '8080');
const FPS = parseInt(process.env.FPS || '10');
const INTERVAL_MS = 1000 / FPS;

let ws = null;
let roomId = null;
let frameCount = 0;

function connect() {
    return new Promise((resolve, reject) => {
        ws = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
        ws.on('open', () => {
            ws.send(JSON.stringify({ type: 'host' }));
        });
        ws.on('message', (data) => {
            try {
                const msg = JSON.parse(data);
                if (msg.type === 'room') {
                    roomId = msg.id;
                    console.log(`[Helper] Sala criada: ${roomId} (compartilhe este ID)`);
                    console.log(`[Helper] Conectado direto ao relay :${RELAY_PORT}`);
                    resolve(roomId);
                }
            } catch {}
        });
        ws.on('error', (e) => { console.error('[Helper] Erro WS:', e.message); reject(e); });
        ws.on('close', () => console.log('[Helper] Desconectado do relay'));
    });
}

function captureFrame() {
    try {
        const tmpFile = '/tmp/sr_capture.webp';
        execSync(`grim -t webp -q 50 "${tmpFile}" 2>/dev/null`, { timeout: 3000 });
        if (!fs.existsSync(tmpFile)) return null;
        const buf = fs.readFileSync(tmpFile);
        if (buf.length < 100) return null;
        let width = 1920, height = 1080;
        try { const w = buf.readUInt16LE(26); width = w & 0x3FFF; height = buf.readUInt16LE(28) & 0x3FFF; } catch {}
        const header = Buffer.alloc(13);
        header.write('SRF1', 0); header.writeUInt8(1, 4);
        header.writeUInt16LE(width, 5); header.writeUInt16LE(height, 7); header.writeUInt32LE(Date.now(), 9);
        return Buffer.concat([header, buf]);
    } catch { return null; }
}

async function main() {
    console.log(`[Helper] StreamRelay Screen Capture`);
    console.log(`[Helper] FPS: ${FPS}, Relay: 127.0.0.1:${RELAY_PORT}`);
    await connect();
    console.log(`[Helper] Capturando... Pressione Ctrl+C para parar`);
    setInterval(() => {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        const pkt = captureFrame();
        if (pkt) { ws.send(pkt); frameCount++; if (frameCount % 30 === 0) console.log(`[Helper] ${frameCount} frames`); }
    }, INTERVAL_MS);
    process.on('SIGINT', () => { console.log(`\n[Helper] Parado. ${frameCount} frames, sala ${roomId}`); try { ws.close(); } catch {} process.exit(0); });
}
main();
