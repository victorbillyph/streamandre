import { WebSocketServer, WebSocket } from 'ws';
import net from 'net';

const LOCAL_PORT = parseInt(process.env.BRIDGE_PORT || '6789');
const SOCKS_HOST = process.env.SOCKS_HOST || '127.0.0.1';
const SOCKS_PORT = parseInt(process.env.SOCKS_PORT || '9050');

const args = process.argv.slice(2);
const onionAddr = args[0] || process.env.ONION_ADDR;
const onionPort = parseInt(args[1] || process.env.ONION_PORT || '8080');

if (!onionAddr) {
  console.error('Usage: node bridge.mjs <onion-address> [onion-port]');
  console.error('Example: node bridge.mjs abc123xyz.onion 8080');
  process.exit(1);
}

console.log(`Bridge: ws://127.0.0.1:${LOCAL_PORT} -> tor -> ws://${onionAddr}:${onionPort}`);

function connectViaSocks(onionHost, onionPort) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKS_PORT, SOCKS_HOST, () => {
      // SOCKS5 handshake
      socket.write(Buffer.from([0x05, 0x01, 0x00]));
    });

    let step = 0;
    socket.on('data', (data) => {
      if (step === 0) {
        // SOCKS5 auth response
        if (data[0] !== 0x05) {
          socket.destroy();
          reject(new Error('SOCKS5 auth failed'));
          return;
        }
        step = 1;
        // SOCKS5 connect request
        const hostBuf = Buffer.from(onionHost);
        const buf = Buffer.alloc(7 + hostBuf.length);
        buf[0] = 0x05; // VER
        buf[1] = 0x01; // CMD: CONNECT
        buf[2] = 0x00; // RSV
        buf[3] = 0x03; // ATYP: DOMAIN
        buf[4] = hostBuf.length;
        hostBuf.copy(buf, 5);
        buf.writeUInt16BE(onionPort, 5 + hostBuf.length);
        socket.write(buf);
      } else if (step === 1) {
        // SOCKS5 connect response
        if (data[1] !== 0x00) {
          socket.destroy();
          reject(new Error(`SOCKS5 connect failed: ${data[1]}`));
          return;
        }
        resolve(socket);
      }
    });

    socket.on('error', reject);
    socket.setTimeout(30000, () => {
      socket.destroy();
      reject(new Error('SOCKS5 connect timeout'));
    });
  });
}

const wss = new WebSocketServer({ port: LOCAL_PORT });

wss.on('connection', async (clientWs) => {
  console.log('[BRIDGE] Client connected, establishing Tor tunnel...');

  try {
    const torSocket = await connectViaSocks(onionAddr, onionPort);
    const torWs = new WebSocket({ socket: torSocket });

    let torReady = false;

    torWs.on('open', () => {
      torReady = true;
      console.log('[BRIDGE] Tor tunnel established');
    });

    // Forward messages both ways
    clientWs.on('message', (data, isBinary) => {
      if (torReady && torWs.readyState === WebSocket.OPEN) {
        torWs.send(data, { binary: isBinary });
      }
    });

    torWs.on('message', (data, isBinary) => {
      if (clientWs.readyState === WebSocket.OPEN) {
        clientWs.send(data, { binary: isBinary });
      }
    });

    clientWs.on('close', () => {
      torWs.close();
    });

    torWs.on('close', () => {
      clientWs.close();
    });

    clientWs.on('error', () => torWs.close());
    torWs.on('error', () => clientWs.close());

  } catch (err) {
    console.error('[BRIDGE] Connection failed:', err.message);
    clientWs.close(1011, 'Tor connection failed');
  }
});

console.log(`Bridge ready on ws://127.0.0.1:${LOCAL_PORT}`);
console.log(`Make sure Tor is running on ${SOCKS_HOST}:${SOCKS_PORT}`);
