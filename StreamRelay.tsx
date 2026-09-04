import { definePlugin } from "@utils/types";
import { Devs } from "@utils/constants";
import { ApplicationCommandInputType, ApplicationCommandOptionType, sendBotMessage } from "@api/Commands";
import { DataStore } from "@api/DataStore";
import { showToast, Toasts } from "@api/Toast";
import { findByProps } from "@webpack";
import { React, FluxDispatcher } from "@webpack/common";

const PLUGIN_KEY = "StreamRelay";

let ws = null;
let stream = null;
let sendInterval = null;
let overlayEl = null;

const FRAME_RATE = 15;
const QUALITY = 0.6;

function createOverlay(roomId) {
  removeOverlay();
  overlayEl = document.createElement("div");
  overlayEl.id = "stream-relay-overlay";
  overlayEl.style.cssText = `
    position: fixed; top: 20px; right: 20px; z-index: 99999;
    width: 400px; height: 300px; background: #000; border: 2px solid #5865f2;
    border-radius: 8px; overflow: hidden; box-shadow: 0 4px 20px rgba(0,0,0,0.5);
  `;

  const header = document.createElement("div");
  header.style.cssText = `
    display: flex; justify-content: space-between; align-items: center;
    padding: 4px 8px; background: #5865f2; color: white; font-size: 12px;
  `;
  header.innerHTML = `<span>StreamRelay - ${roomId}</span>`;

  const stopBtn = document.createElement("button");
  stopBtn.textContent = "Stop";
  stopBtn.style.cssText = "background:#ed4245;border:none;color:white;padding:2px 8px;border-radius:4px;cursor:pointer;font-size:11px;";
  stopBtn.onclick = () => {
    if (ws) ws.send(JSON.stringify({ type: "bye" }));
    cleanup();
  };
  header.appendChild(stopBtn);
  overlayEl.appendChild(header);

  const canvas = document.createElement("canvas");
  canvas.id = "stream-relay-canvas";
  canvas.style.cssText = "width:100%;height:calc(100% - 24px);display:block;";
  overlayEl.appendChild(canvas);

  document.body.appendChild(overlayEl);
}

function removeOverlay() {
  const el = document.getElementById("stream-relay-overlay");
  if (el) el.remove();
  overlayEl = null;
}

function cleanup() {
  if (sendInterval) clearInterval(sendInterval);
  sendInterval = null;
  if (stream) {
    stream.getTracks().forEach((t) => t.stop());
    stream = null;
  }
  if (ws) {
    try { ws.close(); } catch {}
    ws = null;
  }
  removeOverlay();
}

function connectWS(onionAddr, onionPort, mode, room) {
  return new Promise((resolve, reject) => {
    const url = `ws://127.0.0.1:6789`;
    ws = new WebSocket(url);

    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error("Connection timeout"));
    }, 15000);

    ws.onopen = () => {
      clearTimeout(timeout);
      ws.send(JSON.stringify({ type: mode, room: room || undefined }));
    };

    ws.onmessage = (event) => {
      if (typeof event.data === "string") {
        const msg = JSON.parse(event.data);
        if (msg.type === "room") {
          resolve(msg.id);
        } else if (msg.type === "error") {
          reject(new Error(msg.msg));
        } else if (msg.type === "gone") {
          showToast("Host disconnected", Toasts.Type.FAILURE);
          cleanup();
        } else if (msg.type === "viewing") {
          showToast(`Connected to room ${msg.room}`, Toasts.Type.SUCCESS);
        }
      } else {
        // Binary frame data
        handleFrame(event.data);
      }
    };

    ws.onerror = (err) => {
      clearTimeout(timeout);
      reject(err);
    };

    ws.onclose = () => {
      clearTimeout(timeout);
    };
  });
}

function handleFrame(data) {
  if (!overlayEl) return;
  const canvas = document.getElementById("stream-relay-canvas");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");

  const blob = new Blob([data], { type: "image/webp" });
  createImageBitmap(blob).then((bmp) => {
    canvas.width = bmp.width;
    canvas.height = bmp.height;
    ctx.drawImage(bmp, 0, 0);
  }).catch(() => {});
}

async function startHost(onionAddr, onionPort, room) {
  try {
    stream = await navigator.mediaDevices.getDisplayMedia({
      video: { cursor: "always" },
      audio: false,
    });
  } catch {
    showToast("Screen capture cancelled", Toasts.Type.FAILURE);
    return;
  }

  showToast("Connecting to relay...", Toasts.Type.INFO);

  try {
    const roomId = await connectWS(onionAddr, onionPort, "host", room);
    createOverlay(roomId);
    showToast(`Hosting room: ${roomId}`, Toasts.Type.SUCCESS);

    const videoTrack = stream.getVideoTracks()[0];
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d");

    sendInterval = setInterval(() => {
      if (!videoTrack || videoTrack.readyState !== "live") {
        cleanup();
        return;
      }
      const settings = videoTrack.getSettings();
      canvas.width = settings.width || 1280;
      canvas.height = settings.height || 720;
      ctx.drawImage(videoTrack, 0, 0, canvas.width, canvas.height);

      canvas.toBlob((blob) => {
        if (blob && ws && ws.readyState === WebSocket.OPEN) {
          blob.arrayBuffer().then((buf) => {
            const header = new ArrayBuffer(13);
            const view = new DataView(header);
            // Magic "SRF1"
            view.setUint8(0, 0x53);
            view.setUint8(1, 0x52);
            view.setUint8(2, 0x46);
            view.setUint8(3, 0x31);
            view.setUint8(4, 1); // webp
            view.setUint16(5, canvas.width, true);
            view.setUint16(7, canvas.height, true);
            view.setUint32(9, Date.now(), true);

            const packet = new Uint8Array(13 + buf.byteLength);
            packet.set(new Uint8Array(header), 0);
            packet.set(new Uint8Array(buf), 13);
            ws.send(packet);
          });
        }
      }, "image/webp", QUALITY);
    }, 1000 / FRAME_RATE);

    videoTrack.onended = () => {
      cleanup();
      showToast("Stream ended", Toasts.Type.FAILURE);
    };
  } catch (err) {
    cleanup();
    showToast(`Error: ${err.message}`, Toasts.Type.FAILURE);
  }
}

async function startView(onionAddr, onionPort, room) {
  if (!room) {
    showToast("Room ID is required", Toasts.Type.FAILURE);
    return;
  }

  showToast("Connecting to relay...", Toasts.Type.INFO);

  try {
    await connectWS(onionAddr, onionPort, "view", room);
    createOverlay(room);
    showToast("Viewing stream", Toasts.Type.SUCCESS);
  } catch (err) {
    showToast(`Error: ${err.message}`, Toasts.Type.FAILURE);
  }
}

export default definePlugin({
  name: PLUGIN_KEY,
  description: "Private screen sharing via Tor hidden service",
  authors: [Devs.Ven],

  commands: [
    {
      name: "streamhost",
      description: "Host screen share via relay",
      inputType: ApplicationCommandInputType.BUILT_IN,
      options: [
        {
          name: "onion",
          description: "Onion address (e.g. abc.onion)",
          type: ApplicationCommandOptionType.STRING,
          required: true,
        },
        {
          name: "port",
          description: "Onion port (default: 8080)",
          type: ApplicationCommandOptionType.NUMBER,
          required: false,
        },
        {
          name: "room",
          description: "Room ID (auto-generated if empty)",
          type: ApplicationCommandOptionType.STRING,
          required: false,
        },
      ],
      async execute(args, ctx) {
        const onion = args.onion.value;
        const port = args.port?.value || 8080;
        const room = args.room?.value || null;
        cleanup();
        startHost(onion, port, room);
        sendBotMessage(ctx.channel.id, `Starting relay host to ${onion}:${port}`);
      },
    },
    {
      name: "streamview",
      description: "View screen share from relay",
      inputType: ApplicationCommandInputType.BUILT_IN,
      options: [
        {
          name: "onion",
          description: "Onion address (e.g. abc.onion)",
          type: ApplicationCommandOptionType.STRING,
          required: true,
        },
        {
          name: "port",
          description: "Onion port (default: 8080)",
          type: ApplicationCommandOptionType.NUMBER,
          required: false,
        },
        {
          name: "room",
          description: "Room ID to join",
          type: ApplicationCommandOptionType.STRING,
          required: true,
        },
      ],
      async execute(args, ctx) {
        const onion = args.onion.value;
        const port = args.port?.value || 8080;
        const room = args.room.value;
        cleanup();
        startView(onion, port, room);
        sendBotMessage(ctx.channel.id, `Connecting to room ${room} on ${onion}:${port}`);
      },
    },
    {
      name: "streamstop",
      description: "Stop current stream or viewer",
      inputType: ApplicationCommandInputType.BUILT_IN,
      options: [],
      async execute(args, ctx) {
        cleanup();
        sendBotMessage(ctx.channel.id, "Stream stopped");
      },
    },
  ],

  start() {},
  stop() {
    cleanup();
  },
});
