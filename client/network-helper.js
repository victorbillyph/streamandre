#!/usr/bin/env node
// StreamRelay Decentralized Network Helper
// Cria hidden service proprio e participa da rede peer-to-peer

import { execSync } from 'child_process';
import fs from 'fs';
import WebSocket from 'ws';
import net from 'net';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(__dirname, '../network-data');
const PEERS_FILE = path.join(DATA_DIR, 'peers.json');
const IDENTITY_FILE = path.join(DATA_DIR, 'identity.json');
const TOR_DATA = path.join(DATA_DIR, 'tor');
const TOR_SOCKS = parseInt(process.env.TOR_SOCKS || '9050');
const RELAY_PORT = parseInt(process.env.RELAY_PORT || '8080');
const LISTEN_PORT = parseInt(process.env.LISTEN_PORT || '8888');
const FPS = parseInt(process.env.FPS || '10');

let ws = null;
let running = false;
let frameCount = 0;
let peers = [];
let identity = null;

// ==================== TOR ====================

function ensureTor() {
    if (ss_listening(TOR_SOCKS)) {
        console.log('[TOR] Ja rodando na porta', TOR_SOCKS);
        return;
    }

    console.log('[TOR] Iniciando...');

    const torBin = fs.existsSync('/usr/bin/tor') ? 'tor' : null;
    if (!torBin) {
        console.error('[TOR] Tor nao encontrado. Instale: sudo pacman -S tor');
        process.exit(1);
    }

    fs.mkdirSync(TOR_DATA, { recursive: true });
    fs.chmodSync(TOR_DATA, 0o700);

    const torrc = `
SocksPort ${TOR_SOCKS}
DataDirectory ${TOR_DATA}
HiddenServiceDir ${TOR_DATA}/hidden_service
HiddenServicePort 80 127.0.0.1:${RELAY_PORT}
Log notice file ${TOR_DATA}/tor.log
    `.trim();

    fs.writeFileSync(path.join(TOR_DATA, 'torrc'), torrc);
    execSync(`${torBin} -f ${TOR_DATA}/torrc &`, { stdio: 'ignore' });

    console.log('[TOR] Aguardando conexao...');
    for (let i = 0; i < 60; i++) {
        if (ss_listening(TOR_SOCKS)) {
            console.log('[TOR] Conectado!');
            return;
        }
        await sleep(1000);
        process.stdout.write('.');
    }
    console.error('\n[TOR] Falha ao conectar');
    process.exit(1);
}

function getOnionAddress() {
    const hostnameFile = path.join(TOR_DATA, 'hidden_service', 'hostname');
    if (fs.existsSync(hostnameFile)) {
        return fs.readFileSync(hostnameFile, 'utf8').trim();
    }
    return null;
}

function ss_listening(port) {
    try {
        const result = execSync(`ss -tlnp 2>/dev/null | grep ":${port}"`, { encoding: 'utf8' });
        return result.length > 0;
    } catch {
        return false;
    }
}

// ==================== IDENTITY ====================

function loadOrCreateIdentity() {
    if (fs.existsSync(IDENTITY_FILE)) {
        identity = JSON.parse(fs.readFileSync(IDENTITY_FILE, 'utf8'));
        console.log(`[ID] Identidade carregada: ${identity.name}`);
        return;
    }

    const name = `User-${Math.random().toString(36).substring(2, 8)}`;
    identity = {
        name,
        created: Date.now(),
        peers: []
    };

    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(IDENTITY_FILE, JSON.stringify(identity, null, 2));
    console.log(`[ID] Nova identidade criada: ${name}`);
}

// ==================== PEERS ====================

function loadPeers() {
    if (fs.existsSync(PEERS_FILE)) {
        peers = JSON.parse(fs.readFileSync(PEERS_FILE, 'utf8'));
    }
}

function savePeers() {
    fs.writeFileSync(PEERS_FILE, JSON.stringify(peers, null, 2));
}

function addPeer(onion, name = 'Unknown') {
    if (!peers.find(p => p.onion === onion)) {
        peers.push({ onion, name, added: Date.now(), lastSeen: Date.now() });
        savePeers();
        console.log(`[PEER] Adicionado: ${name} (${onion.substring(0, 20)}...)`);
    }
}

function updatePeerSeen(onion) {
    const peer = peers.find(p => p.onion === onion);
    if (peer) {
        peer.lastSeen = Date.now();
        savePeers();
    }
}

// ==================== SOCKS5 ====================

function connectViaSocks(host, port) {
    return new Promise((resolve, reject) => {
        const socket = net.createConnection(TOR_SOCKS, '127.0.0.1', () => {
            socket.write(Buffer.from([0x05, 0x01, 0x00]));
        });

        let step = 0;
        socket.on('data', (data) => {
            if (step === 0) {
                if (data[0] !== 0x05) { socket.destroy(); reject(new Error('SOCKS5 auth failed')); return; }
                step = 1;
                const hostBuf = Buffer.from(host);
                const buf = Buffer.alloc(7 + hostBuf.length);
                buf[0] = 0x05; buf[1] = 0x01; buf[2] = 0x00; buf[3] = 0x03;
                buf[4] = hostBuf.length;
                hostBuf.copy(buf, 5);
                buf.writeUInt16BE(port, 5 + hostBuf.length);
                socket.write(buf);
            } else if (step === 1) {
                if (data[1] !== 0x00) { socket.destroy(); reject(new Error(`SOCKS5 connect failed: ${data[1]}`)); return; }
                resolve(socket);
            }
        });

        socket.on('error', reject);
        socket.setTimeout(30000, () => { socket.destroy(); reject(new Error('Timeout')); });
    });
}

// ==================== RELAY SERVER ====================

const rooms = new Map();

function createRelayServer() {
    const wss = new WebSocket.Server({ port: RELAY_PORT });

    wss.on('connection', (ws) => {
        let currentRoom = null;
        let isHost = false;

        ws.on('message', (data, isBinary) => {
            if (isBinary) {
                if (isHost && currentRoom && currentRoom.host === ws) {
                    currentRoom.lastFrame = data;
                    for (const viewer of currentRoom.viewers) {
                        if (viewer.readyState === 1) viewer.send(data);
                    }
                }
                return;
            }

            let msg;
            try { msg = JSON.parse(data); } catch { return; }

            switch (msg.type) {
                case 'host': {
                    const roomId = msg.room || Math.random().toString(36).substring(2, 8);
                    if (rooms.has(roomId)) {
                        const existing = rooms.get(roomId);
                        if (existing.host) { ws.send(JSON.stringify({ type: 'error', msg: 'Room occupied' })); return; }
                        existing.host = ws;
                        isHost = true;
                        currentRoom = existing;
                    } else {
                        currentRoom = { host: ws, viewers: new Set(), lastFrame: null };
                        rooms.set(roomId, currentRoom);
                        isHost = true;
                    }
                    ws.send(JSON.stringify({ type: 'room', id: roomId }));
                    broadcastAnnounce(roomId);
                    console.log(`[RELAY] Host joined room ${roomId}`);
                    break;
                }
                case 'view': {
                    if (!msg.room) { ws.send(JSON.stringify({ type: 'error', msg: 'room required' })); return; }
                    currentRoom = rooms.get(msg.room);
                    if (!currentRoom || !currentRoom.host) {
                        ws.send(JSON.stringify({ type: 'error', msg: 'Room not found' }));
                        return;
                    }
                    currentRoom.viewers.add(ws);
                    ws.send(JSON.stringify({ type: 'viewing', room: msg.room }));
                    console.log(`[RELAY] Viewer joined room ${msg.room} (${currentRoom.viewers.size} viewers)`);
                    break;
                }
                case 'query': {
                    const activeRooms = [];
                    for (const [id, room] of rooms) {
                        if (room.host) activeRooms.push({ id, viewers: room.viewers.size });
                    }
                    ws.send(JSON.stringify({ type: 'rooms', rooms: activeRooms }));
                    break;
                }
                case 'announce': {
                    // Forward announcement to all connected peers
                    for (const [id, room] of rooms) {
                        if (room.host && room.host !== ws) {
                            room.host.send(JSON.stringify({ type: 'peer_announce', from: msg.from, room: msg.room }));
                        }
                    }
                    break;
                }
            }
        });

        ws.on('close', () => {
            if (isHost && currentRoom) {
                for (const viewer of currentRoom.viewers) {
                    viewer.send(JSON.stringify({ type: 'gone' }));
                }
                rooms.delete(getRoomId(currentRoom));
            } else if (currentRoom) {
                currentRoom.viewers.delete(ws);
            }
        });
    });

    console.log(`[RELAY] Servidor rodando na porta ${RELAY_PORT}`);
}

function getRoomId(room) {
    for (const [id, r] of rooms) { if (r === room) return id; }
    return null;
}

function broadcastAnnounce(roomId) {
    const onion = getOnionAddress();
    if (!onion) return;

    const announce = JSON.stringify({
        type: 'stream_announce',
        onion,
        room: roomId,
        name: identity.name,
        timestamp: Date.now()
    });

    for (const peer of peers) {
        connectToPeer(peer.onion).then(ws => {
            ws.send(announce);
            ws.close();
        }).catch(() => {});
    }
}

// ==================== PEER CONNECTION ====================

async function connectToPeer(onion) {
    const socket = await connectViaSocks(onion, RELAY_PORT);
    return new WebSocket({ socket });
}

async function peerListener() {
    if (!getOnionAddress()) {
        console.log('[PEER] Aguardando Tor Hidden Service...');
        await sleep(5000);
    }

    const onion = getOnionAddress();
    if (!onion) {
        console.error('[PEER] Nao foi possivel obter endereco onion');
        return;
    }

    console.log(`[PEER] Meu endereco: ${onion}`);

    // Listen for incoming peer connections
    const server = net.createServer((socket) => {
        // Handle peer connections
        let buffer = Buffer.alloc(0);
        socket.on('data', (data) => {
            buffer = Buffer.concat([buffer, data]);
            const str = buffer.toString();
            if (str.includes('\n')) {
                try {
                    const msg = JSON.parse(str.split('\n')[0]);
                    handlePeerMessage(msg, socket);
                } catch {}
                buffer = Buffer.alloc(0);
            }
        });
    });

    server.listen(LISTEN_PORT, '127.0.0.1', () => {
        console.log(`[PEER] Listener na porta ${LISTEN_PORT}`);
    });
}

function handlePeerMessage(msg, socket) {
    switch (msg.type) {
        case 'peer_announce':
            console.log(`[PEER] Stream announced: ${msg.name} @ ${msg.onion.substring(0, 20)}...`);
            updatePeerSeen(msg.onion);
            // Forward to other peers
            for (const peer of peers) {
                if (peer.onion !== msg.from) {
                    connectToPeer(peer.onion).then(ws => {
                        ws.send(JSON.stringify({ ...msg, from: getOnionAddress() }));
                        ws.close();
                    }).catch(() => {});
                }
            }
            break;
        case 'ping':
            socket.write(JSON.stringify({ type: 'pong', name: identity.name, onion: getOnionAddress() }) + '\n');
            break;
    }
}

// ==================== SCREEN CAPTURE ====================

function captureFrame() {
    try {
        const tmpFile = '/tmp/sr_capture.webp';
        execSync(`grim -t webp -q 50 "${tmpFile}" 2>/dev/null`, { timeout: 3000 });
        if (!fs.existsSync(tmpFile)) return null;
        const buf = fs.readFileSync(tmpFile);
        if (buf.length < 100) return null;

        let width = 1920, height = 1080;
        try {
            const wh = buf.readUInt16LE(26);
            width = wh & 0x3FFF;
            height = buf.readUInt16LE(28) & 0x3FFF;
        } catch {}

        const header = Buffer.alloc(13);
        header.write('SRF1', 0);
        header.writeUInt8(1, 4);
        header.writeUInt16LE(width, 5);
        header.writeUInt16LE(height, 7);
        header.writeUInt32LE(Date.now(), 9);

        return Buffer.concat([header, buf]);
    } catch {
        return null;
    }
}

function sendFrame(packet) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(packet);
        frameCount++;
        if (frameCount % 30 === 0) console.log(`[CAPTURE] ${frameCount} frames enviados`);
    }
}

// ==================== MAIN ====================

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
    const args = process.argv.slice(2);
    const mode = args[0] || 'host';

    console.log('========================================');
    console.log('    StreamRelay Decentralized Network');
    console.log('========================================');
    console.log('');

    // Setup
    fs.mkdirSync(DATA_DIR, { recursive: true });
    loadOrCreateIdentity();
    loadPeers();
    ensureTor();
    createRelayServer();
    peerListener();

    const onion = getOnionAddress();
    console.log('');
    console.log('========================================');
    console.log(`  MEU ENDERECO ONION:`);
    console.log(`  ${onion}`);
    console.log('');
    console.log(`  Compartilhe com amigos para`);
    console.log(`  eles assistirem sua transmissao!`);
    console.log('========================================');
    console.log('');

    if (mode === 'host') {
        // Host mode - capture and stream
        console.log('[MODE] HOST - Capturando tela...');
        console.log('[FPS] Pressione Ctrl+C para parar');

        await connectToRelay();

        running = true;
        setInterval(() => {
            if (!running) return;
            const packet = captureFrame();
            if (packet) sendFrame(packet);
        }, 1000 / FPS);

    } else if (mode === 'view') {
        // View mode - connect to a streamer
        const targetOnion = args[1];
        if (!targetOnion) {
            console.error('[MODE] Uso: node network-helper.js view <onion-do-streamer>');
            process.exit(1);
        }

        console.log(`[MODE] VIEW - Conectando a ${targetOnion}...`);
        await connectToStream(targetOnion);

    } else if (mode === 'addpeer') {
        // Add a peer
        const peerOnion = args[1];
        const peerName = args[2] || 'Friend';
        if (!peerOnion) {
            console.error('[MODE] Uso: node network-helper.js addpeer <onion> [nome]');
            process.exit(1);
        }
        addPeer(peerOnion, peerName);
        console.log(`[PEER] Amigo adicionado: ${peerName}`);

    } else if (mode === 'listpeers') {
        // List peers
        console.log('[PEERS] Amigos na rede:');
        for (const peer of peers) {
            console.log(`  - ${peer.name}: ${peer.onion.substring(0, 30)}...`);
        }

    } else if (mode === 'liststreams') {
        // List available streams
        console.log('[STREAMS] Buscando transmissoes...');
        const rooms = await queryStreams();
        if (rooms.length === 0) {
            console.log('  Nenhuma transmissao encontrada');
        } else {
            for (const room of rooms) {
                console.log(`  - Sala: ${room.id} (${room.viewers} viewers)`);
            }
        }
    }

    process.on('SIGINT', () => {
        console.log(`\n[STOP] ${frameCount} frames enviados`);
        running = false;
        if (ws) ws.close();
        process.exit(0);
    });
}

async function connectToRelay() {
    try {
        ws = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
        await new Promise((resolve) => ws.on('open', resolve));
        ws.send(JSON.stringify({ type: 'host' }));
        ws.on('message', (data) => {
            if (typeof data === 'string') {
                const msg = JSON.parse(data);
                if (msg.type === 'room') console.log(`[RELAY] Sala criada: ${msg.id}`);
            }
        });
        console.log('[RELAY] Conectado ao relay local');
    } catch (e) {
        console.error('[RELAY] Erro:', e.message);
    }
}

async function connectToStream(targetOnion) {
    try {
        const socket = await connectViaSocks(targetOnion, RELAY_PORT);
        ws = new WebSocket({ socket });

        ws.on('open', () => {
            console.log('[STREAM] Conectado! Aguardando frames...');
            ws.send(JSON.stringify({ type: 'view', room: 'default' }));
        });

        ws.on('message', (data) => {
            if (typeof data === 'string') {
                const msg = JSON.parse(data);
                console.log('[STREAM]', msg);
            } else {
                // Binary frame - save and display
                fs.writeFileSync('/tmp/sr_viewer_frame.webp', data);
                frameCount++;
                if (frameCount % 30 === 0) console.log(`[STREAM] ${frameCount} frames recebidos`);
            }
        });

        ws.on('close', () => console.log('[STREAM] Desconectado'));
    } catch (e) {
        console.error('[STREAM] Erro:', e.message);
    }
}

async function queryStreams() {
    // Query all known peers for streams
    const results = [];
    for (const peer of peers) {
        try {
            const socket = await connectViaSocks(peer.onion, RELAY_PORT);
            const pws = new WebSocket({ socket });
            await new Promise((resolve) => pws.on('open', resolve));

            pws.send(JSON.stringify({ type: 'query' }));
            const response = await new Promise((resolve) => {
                pws.on('message', (data) => {
                    resolve(JSON.parse(data));
                    pws.close();
                });
                setTimeout(() => resolve({ rooms: [] }), 5000);
            });

            if (response.rooms) {
                results.push(...response.rooms.map(r => ({ ...r, peer: peer.name })));
            }
        } catch {}
    }
    return results;
}

main();
