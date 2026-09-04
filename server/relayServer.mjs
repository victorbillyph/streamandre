import { WebSocketServer } from 'ws';
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';

const PORT = parseInt(process.env.PORT || '8080');
const TOR_ONION_FILE = join(process.env.TOR_DATA_DIR || './tor-data', 'hostname');

const wss = new WebSocketServer({ port: PORT });

const rooms = new Map(); // roomId -> { host: ws, viewers: Set<ws>, seq: 0 }

function getRoomId() {
  return Math.random().toString(36).substring(2, 8);
}

function send(ws, data) {
  if (ws.readyState === 1) ws.send(data);
}

function broadcast(room) {
  for (const viewer of room.viewers) {
    send(viewer, room.lastFrame);
  }
}

wss.on('connection', (ws) => {
  let currentRoom = null;
  let isHost = false;

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      // Frame data from host
      if (isHost && currentRoom && currentRoom.host === ws) {
        currentRoom.lastFrame = data;
        broadcast(currentRoom);
      }
      return;
    }

    let msg;
    try { msg = JSON.parse(data); } catch { return; }

    switch (msg.type) {
      case 'host': {
        const roomId = msg.room || getRoomId();
        if (rooms.has(roomId)) {
          const existing = rooms.get(roomId);
          if (existing.host) {
            send(ws, JSON.stringify({ type: 'error', msg: 'Room already has a host' }));
            return;
          }
          existing.host = ws;
          isHost = true;
          currentRoom = existing;
        } else {
          currentRoom = { host: ws, viewers: new Set(), lastFrame: null, seq: 0 };
          rooms.set(roomId, currentRoom);
          isHost = true;
        }
        send(ws, JSON.stringify({ type: 'room', id: roomId }));
        console.log(`[HOST] Joined room ${roomId}`);
        break;
      }

      case 'view': {
        if (!msg.room) {
          send(ws, JSON.stringify({ type: 'error', msg: 'room is required' }));
          return;
        }
        currentRoom = rooms.get(msg.room);
        if (!currentRoom) {
          send(ws, JSON.stringify({ type: 'error', msg: 'Room not found' }));
          return;
        }
        if (!currentRoom.host) {
          send(ws, JSON.stringify({ type: 'error', msg: 'No host in room' }));
          return;
        }
        currentRoom.viewers.add(ws);
        send(ws, JSON.stringify({ type: 'viewing', room: msg.room }));
        send(ws, JSON.stringify({ type: 'status', msg: 'Host is streaming' }));
        console.log(`[VIEWER] Joined room ${msg.room} (${currentRoom.viewers.size} viewers)`);
        break;
      }

      case 'bye': {
        cleanup();
        break;
      }
    }
  });

  function cleanup() {
    if (isHost && currentRoom) {
      console.log(`[HOST] Left room, notifying viewers`);
      for (const viewer of currentRoom.viewers) {
        send(viewer, JSON.stringify({ type: 'gone' }));
      }
      rooms.delete(getRoomByHost(currentRoom));
    } else if (currentRoom) {
      currentRoom.viewers.delete(ws);
    }
  }

  function getRoomByHost(room) {
    for (const [id, r] of rooms) {
      if (r === room) return id;
    }
    return null;
  }

  ws.on('close', cleanup);
  ws.on('error', () => cleanup());
});

// Try to read onion address
let onionAddr = null;
if (existsSync(TOR_ONION_FILE)) {
  onionAddr = readFileSync(TOR_ONION_FILE, 'utf8').trim();
}

console.log(`StreamRelay Server started on port ${PORT}`);
console.log(`Onion address: ${onionAddr || 'Waiting for Tor... (set TOR_DATA_DIR to tor-data directory)'}`);

// Watch for onion file (in case tor starts later)
if (!onionAddr) {
  const checkInterval = setInterval(() => {
    if (existsSync(TOR_ONION_FILE)) {
      onionAddr = readFileSync(TOR_ONION_FILE, 'utf8').trim();
      console.log(`Onion address discovered: ${onionAddr}`);
      clearInterval(checkInterval);
    }
  }, 2000);
}
