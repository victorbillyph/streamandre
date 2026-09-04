#!/usr/bin/env node
// StreamRelay Screen Capture Helper
// Captura tela com grim e envia frames via WebSocket ao relay

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const WebSocket = require('ws');
const path = require('path');

const BRIDGE_PORT = process.env.BRIDGE_PORT || 6789;
const FPS = parseInt(process.env.FPS || '10');
const INTERVAL_MS = 1000 / FPS;

let ws = null;
let running = false;
let frameCount = 0;

function connect() {
    return new Promise((resolve, reject) => {
        ws = new WebSocket(`ws://127.0.0.1:${BRIDGE_PORT}`);
        ws.on('open', () => {
            console.log('[Helper] Conectado ao bridge');
            resolve();
        });
        ws.on('error', (e) => {
            console.error('[Helper] Erro WS:', e.message);
            reject(e);
        });
        ws.on('close', () => {
            console.log('[Helper] Desconectado');
            if (running) setTimeout(connect, 2000);
        });
    });
}

function captureFrame() {
    try {
        const tmpFile = '/tmp/sr_capture.webp';
        execSync(`grim -t webp -q 50 "${tmpFile}" 2>/dev/null`, { timeout: 3000 });
        
        if (!fs.existsSync(tmpFile)) return null;
        
        const buf = fs.readFileSync(tmpFile);
        if (buf.length < 100) return null;
        
        // WebP header: width/height at offset 26/28 (14-bit LE)
        let width = 1920, height = 1080;
        try {
            const wh = buf.readUInt16LE(26);
            width = wh & 0x3FFF;
            height = buf.readUInt16LE(28) & 0x3FFF;
        } catch {}

        const header = Buffer.alloc(13);
        header.write('SRF1', 0);
        header.writeUInt8(1, 4); // webp
        header.writeUInt16LE(width, 5);
        header.writeUInt16LE(height, 7);
        header.writeUInt32LE(Date.now(), 9);

        return Buffer.concat([header, buf]);
    } catch (e) {
        return null;
    }
}

function sendFrame(packet) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(packet);
        frameCount++;
        if (frameCount % 30 === 0) {
            console.log(`[Helper] ${frameCount} frames enviados`);
        }
    }
}

async function main() {
    console.log(`[Helper] StreamRelay Screen Capture`);
    console.log(`[Helper] FPS: ${FPS}, Bridge: ${BRIDGE_PORT}`);
    console.log(`[Helper] Pressione Ctrl+C para parar`);

    try {
        await connect();
    } catch {
        console.error('[Helper] Nao foi possivel conectar ao bridge. Inicie o bridge primeiro.');
        console.error(`[Helper] Execute: node bridge.mjs <onion-address>`);
        process.exit(1);
    }

    running = true;

    setInterval(() => {
        if (!running) return;
        const packet = captureFrame();
        if (packet) sendFrame(packet);
    }, INTERVAL_MS);

    process.on('SIGINT', () => {
        console.log(`\n[Helper] Parado. ${frameCount} frames enviados.`);
        running = false;
        if (ws) ws.close();
        process.exit(0);
    });
}

main();
