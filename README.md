# StreamRelay - Screen Sharing via Tor

Sistema de transmissão de tela privada usando Tor hidden service.
Apenas quem tem o plugin Vencord pode ver a transmissão.

## Arquitetura

```
Host (Discord+Plugin) → Local Bridge → Tor → Hidden Service → Tor → Local Bridge → Viewer (Discord+Plugin)
```

## Setup

### 1. Iniciar o servidor (esta máquina)

```bash
cd server
npm install
TOR_DATA_DIR=../tor-data node relayServer.mjs
```

O endereço .onion é gerado automaticamente em `tor-data/hostname`.

### 2. Para cada cliente (quem vai assistir)

```bash
# Instalar Tor (se não tiver)
# Debian/Ubuntu: sudo apt install tor
# macOS: brew install tor
# Windows: baixar do site do Tor Project

# Iniciar Tor
tor
# (escuta em 127.0.0.1:9050)

# Instalar bridge
cd client
npm install
node bridge.mjs <endereço-onion> 8080
```

### 3. No Discord (Vencord)

Copie `plugin/StreamRelay.tsx` para `Vencord/src/plugins/` e recompile.

**Para transmitir tela:**
```
/streamhost onion:<endereço>.onion room:<sala>
```

**Para assistir:**
```
/streamview onion:<endereço>.onion room:<sala>
```

**Para parar:**
```
/streamstop
```

## Comandos

| Comando | Descrição |
|---------|-----------|
| `/streamhost` | Inicia transmissão via relay |
| `/streamview` | Conecta como viewer |
| `/streamstop` | Para transmissão atual |

## Segurança

- Toda comunicação passa por Tor
- Servidor não loga conteúdo
- Streams são em tempo real via WebSocket binário
- Codec: WebP a 15fps, qualidade 60%

## Troubleshooting

- **Bridge não conecta**: Verifique se Tor está rodando (`ss -tlnp | grep 9050`)
- **Sem imagem**: Verifique se o firewall bloqueia WebSocket
- **Lento**: Tor adiciona latência, considere reduzir FPS
