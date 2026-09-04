# 🎬 StreamAndre — Transmissão privada via Tor

> Compartilhe sua tela no Discord **sem usar os servidores do Discord**. Só quem tem o plugin vê. Tudo via Tor.

[![Vencord](https://img.shields.io/badge/Vencord-Plugin-5865F2)](https://vencord.dev) [![Tor](https://img.shields.io/badge/Tor-Hidden%20Service-7D4698)](https://www.torproject.org) [![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue)](LICENSE)

### ✨ Como funciona?
```
Você (grim) → Helper → Relay (8080) → Tor onion → Bridge (6789) → Amigo (plugin)
```
- **Host transmite com o helper** (fora do Discord, funciona até no Flatpak/Wayland).
- **Viewer assiste dentro do Discord** com overlay + fullscreen. Sem helper não vê nada.

---

## 🚀 Instalação em 1 comando

### 1️⃣ Helper (transmitir) — Linux
```bash
curl -sL https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-helper.sh | bash
# clone vai para /tmp e instala em ~/.local/share/streamrelay
```

### Helper — Windows (PowerShell Admin)
```powershell
irm https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-helper.ps1 | iex
```

### 2️⃣ Plugin Vencord (assistir) — Linux
```bash
curl -sL https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-linux.sh | sudo bash
# ou manual: copie plugin/StreamRelay.tsx → Vencord/src/userplugins/ → pnpm build
```

> **Depois de instalar o plugin:** `cd ~/Vencord && sudo pnpm inject` → reinicie o Discord → botão **vermelho** aparece ao lado do botão nativo de transmissão.

---

## 🎮 Usando

### Transmitir (Host) — precisa do helper
```bash
streamrelay-start
# 1. inicia Tor (baixa sozinho se não tiver)
# 2. inicia relay local
# 3. inicia bridge
# 4. captura tela com grim (todos os monitores em 1 sala) a 10 FPS
```
Você verá:
```
[Helper] Sala criada: qf90dc (compartilhe este ID)
[Helper] Capturando 2 tela(s)... 30 frames
```
No Discord, assim que o helper criar a sala, abre **modal automático** com o código grande e botão **Copiar código** — envie aos amigos.

> **Rede descentralizada (opcional):** cada um roda seu próprio onion
> ```bash
> streamrelay-network host              # host com onion próprio
> streamrelay-network view <onion>      # viewer via Tor
> streamrelay-network addpeer <onion>   # adicionar amigo
> streamrelay-network listpeers         # listar
> ```

### Assistir (Viewer) — precisa do helper também!
Mesmo pra só assistir precisa do helper rodando (bridge).

1. Deixe o helper ligado: `streamrelay-start` (pode deixar sem transmitir, só o bridge)
2. No Discord, clique no **botão vermelho** ao lado do botão de Compartilhar Tela, ou digite:
   - `/streamrelay` → abre painel
   - `/streamview` → abre painel

No painel:
- **Status** mostra `Helper: conectado (127.0.0.1:8080 / 6789)` (verde) ou `desconectado` (vermelho) + onion
- **Assistir transmissão** → cole o código (ex: `qf90dc`) → **Assistir sala**
- Aparece overlay `400×300` no canto superior direito com header `Monitor 1 - qf90dc`
  - Clique no canvas ou `⛶` para **fullscreen** por monitor
  - `Stop` para parar
  - Se host tem 2+ monitores, aparecem janelas empilhadas (mesma sala, imagem combinada; fullscreen mostra tudo)

---

## 💬 Comandos no Discord

| Comando | O que faz | Onde |
|---------|-----------|------|
| `/streamrelay` | Abre painel (status helper + assistir) | Chat |
| `/streamhost` | Abre mesmo painel (legado) | Chat |
| `/streamview` | Abre mesmo painel | Chat |
| `/streamstop` | Para overlay/viewer | Chat |
| **Botão vermelho** | Ao lado do botão nativo de Go Live/Share | Call |

**Settings:** Vencord → Settings → Plugins → StreamRelay
- `Endereco .onion` (padrão: `m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion`)
- `Porta` (8080)
- `Auto Relay` (intercepta `getDisplayMedia` e abre painel)

---

## 🧩 Arquitetura e Pastas

| Pasta | O que é |
|-------|---------|
| `server/relayServer.mjs` | Relay WebSocket (`:8080`), salas `roomId` → `host/viewers` |
| `client/bridge.mjs` | Bridge `127.0.0.1:6789` → Tor SOCKS `9050` → `onion:8080` |
| `client/capture-helper.js` | Captura `grim -o <mon> -t jpeg` → header `SRF1` → relay (10 FPS) |
| `client/network-helper.js` | Rede descentralizada: cada nó com onion próprio, gossip |
| `plugin/StreamRelay.tsx` | Plugin view-only, modal de código, polling de salas |
| `tor-data/` | `hostname` onion, `torrc` |

---

## 🔧 Manual (sem script)

```bash
# relay
cd server && npm install && TOR_DATA_DIR=../tor-data node relayServer.mjs

# bridge (viewer precisa)
cd client && npm install && node bridge.mjs m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion 8080

# captura (host)
node capture-helper.js  # conecta direto em 127.0.0.1:8080

# plugin
cp plugin/StreamRelay.tsx Vencord/src/userplugins/ && cd Vencord && pnpm build && sudo pnpm inject
```

---

## 🛡️ Segurança e Privacidade

- Tudo via Tor, sem passar pelos servidores do Discord
- Sem logs de conteúdo no relay (só `roomId` e `viewers`)
- Binário WebSocket com header `SRF1` (13 bytes) + `jpeg` (grim)
- Flatpak/Wayland: helper captura fora do sandbox (PipeWire/grim), plugin só assiste

---

## ❓ Troubleshooting

**Helper fica 0 frames / `grim falhou`**
- `grim` só suporta `png|ppm|jpeg` → helper usa `jpeg -q 60` (fix `e66e7c9`)
- Verifique: `grim -t jpeg -q 60 /tmp/test.jpeg && ls -lh /tmp/test.jpeg`
- Wayland: `hyprctl monitors -j` ou `wlr-randr` deve listar saídas

**Helper desconecta / `SOCKS5 connect failed: 5`**
- Host usa relay direto (`127.0.0.1:8080`), não precisa Tor. Bridge é só para viewers remotos.
- Aguarde 30–60s para descriptor Tor publicar se viewer for remoto.

**Plugin mostra `Helper: desconectado`**
- `ss -tlnp | grep 9050` (Tor) e `ss -tlnp | grep 8080` (relay) devem responder
- `ps aux | grep capture-helper` e `ps aux | grep bridge.mjs`

**Plugin não aparece / botão vermelho não aparece**
- `cd ~/Vencord && pnpm build && sudo pnpm inject` → reinicie Discord
- Botão só aparece em call/voice (clone do `Go Live/Share Screen`, não nos controles de janela)

**Captura Flatpak bloqueada (`Not Supported`)**
- Normal no Discord Flatpak — use helper: `streamrelay-start` (não precisa `getDisplayMedia`)

---

## 🔗 Links

- Repo: https://github.com/victorbillyph/streamandre
- Vencord Docs (custom plugins): https://docs.vencord.dev/installing/custom-plugins/
- Tor: https://www.torproject.org
