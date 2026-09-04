/*
 * Vencord, a Discord client mod
 * Copyright (c) 2024 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { Devs } from "@utils/constants";
import {
    ApplicationCommandInputType,
    ApplicationCommandOptionType,
    sendBotMessage,
} from "@api/Commands";
import { showToast, Toasts } from "@webpack/common";

const PLUGIN_KEY = "StreamRelay";

const settings = definePluginSettings({
    onionAddress: {
        type: OptionType.STRING,
        description: "Endereco .onion do servidor relay",
        default: "m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion",
    },
    onionPort: {
        type: OptionType.NUMBER,
        description: "Porta do servidor relay",
        default: 8080,
    },
    autoRelay: {
        type: OptionType.BOOLEAN,
        description: "Interceptar screen share do Discord automaticamente",
        default: true,
    },
});

let ws = null;
let stream = null;
let sendInterval = null;
let overlayEl = null;
let pickerModal = null;
let popupObserver = null;
let popupCSSInjected = false;
let originalGetDisplayMedia = null;

const FRAME_RATE = 15;
const QUALITY = 0.6;

const HIDE_POPUP_CSS = `
/* Hide Discord's screen share restriction popup */
[class*="modal"]:has([class*="error"]):not(:has([class*="picker"])),
[class*="modal"]:has([class*="not available"]):not(:has([class*="picker"])),
[class*="modal"]:has([class*="indisponivel"]):not(:has([class*="picker"])),
[class*="modal"]:has([class*="restri"]):not(:has([class*="picker"])),
[class*="modal"]:has([class*="restriction"]),
[class*="modal"]:has([class*="blocked"]),
[class*="notice"]:has([class*="error"]),
[class*="notice"]:has([class*="restricted"]),
[class*="banner"]:has([class*="error"]),
[class*="banner"]:has([class*="warning"]),
[role="dialog"]:has([class*="error"]):not(:has([class*="picker"])),
[aria-label*="Screen Share"][class*="error"],
[aria-label*="Compartilhar"][class*="error"],
`;

function injectPopupBlockerCSS() {
    if (popupCSSInjected) return;
    const style = document.createElement("style");
    style.id = "stream-relay-popup-blocker";
    style.textContent = HIDE_POPUP_CSS;
    document.head.appendChild(style);
    popupCSSInjected = true;
}

function removePopupBlockerCSS() {
    const style = document.getElementById("stream-relay-popup-blocker");
    if (style) style.remove();
    popupCSSInjected = false;
}

function startPopupObserver() {
    if (popupObserver) return;
    popupObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.nodeType !== 1) continue;
                const isDialog = node.matches?.('[role="dialog"]') || node.matches?.('[class*="modal"]');
                if (!isDialog) continue;
                const text = node.textContent?.toLowerCase() || "";
                const isRestriction =
                    text.includes("not available") ||
                    text.includes("indisponivel") ||
                    text.includes("restri") ||
                    text.includes("restriction") ||
                    text.includes("blocked") ||
                    text.includes("bloqueado") ||
                    text.includes("nao e possivel") ||
                    text.includes("this feature is not") ||
                    text.includes("esta funcionalidade nao") ||
                    text.includes("your region") ||
                    text.includes("sua regiao");
                const isScreenPicker =
                    node.querySelector?.('[class*="picker"]') ||
                    node.querySelector?.('[class*="selector"]') ||
                    node.querySelector?.('[class*="source"]') ||
                    text.includes("choose") ||
                    text.includes("escolher") ||
                    text.includes("select a") ||
                    text.includes("selecione");
                if (isRestriction && !isScreenPicker) {
                    console.log("[StreamRelay] Removing restriction popup");
                    node.remove();
                }
            }
        }
    });
    popupObserver.observe(document.body, { childList: true, subtree: true });
}

function stopPopupObserver() {
    if (popupObserver) { popupObserver.disconnect(); popupObserver = null; }
}

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
    stopBtn.onclick = () => { if (ws) ws.send(JSON.stringify({ type: "bye" })); cleanup(); };
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
    if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
    if (ws) { try { ws.close(); } catch {} ws = null; }
    removeOverlay();
    removePickerModal();
}

function removePickerModal() {
    if (pickerModal) { pickerModal.remove(); pickerModal = null; }
}

function connectWS(onionAddr, onionPort, mode, room) {
    return new Promise((resolve, reject) => {
        const url = `ws://127.0.0.1:6789`;
        ws = new WebSocket(url);
        const timeout = setTimeout(() => { ws.close(); reject(new Error("Connection timeout")); }, 15000);
        ws.onopen = () => { clearTimeout(timeout); ws.send(JSON.stringify({ type: mode, room: room || undefined })); };
        ws.onmessage = (event) => {
            if (typeof event.data === "string") {
                const msg = JSON.parse(event.data);
                if (msg.type === "room") resolve(msg.id);
                else if (msg.type === "error") reject(new Error(msg.msg));
                else if (msg.type === "gone") { showToast("Host disconnected", Toasts.Type.FAILURE); cleanup(); }
                else if (msg.type === "viewing") showToast(`Connected to room ${msg.room}`, Toasts.Type.SUCCESS);
            } else {
                handleFrame(event.data);
            }
        };
        ws.onerror = (err) => { clearTimeout(timeout); reject(err); };
        ws.onclose = () => { clearTimeout(timeout); };
    });
}

function handleFrame(data) {
    if (!overlayEl) return;
    const canvas = document.getElementById("stream-relay-canvas");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    const blob = new Blob([data], { type: "image/webp" });
    createImageBitmap(blob).then((bmp) => { canvas.width = bmp.width; canvas.height = bmp.height; ctx.drawImage(bmp, 0, 0); }).catch(() => {});
}

function startStreaming(mediaStream) {
    stream = mediaStream;
    const onionAddr = settings.store.onionAddress;
    const onionPort = settings.store.onionPort;

    showToast("Conectando ao relay...", Toasts.Type.INFO);

    connectWS(onionAddr, onionPort, "host", null).then((roomId) => {
        createOverlay(roomId);
        showToast(`Hostando sala: ${roomId}`, Toasts.Type.SUCCESS);

        const videoTrack = stream.getVideoTracks()[0];
        const canvas = document.createElement("canvas");
        const ctx = canvas.getContext("2d");

        sendInterval = setInterval(() => {
            if (!videoTrack || videoTrack.readyState !== "live") { cleanup(); return; }
            const settings2 = videoTrack.getSettings();
            canvas.width = settings2.width || 1280;
            canvas.height = settings2.height || 720;
            ctx.drawImage(videoTrack, 0, 0, canvas.width, canvas.height);
            canvas.toBlob((blob) => {
                if (blob && ws && ws.readyState === WebSocket.OPEN) {
                    blob.arrayBuffer().then((buf) => {
                        const header = new ArrayBuffer(13);
                        const view = new DataView(header);
                        view.setUint8(0, 0x53); view.setUint8(1, 0x52); view.setUint8(2, 0x46); view.setUint8(3, 0x31);
                        view.setUint8(4, 1); view.setUint16(5, canvas.width, true); view.setUint16(7, canvas.height, true); view.setUint32(9, Date.now(), true);
                        const packet = new Uint8Array(13 + buf.byteLength);
                        packet.set(new Uint8Array(header), 0); packet.set(new Uint8Array(buf), 13);
                        ws.send(packet);
                    });
                }
            }, "image/webp", QUALITY);
        }, 1000 / FRAME_RATE);

        videoTrack.onended = () => { cleanup(); showToast("Transmissao encerrada", Toasts.Type.FAILURE); };
    }).catch((err) => {
        cleanup();
        showToast(`Erro: ${err.message}`, Toasts.Type.FAILURE);
    });
}

function openCustomPicker(options) {
    return new Promise((resolve, reject) => {
        removePickerModal();

        pickerModal = document.createElement("div");
        pickerModal.id = "stream-relay-picker";
        pickerModal.style.cssText = `
            position: fixed; top: 0; left: 0; right: 0; bottom: 0;
            background: rgba(0,0,0,0.85); z-index: 999999;
            display: flex; align-items: center; justify-content: center;
            font-family: 'gg sans', 'Noto Sans', 'Helvetica Neue', Helvetica, Arial, sans-serif;
        `;

        const onionAddr = settings.store.onionAddress;
        const onionPort = settings.store.onionPort;

        const modal = document.createElement("div");
        modal.style.cssText = `
            background: #2b2d31; border-radius: 12px; padding: 24px;
            width: 520px; max-width: 90vw; box-shadow: 0 8px 32px rgba(0,0,0,0.5); color: #dbdee1;
        `;

        modal.innerHTML = `
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:20px;">
                <div style="width:40px;height:40px;background:#5865f2;border-radius:50%;display:flex;align-items:center;justify-content:center;">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="white">
                        <rect x="2" y="3" width="20" height="14" rx="2" stroke="white" fill="none" stroke-width="2"/>
                        <path d="M8 21h8M12 17v4" stroke="white" stroke-width="2" stroke-linecap="round"/>
                    </svg>
                </div>
                <div>
                    <div style="font-size:20px;font-weight:600;color:#f2f3f5;">StreamRelay</div>
                    <div style="font-size:14px;color:#b5bac1;">Transmissao via servidor privado</div>
                </div>
            </div>

            <div style="background:#1e1f22;border-radius:8px;padding:16px;margin-bottom:12px;">
                <div style="font-size:12px;color:#b5bac1;margin-bottom:10px;">Servidor:</div>
                <div style="background:#111214;border-radius:6px;padding:8px 12px;font-family:monospace;font-size:13px;color:#dbdee1;word-break:break-all;">
                    ${onionAddr}:${onionPort}
                </div>
            </div>

            <div style="background:#1e1f22;border-radius:8px;padding:16px;margin-bottom:16px;">
                <div style="font-size:14px;color:#b5bac1;margin-bottom:10px;">Selecione a captura:</div>
                <div style="display:flex;flex-direction:column;gap:8px;">
                    <button id="srr-btn-screen" style="
                        background:#5865f2; border:none; color:white; padding:12px 16px;
                        border-radius:8px; cursor:pointer; font-size:14px; text-align:left;
                        display:flex; align-items:center; gap:10px; transition: background 0.2s;
                    ">
                        <svg width="20" height="20" viewBox="0 0 24 24" fill="white"><rect x="2" y="3" width="20" height="14" rx="2" stroke="white" fill="none" stroke-width="2"/><path d="M8 21h8M12 17v4" stroke="white" stroke-width="2" stroke-linecap="round"/></svg>
                        Toda a tela
                    </button>
                    <button id="srr-btn-window" style="
                        background:#383a40; border:none; color:white; padding:12px 16px;
                        border-radius:8px; cursor:pointer; font-size:14px; text-align:left;
                        display:flex; align-items:center; gap:10px; transition: background 0.2s;
                    ">
                        <svg width="20" height="20" viewBox="0 0 24 24" fill="white"><rect x="3" y="3" width="18" height="18" rx="2" stroke="white" fill="none" stroke-width="2"/><path d="M3 9h18" stroke="white" stroke-width="2"/></svg>
                        Janela especifica
                    </button>
                </div>
            </div>

            <div style="display:flex;gap:12px;justify-content:flex-end;">
                <button id="srr-btn-cancel" style="
                    background:transparent; border:1px solid #4e5058; color:#dbdee1;
                    padding:8px 16px; border-radius:8px; cursor:pointer; font-size:14px;
                ">Cancelar</button>
            </div>
        `;

        pickerModal.appendChild(modal);
        document.body.appendChild(pickerModal);

        const btnScreen = modal.querySelector("#srr-btn-screen");
        const btnWindow = modal.querySelector("#srr-btn-window");
        const btnCancel = modal.querySelector("#srr-btn-cancel");

        btnScreen.onmouseenter = () => btnScreen.style.background = "#4752c4";
        btnScreen.onmouseleave = () => btnScreen.style.background = "#5865f2";
        btnWindow.onmouseenter = () => btnWindow.style.background = "#4e5058";
        btnWindow.onmouseleave = () => btnWindow.style.background = "#383a40";

        btnScreen.onclick = async () => {
            removePickerModal();
            try {
                const originalGDM = originalGetDisplayMedia || navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
                const s = await originalGDM({ video: { displaySurface: "monitor" }, audio: false });
                resolve(s);
            } catch (e) { reject(e); }
        };

        btnWindow.onclick = async () => {
            removePickerModal();
            try {
                const originalGDM = originalGetDisplayMedia || navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
                const s = await originalGDM({ video: { displaySurface: "window" }, audio: false });
                resolve(s);
            } catch (e) { reject(e); }
        };

        btnCancel.onclick = () => { removePickerModal(); reject(new Error("Cancelled")); };
        pickerModal.onclick = (e) => { if (e.target === pickerModal) { removePickerModal(); reject(new Error("Cancelled")); } };
    });
}

function interceptedGetDisplayMedia(options) {
    if (settings.store.autoRelay) {
        return openCustomPicker(options).then((mediaStream) => {
            startStreaming(mediaStream);
            return mediaStream;
        });
    }
    if (originalGetDisplayMedia) {
        return originalGetDisplayMedia.call(navigator.mediaDevices, options);
    }
    // Fallback if no original
    throw new Error("getDisplayMedia not available");
}

function startView(onionAddr, onionPort, room) {
    if (!room) { showToast("Room ID is required", Toasts.Type.FAILURE); return; }
    showToast("Connecting to relay...", Toasts.Type.INFO);
    connectWS(onionAddr, onionPort, "view", room).then(() => {
        createOverlay(room);
        showToast("Viewing stream", Toasts.Type.SUCCESS);
    }).catch((err) => {
        showToast(`Error: ${err.message}`, Toasts.Type.FAILURE);
    });
}

export default definePlugin({
    name: PLUGIN_KEY,
    description: "Private screen sharing via Tor hidden service - substitui o botao padrao do Discord",
    authors: [Devs.Ven],
    settings,

    start() {
        injectPopupBlockerCSS();
        startPopupObserver();

        // Intercept screen share regardless of autoRelay setting
        if (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
            originalGetDisplayMedia = navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
            navigator.mediaDevices.getDisplayMedia = interceptedGetDisplayMedia;
            console.log("[StreamRelay] Screen share interceptado - usando servidor relay");
        } else {
            console.warn("[StreamRelay] getDisplayMedia nao disponivel");
            // Try to polyfill getDisplayMedia
            navigator.mediaDevices.getDisplayMedia = async (options) => {
                showToast("Captura de tela indisponivel. Execute: flatpak override --user --socket=x11 --socket=wayland --device=dri com.discordapp.Discord", Toasts.Type.FAILURE);
                throw new Error("getDisplayMedia not supported - Flatpak permissions needed");
            };
        }
    },

    stop() {
        cleanup();
        removePopupBlockerCSS();
        stopPopupObserver();
        if (originalGetDisplayMedia) {
            navigator.mediaDevices.getDisplayMedia = originalGetDisplayMedia;
            originalGetDisplayMedia = null;
        }
    },

    commands: [
        {
            name: "streamhost",
            description: "Iniciar transmissao via relay",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                {
                    name: "room",
                    description: "Room ID (auto-gerado se vazio)",
                    type: ApplicationCommandOptionType.STRING,
                    required: false,
                },
            ],
            async execute(args, ctx) {
                const room = args.room?.value || null;
                cleanup();
                try {
                    const originalGDM = originalGetDisplayMedia || navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
                    const s = await originalGDM({ video: true, audio: false });
                    startStreaming(s);
                    sendBotMessage(ctx.channel.id, { content: "Iniciando transmissao via StreamRelay" });
                } catch (e) {
                    console.error("[StreamRelay] Capture error:", e);
                    sendBotMessage(ctx.channel.id, { content: `Erro ao capturar tela: ${e.message}. Se estiver no Flatpak, rode: flatpak override --user --socket=session-bus com.discordapp.Discord` });
                }
            },
        },
        {
            name: "streamview",
            description: "Assistir transmissao via relay",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                {
                    name: "room",
                    description: "Room ID para entrar",
                    type: ApplicationCommandOptionType.STRING,
                    required: true,
                },
            ],
            async execute(args, ctx) {
                const room = args.room.value;
                cleanup();
                startView(settings.store.onionAddress, settings.store.onionPort, room);
                sendBotMessage(ctx.channel.id, { content: `Conectando a sala ${room}` });
            },
        },
        {
            name: "streamstop",
            description: "Parar transmissao",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [],
            async execute(args, ctx) {
                cleanup();
                sendBotMessage(ctx.channel.id, { content: "Transmissao encerrada" });
            },
        },
    ],
});
