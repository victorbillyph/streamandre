# StreamRelay

Sistema de transmissao de tela privada via Tor hidden service.
Apenas quem tem o plugin Vencord pode ver a transmissao.

## Instalacao Rapida

### Linux (1 comando)
```bash
curl -sL https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-helper.sh | bash
```

### Windows (PowerShell)
```powershell
irm https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-helper.ps1 | iex
```

### Plugin Vencord (1 comando)
```bash
curl -sL https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-linux.sh | sudo bash
```

## Como Funciona

```
Host (grim/ffmpeg) → Bridge (WebSocket) → Tor → Hidden Service → Tor → Bridge → Viewer (Plugin)
```

## Arquitetura

- **Servidor Relay** (`server/relayServer.mjs`) - Roda na maquina do host
- **Bridge Tor** (`client/bridge.mjs`) - Conecta ao servidor via Tor
- **Capture Helper** (`client/capture-helper.js`) - Captura tela e envia frames
- **Plugin Vencord** (`plugin/StreamRelay.tsx`) - Ve a transmissao no Discord

## Uso Manual

### 1. Iniciar servidor (esta maquina)
```bash
cd server
npm install
TOR_DATA_DIR=../tor-data node relayServer.mjs
```

### 2. Iniciar bridge (quem vai transmitir)
```bash
cd client
npm install
node bridge.mjs <endereço-onion> 8080
```

### 3. Iniciar captura de tela
```bash
node capture-helper.js
```

### 4. No Discord (quem vai assistir)
- Copie `plugin/StreamRelay.tsx` para `Vencord/src/userplugins/`
- Recompile com `pnpm build`
- Comandos:
  - `/streamhost room:<sala>` - transmitir tela
  - `/streamview room:<sala>` - assistir
  - `/streamstop` - parar

## Endereco Onion

Seu servidor esta rodando em:
```
m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion:8080
```

## Comandos Discord

| Comando | Descricao |
|---------|-----------|
| `/streamhost room:<sala>` | Inicia transmissao via relay |
| `/streamview room:<sala>` | Conecta como viewer |
| `/streamstop` | Para transmissao atual |

## Settings do Plugin

No Vencord Settings > Plugins > StreamRelay:
- **Endereco Onion** - Endereco do servidor (padrao: seu onion)
- **Porta** - Porta do servidor (padrao: 8080)
- **Auto Relay** - Interceptar screen share automaticamente

## Seguranca

- Toda comunicacao passa por Tor
- Servidor nao loga conteudo
- Streams sao em tempo real via WebSocket binario
- Codec: WebP a 15fps, qualidade 60%

## Troubleshooting

### Capture helper nao conecta
- Verifique se o bridge esta rodando: `ps aux | grep bridge`
- Verifique se Tor esta rodando: `ss -tlnp | grep 9050`

### Plugin nao aparece no Discord
- Verifique se o plugin foi compilado: `cd ~/Vencord && pnpm build`
- Reinicie o Discord

### Captura de tela nao funciona (Flatpak)
- Execute: `flatpak override --user --socket=x11 --socket=wayland --device=dri com.discordapp.Discord`
- Ou use o capture-helper.js (recomendado)

## Links

- [GitHub](https://github.com/victorbillyph/streamandre)
- [Vencord](https://vencord.dev)
- [Tor Project](https://www.torproject.org)
