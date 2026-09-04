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
import { showToast, Toasts, Text, Button, Modal, openModal, closeModal, TextInput } from "@webpack/common";
import { Flex } from "@components/Flex";
import { Divider } from "@components/Divider";
import { React, useState, useEffect } from "@webpack/common";

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

let ws: WebSocket | null = null;
let stream: MediaStream | null = null;
let sendInterval: any = null;
let overlayEl: HTMLDivElement | null = null;
let pickerModal: HTMLDivElement | null = null;
let popupObserver: MutationObserver | null = null;
let popupCSSInjected = false;
let originalGetDisplayMedia: any = null;

const FRAME_RATE = 15;
const QUALITY = 0.6;

const HIDE_POPUP_CSS = `
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
    popupObserver = new MutationObserver(mutations => {
        for (const m of mutations) for (const node of m.addedNodes) {
            if ((node as Element).nodeType !== 1) continue;
            const el = node as Element;
            const isDialog = el.matches?.('[role="dialog"]') || el.matches?.('[class*="modal"]');
            if (!isDialog) continue;
            const text = el.textContent?.toLowerCase() || "";
            const isRestriction = text.includes("not available") || text.includes("indisponivel") || text.includes("restri") || text.includes("restriction") || text.includes("blocked") || text.includes("bloqueado") || text.includes("nao e possivel") || text.includes("this feature is not") || text.includes("your region") || text.includes("sua regiao");
            const isPicker = el.querySelector?.('[class*="picker"]') || text.includes("choose") || text.includes("escolher") || text.includes("select a") || text.includes("selecione");
            if (isRestriction && !isPicker) el.remove();
        }
    });
    popupObserver.observe(document.body, { childList: true, subtree: true });
}
function stopPopupObserver() { if (popupObserver) { popupObserver.disconnect(); popupObserver = null; } }

let overlayEls: HTMLDivElement[] = [];
let activeViewWS: WebSocket[] = [];

function createOverlay(roomId: string) {
    // compat: cria overlay unico
    createMonitorOverlays([roomId]);
}
function createMonitorOverlays(roomIds: string[]) {
    removeOverlay();
    const container = document.createElement("div");
    container.id = "stream-relay-overlay";
    container.style.cssText = `position:fixed;top:20px;right:20px;z-index:99999;display:flex;flex-direction:column;gap:8px;max-height:90vh;overflow:auto;`;
    overlayEl = container as any;
    overlayEls = [];
    roomIds.forEach((rid, idx) => {
        const wrap = document.createElement("div");
        wrap.style.cssText = `width:400px;height:300px;background:#000;border:2px solid #5865f2;border-radius:8px;overflow:hidden;box-shadow:0 4px 20px rgba(0,0,0,0.5);display:flex;flex-direction:column;`;
        const header = document.createElement("div");
        header.style.cssText = `display:flex;justify-content:space-between;align-items:center;padding:4px 8px;background:#5865f2;color:white;font-size:12px;`;
        const label = roomIds.length > 1 ? `Monitor ${idx + 1} - ${rid}` : `StreamRelay - ${rid}`;
        header.innerHTML = `<span>${label}</span>`;
        const btns = document.createElement("div"); btns.style.cssText = `display:flex;gap:4px;`;
        const fsBtn = document.createElement("button"); fsBtn.textContent = "⛶";
        fsBtn.title = "Fullscreen"; fsBtn.style.cssText = "background:#2b2d31;border:none;color:white;padding:2px 6px;border-radius:4px;cursor:pointer;font-size:11px;";
        fsBtn.onclick = () => { const cv = wrap.querySelector("canvas") as HTMLCanvasElement; if (cv) cv.requestFullscreen?.(); };
        const stopBtn = document.createElement("button"); stopBtn.textContent = "Stop";
        stopBtn.style.cssText = "background:#ed4245;border:none;color:white;padding:2px 8px;border-radius:4px;cursor:pointer;font-size:11px;";
        stopBtn.onclick = () => cleanup();
        btns.appendChild(fsBtn); btns.appendChild(stopBtn); header.appendChild(btns);
        wrap.appendChild(header);
        const canvas = document.createElement("canvas");
        canvas.id = `stream-relay-canvas-${idx}`;
        canvas.dataset.room = rid;
        canvas.style.cssText = "width:100%;flex:1;display:block;background:#000;cursor:pointer;";
        canvas.onclick = () => canvas.requestFullscreen?.();
        wrap.appendChild(canvas);
        container.appendChild(wrap);
        overlayEls.push(wrap);
    });
    document.body.appendChild(container);
}
function removeOverlay() {
    const el = document.getElementById("stream-relay-overlay");
    if (el) el.remove();
    overlayEl = null; overlayEls = [];
    activeViewWS.forEach(s => { try { s.close(); } catch {} });
    activeViewWS = [];
}
function removePickerModal() { if (pickerModal) { pickerModal.remove(); pickerModal = null; } }
function cleanup() {
    if (sendInterval) clearInterval(sendInterval);
    sendInterval = null;
    if (stream) { stream.getTracks().forEach(t => t.stop()); stream = null; }
    if (ws) { try { ws.close(); } catch {} ws = null; }
    activeViewWS.forEach(s => { try { s.close(); } catch {} });
    activeViewWS = [];
    removeOverlay(); removePickerModal();
}
function tryConnect(url: string, mode: string, room?: string | null): Promise<string> {
    return new Promise((resolve, reject) => {
        const s = new WebSocket(url);
        s.binaryType = "arraybuffer";
        ws = s;
        const timeout = setTimeout(() => { try { s.close(); } catch {} reject(new Error("timeout")); }, 4000);
        s.onopen = () => { clearTimeout(timeout); s.send(JSON.stringify({ type: mode, room: room || undefined })); };
        s.onmessage = (event: any) => {
            if (typeof event.data === "string") {
                const msg = JSON.parse(event.data);
                if (msg.type === "room") resolve(msg.id);
                else if (msg.type === "viewing") { clearTimeout(timeout); resolve(msg.room); }
                else if (msg.type === "error") { clearTimeout(timeout); reject(new Error(msg.msg)); }
                else if (msg.type === "gone") { showToast("Host desconectado", Toasts.Type.FAILURE); cleanup(); }
            } else handleFrame(event.data);
        };
        s.onerror = () => { clearTimeout(timeout); reject(new Error("ws error")); };
        s.onclose = () => clearTimeout(timeout);
    });
}
function connectWS(_onionAddr: string, _onionPort: number, mode: string, room?: string | null): Promise<string> {
    // viewer/host: tenta direto no relay local (sem Tor) primeiro; fallback via bridge Tor
    return tryConnect(`ws://127.0.0.1:8080`, mode, room).catch(() =>
        tryConnect(`ws://127.0.0.1:6789`, mode, room).catch(() => {
            throw new Error("Helper nao conectado (127.0.0.1:8080/6789). Rode streamrelay-start");
        })
    );
}
function handleFrame(data: ArrayBuffer, targetRoom?: string) {
    let canvas: HTMLCanvasElement | null = null;
    if (targetRoom) {
        canvas = document.querySelector(`canvas[data-room="${targetRoom}"]`) as HTMLCanvasElement;
    }
    if (!canvas) canvas = document.getElementById("stream-relay-canvas") as HTMLCanvasElement;
    if (!canvas) {
        // multi: usa primeiro canvas livre
        canvas = document.querySelector(`[id^="stream-relay-canvas-"]`) as HTMLCanvasElement;
        if (!canvas) return;
    }
    const ctx = canvas.getContext("2d")!;
    let buf = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data as any);
    if (buf.length > 13 && buf[0] === 0x53 && buf[1] === 0x52 && buf[2] === 0x46 && buf[3] === 0x31) buf = buf.slice(13);
    const blob = new Blob([buf], { type: "image/jpeg" });
    createImageBitmap(blob).then(bmp => { canvas!.width = bmp.width; canvas!.height = bmp.height; ctx.drawImage(bmp, 0, 0); }).catch(() => {});
}
function checkHelperStatus(): Promise<boolean> {
    const tryUrl = (url: string) => new Promise<boolean>(res => {
        const s = new WebSocket(url);
        let done = false;
        const t = setTimeout(() => { if (!done) { done = true; try { s.close(); } catch {} res(false); } }, 1200);
        s.onopen = () => { if (!done) { done = true; clearTimeout(t); s.close(); res(true); } };
        s.onerror = () => { if (!done) { done = true; clearTimeout(t); res(false); } };
    });
    return tryUrl("ws://127.0.0.1:8080").then(ok => ok ? true : tryUrl("ws://127.0.0.1:6789"));
}
function startStreaming(mediaStream: MediaStream) {
    stream = mediaStream;
    const onionAddr = settings.store.onionAddress;
    const onionPort = settings.store.onionPort;
    showToast("Conectando ao relay...", Toasts.Type.INFO);
    connectWS(onionAddr, onionPort, "host", null).then(roomId => {
        createOverlay(roomId);
        showToast(`Hostando sala: ${roomId}`, Toasts.Type.SUCCESS);
        const videoTrack = stream!.getVideoTracks()[0];
        const canvas = document.createElement("canvas");
        const ctx = canvas.getContext("2d")!;
        sendInterval = setInterval(() => {
            if (!videoTrack || videoTrack.readyState !== "live") { cleanup(); return; }
            const s = videoTrack.getSettings();
            canvas.width = (s.width as number) || 1280;
            canvas.height = (s.height as number) || 720;
            ctx.drawImage(videoTrack as any, 0, 0, canvas.width, canvas.height);
            canvas.toBlob(blob => {
                if (blob && ws && ws.readyState === WebSocket.OPEN) {
                    blob.arrayBuffer().then(buf => {
                        const header = new ArrayBuffer(13);
                        const view = new DataView(header);
                        view.setUint8(0, 0x53); view.setUint8(1, 0x52); view.setUint8(2, 0x46); view.setUint8(3, 0x31);
                        view.setUint8(4, 1); view.setUint16(5, canvas.width, true); view.setUint16(7, canvas.height, true); view.setUint32(9, Date.now(), true);
                        const packet = new Uint8Array(13 + buf.byteLength);
                        packet.set(new Uint8Array(header), 0); packet.set(new Uint8Array(buf), 13);
                        ws!.send(packet);
                    });
                }
            }, "image/webp", QUALITY);
        }, 1000 / FRAME_RATE);
        videoTrack.onended = () => { cleanup(); showToast("Transmissao encerrada", Toasts.Type.FAILURE); };
    }).catch(err => { cleanup(); showToast(`Erro: ${err.message}`, Toasts.Type.FAILURE); });
}
async function queryRooms(): Promise<string[]> {
    return new Promise(res => {
        const s = new WebSocket("ws://127.0.0.1:8080");
        s.binaryType = "arraybuffer";
        const t = setTimeout(() => { try { s.close(); } catch {} res([]); }, 1500);
        s.onopen = () => s.send(JSON.stringify({ type: "query" }));
        s.onmessage = (e: any) => {
            try {
                const msg = JSON.parse(e.data);
                if (msg.type === "rooms") { clearTimeout(t); res(msg.rooms.map((r: any) => r.id)); s.close(); }
            } catch {}
        };
        s.onerror = () => { clearTimeout(t); res([]); };
    });
}
function startView(room: string) {
    showToast("Conectando ao relay...", Toasts.Type.INFO);
    const base = room.trim();
    queryRooms().then(allRooms => {
        const related = allRooms.filter(r => r === base || r.startsWith(base + "-"));
        const toWatch = related.length ? related : [base];
        createMonitorOverlays(toWatch);
        showToast(`Assistindo ${toWatch.length} tela(s) — clique no canvas para fullscreen`, Toasts.Type.SUCCESS);
        toWatch.forEach(r => {
            const url = `ws://127.0.0.1:8080`;
            const s = new WebSocket(url);
            s.binaryType = "arraybuffer";
            activeViewWS.push(s);
            s.onopen = () => s.send(JSON.stringify({ type: "view", room: r }));
            s.onmessage = (e: any) => {
                if (typeof e.data === "string") {
                    try {
                        const m = JSON.parse(e.data);
                        if (m.type === "gone") { showToast(`Sala ${r} encerrada`, Toasts.Type.FAILURE); }
                    } catch {}
                } else handleFrame(e.data, r);
            };
            s.onerror = () => {
                // fallback Tor bridge
                const b = new WebSocket(`ws://127.0.0.1:6789`);
                b.binaryType = "arraybuffer";
                activeViewWS.push(b);
                b.onopen = () => b.send(JSON.stringify({ type: "view", room: r }));
                b.onmessage = (e: any) => { if (typeof e.data !== "string") handleFrame(e.data, r); };
            };
        });
    }).catch(() => {
        // sem query, tenta direto
        createMonitorOverlays([base]);
        connectWS(settings.store.onionAddress, settings.store.onionPort, "view", base).catch(err => showToast(`Erro: ${err.message}`, Toasts.Type.FAILURE));
    });
}

let seenRooms = new Set<string>();
let pollInterval: any = null;
let redButtonObserver: MutationObserver | null = null;
let redButtonStyleInjected = false;

const RED_BTN_CSS = `
.sr-red-share-btn {
    background: #ed4245 !important;
    color: white !important;
}
.sr-red-share-btn:hover { background: #c93a3e !important; }
.sr-red-share-btn svg { color: white !important; }
`;

function ensureRedButtonStyle() {
    if (redButtonStyleInjected) return;
    const s = document.createElement("style");
    s.id = "sr-red-btn-style";
    s.textContent = RED_BTN_CSS;
    document.head.appendChild(s);
    redButtonStyleInjected = true;
}
function removeRedButtonStyle() {
    document.getElementById("sr-red-btn-style")?.remove();
    redButtonStyleInjected = false;
}
function injectRedButtons() {
    ensureRedButtonStyle();
    // procura em varios seletores (Discord usa <button> e <div role=button>)
    const candidates = Array.from(document.querySelectorAll('button[aria-label], [role="button"][aria-label], button, [class*="actionButtons"] button, [class*="panels"] button')) as HTMLElement[];
    let injected = 0;
    for (const btn of candidates) {
        const label = ((btn.getAttribute("aria-label") || btn.getAttribute("title") || "")).toLowerCase();
        // SOMENTE botao de transmissao/share
        const isShare = label.includes("share") || label.includes("compartilhar") || label.includes("go live") || label.includes("transmitir") || label.includes("screen") || label.includes("tela");
        if (!isShare) continue;
        if (btn.closest('[class*="channelTextArea"]') || btn.closest('[class*="chat"]')) continue;
        if ((btn.nextElementSibling as Element)?.classList?.contains("sr-red-share-btn")) continue;
        if (btn.classList.contains("sr-red-share-btn")) continue;

        const newBtn = btn.cloneNode(true) as HTMLElement;
        newBtn.classList.add("sr-red-share-btn");
        newBtn.setAttribute("aria-label", "StreamRelay (servidor privado)");
        (newBtn as any).title = "StreamRelay — abrir painel";
        // limpa listeners antigos: clona de novo
        const cleanBtn = newBtn.cloneNode(true) as HTMLElement;
        cleanBtn.onclick = (e) => { e.preventDefault(); e.stopPropagation(); openStatusModal(); };
        (cleanBtn as HTMLElement).style.background = "#ed4245";
        (cleanBtn as HTMLElement).style.backgroundColor = "#ed4245";
        (cleanBtn as HTMLElement).style.borderColor = "#ed4245";
        (cleanBtn as HTMLElement).style.color = "white";
        (cleanBtn as HTMLElement).style.marginLeft = "8px";
        // garante visibilidade
        (cleanBtn as HTMLElement).style.opacity = "1";
        (cleanBtn as HTMLElement).style.visibility = "visible";
        // força icone branco
        cleanBtn.querySelectorAll("svg, svg path").forEach(el => ((el as HTMLElement).style as any).color = "white");
        try { btn.insertAdjacentElement("afterend", cleanBtn); injected++; } catch {}
        if (injected >= 2) break;
    }
    // fallback: se nao achou botao, injeta flutuante no painel de voz como ultimo recurso
    if (injected === 0) {
        const panel = document.querySelector('[class*="panels"]') || document.querySelector('[class*="container"][class*="panels"]') || document.querySelector('div[class*="actionButtons"]');
        if (panel && !panel.querySelector(".sr-red-share-btn")) {
            const fb = document.createElement("button");
            fb.className = "sr-red-share-btn";
            fb.setAttribute("aria-label", "StreamRelay");
            fb.title = "StreamRelay — abrir painel";
            fb.style.cssText = "background:#ed4245;color:white;border:none;border-radius:8px;padding:8px 12px;margin:8px;cursor:pointer;font-weight:600;display:flex;align-items:center;gap:6px;";
            fb.innerHTML = `<svg width="18" height="18" viewBox="0 0 24 24" fill="white"><rect x="2" y="3" width="20" height="14" rx="2" stroke="white" fill="none" stroke-width="2"/><path d="M8 21h8M12 17v4" stroke="white" stroke-width="2" stroke-linecap="round"/></svg> StreamRelay`;
            fb.onclick = () => openStatusModal();
            panel.appendChild(fb);
        }
    }
}
function startRedButtonObserver() {
    if (redButtonObserver) return;
    injectRedButtons();
    redButtonObserver = new MutationObserver(() => injectRedButtons());
    redButtonObserver.observe(document.body, { childList: true, subtree: true });
}
function stopRedButtonObserver() {
    if (redButtonObserver) { redButtonObserver.disconnect(); redButtonObserver = null; }
    document.querySelectorAll(".sr-red-share-btn").forEach(el => el.remove());
    removeRedButtonStyle();
}

function HelperCodeModal({ modalProps, close, roomId }: { modalProps: any; close: () => void; roomId: string; }) {
    const [copied, setCopied] = useState(false);
    const copy = async () => {
        try { await navigator.clipboard.writeText(roomId); setCopied(true); showToast("Codigo copiado!", Toasts.Type.SUCCESS); setTimeout(() => setCopied(false), 2000); }
        catch { showToast("Falha ao copiar", Toasts.Type.FAILURE); }
    };
    return (
        <Modal {...modalProps} size="sm" title="StreamRelay — Helper conectado">
            <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: "8px 0", alignItems: "center" }}>
                <Text variant="text-sm/normal" style={{ color: "var(--text-muted)", textAlign: "center" }}>Seu helper criou uma sala. Compartilhe o codigo:</Text>
                <div style={{ background: "var(--background-secondary)", borderRadius: 8, padding: 16, fontFamily: "monospace", fontSize: 28, fontWeight: 700, letterSpacing: 2, textAlign: "center", width: "100%" }}>{roomId}</div>
                <Flex style={{ gap: 8 }}>
                    <Button onClick={copy}>{copied ? "Copiado!" : "Copiar codigo"}</Button>
                    <Button color={Button.Colors.PRIMARY} look={Button.Looks.OUTLINED} onClick={close}>Fechar</Button>
                </Flex>
                <Text variant="text-xs/normal" style={{ color: "var(--text-muted)", textAlign: "center" }}>Viewers: /streamrelay → Assistir → cole o codigo. Precisam do helper (streamrelay-start).</Text>
            </div>
        </Modal>
    );
}
function openHelperCodeModal(roomId: string) {
    const key = openModal(props => <HelperCodeModal modalProps={props} close={() => closeModal(key)} roomId={roomId} />);
}
function startPollingHelperRooms() {
    if (pollInterval) return;
    pollInterval = setInterval(async () => {
        try {
            const rooms = await queryRooms();
            for (const r of rooms) {
                const base = r.split("-")[0];
                if (!seenRooms.has(base)) {
                    seenRooms.add(base);
                    // so mostra para salas criadas ha pouco (helper acabou de conectar)
                    openHelperCodeModal(base);
                }
            }
            // marca salas antigas como vistas para nao repetir
            rooms.forEach(r => seenRooms.add(r.split("-")[0]));
        } catch {}
    }, 4000);
}
function stopPollingHelperRooms() { if (pollInterval) { clearInterval(pollInterval); pollInterval = null; } }

// ---------- Modal ----------
function StatusModal({ modalProps, close }: { modalProps: any; close: () => void; }) {
    const [helperOk, setHelperOk] = useState<boolean | null>(null);
    const [room, setRoom] = useState("");

    useEffect(() => { checkHelperStatus().then(setHelperOk); }, []);

    return (
        <Modal {...modalProps} size="md" title="StreamRelay — Assistir">
            <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: "8px 0" }}>
                <Flex direction="column" style={{ gap: 8 }}>
                    <Text variant="heading-sm/semibold">Status</Text>
                    <div style={{ background: "var(--background-secondary)", borderRadius: 8, padding: 12, display: "flex", flexDirection: "column", gap: 8 }}>
                        <Flex alignItems="center" style={{ gap: 8 }}>
                            <span style={{ width: 10, height: 10, borderRadius: "50%", background: helperOk === null ? "#80848e" : helperOk ? "#23a559" : "#f23f43", display: "inline-block" }} />
                            <Text variant="text-sm/medium">Helper: {helperOk === null ? "verificando..." : helperOk ? "conectado (127.0.0.1:6789 / 8080)" : "desconectado"}</Text>
                        </Flex>
                        {!helperOk && helperOk !== null && (
                            <Text variant="text-xs/normal" style={{ color: "var(--text-muted)" }}>
                                Rode no terminal: <code>streamrelay-start</code> ou <code>curl -sL https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-helper.sh | bash</code>
                            </Text>
                        )}
                        <Text variant="text-xs/normal" style={{ color: "var(--text-muted)", fontFamily: "monospace", wordBreak: "break-all" }}>
                            Onion: {settings.store.onionAddress}:{settings.store.onionPort}
                        </Text>
                        <Text variant="text-xs/normal" style={{ color: "var(--text-muted)" }}>
                            Transmissão via helper externo (grim). Plugin só assiste.
                        </Text>
                    </div>
                </Flex>

                <Divider />

                <Flex direction="column" style={{ gap: 8 }}>
                    <Text variant="heading-sm/semibold">Assistir transmissão</Text>
                    <Text variant="text-sm/normal" style={{ color: "var(--text-muted)" }}>Insira o código da sala criado pelo host.</Text>
                    <TextInput value={room} onChange={setRoom} placeholder=" room id (ex: wmqjpl)" />
                    <Flex style={{ gap: 8 }}>
                        <Button disabled={!room || helperOk === false} onClick={() => { close(); startView(room); }}>Assistir sala</Button>
                        <Button color={Button.Colors.RED} disabled={!stream && !overlayEl} onClick={() => { cleanup(); close(); showToast("Visualização parada", Toasts.Type.SUCCESS); }}>Parar</Button>
                    </Flex>
                </Flex>
            </div>
        </Modal>
    );
}

function openStatusModal() {
    const key = openModal(props => <StatusModal modalProps={props} close={() => closeModal(key)} />);
}

function interceptedGetDisplayMedia(options: any) {
    if (settings.store.autoRelay) {
        // abre modal em vez de picker direto
        openStatusModal();
        // retorna promise que nunca resolve - o modal vai iniciar o stream real
        return new Promise(() => {});
    }
    if (originalGetDisplayMedia) return originalGetDisplayMedia.call(navigator.mediaDevices, options);
    throw new Error("getDisplayMedia not available");
}

export default definePlugin({
    name: PLUGIN_KEY,
    description: "Private screen sharing via Tor - modal com status do helper e selecao de tela",
    authors: [Devs.Ven],
    settings,
    start() {
        injectPopupBlockerCSS(); startPopupObserver(); startRedButtonObserver();
        if (navigator.mediaDevices?.getDisplayMedia) {
            originalGetDisplayMedia = navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
            navigator.mediaDevices.getDisplayMedia = interceptedGetDisplayMedia;
        }
        startPollingHelperRooms();
        queryRooms().then(rooms => rooms.forEach(r => seenRooms.add(r.split("-")[0]))).catch(() => {});
    },
    stop() {
        cleanup(); removePopupBlockerCSS(); stopPopupObserver(); stopPollingHelperRooms(); stopRedButtonObserver();
        if (originalGetDisplayMedia) { navigator.mediaDevices.getDisplayMedia = originalGetDisplayMedia; originalGetDisplayMedia = null; }
    },
    commands: [
        {
            name: "streamrelay",
            description: "Abrir painel StreamRelay (status helper + transmitir)",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [],
            async execute() { openStatusModal(); },
        },
        {
            name: "streamhost",
            description: "Abrir painel para transmitir",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [],
            async execute() { openStatusModal(); },
        },
        {
            name: "streamview",
            description: "Abrir painel para assistir",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [],
            async execute() { openStatusModal(); },
        },
        {
            name: "streamstop",
            description: "Parar transmissao",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [],
            async execute(args, ctx) { cleanup(); sendBotMessage(ctx.channel.id, { content: "Transmissao encerrada" }); },
        },
    ],
});
