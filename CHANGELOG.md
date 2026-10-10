# Changelog

## Próxima versão — estabilidade e experiência de reprodução

- Recuperação live de rede opt-in, com watchdog de posição, backoff limitado e cancelamento por intenção/lifecycle.
- Políticas explícitas de áudio nativo (`preserveHost`, `mixWithOthers`, `exclusive`) e opt-in de background, sem serviço ou garantia de reprodução em background.
- Headers HTTP por fonte/playlist no iOS via options de `AVURLAsset`, com ressalvas de propagação HLS/redirects documentadas.
- Cleanup independente com deadlines, liberação de criações nativas tardias e logs correlacionados por player.
- Controles completos/simplificados/live, fullscreen, gestos com feedback e layout compacto com progresso junto à borda.
- Estado compacto compartilhável entre views/controllers, preservado em transições; toque para ocultar/exibir também com vídeo pausado e indicador de pausa no compacto.
- Prévia durante scrubbing opt-in com coalescing, guards de ownership e retomada protegida; Android espera callback de frame com deadline e restaura parâmetros de seek.
- Android reassocia a superfície após resize do `SurfaceProducer`; removido registro redundante das pastas Kotlin como fontes Java.
- Teardown reforçado no Android/iOS/WebView, testes de regressão e checklist de validação física em `MOBILE_VALIDATION.md`.
- Prévia Android confirmada pelo usuário após correção da superfície; isso não substitui matriz completa de dispositivos, testes de rede/áudio ou profiling.

## Próxima versão — enquadramento

- BoxFit completo para textura nativa e WebView, incluindo contain, cover, fill, fitWidth/fitHeight, none e scaleDown.
- Proporção original ou aspectRatio explícito, independente do fit.
- `LumioVideoLayout.expand` para ocupar área finita disponível, com erro descritivo em altura ilimitada.
- `controller.videoFit` / `setVideoFit` para mudança dinâmica sem reabrir mídia.
- Fit preservado no fallback e reaplicado na WebView após metadata/resize.
- Corrigida a estrutura HTML/CSS do player web para aplicação consistente dos estilos.
- Exemplo com seletores de fit e aspect ratio; testes de layout/resize e CSS.

## Próxima versão — estatísticas para nerds

- Painel `LumioStatisticsView` e ação opt-in `showStatistics`, desabilitada por padrão.
- Polling de 2s somente durante exibição/app ativo, sem sobreposição; erro mantém último snapshot com aviso.
- Snapshot sanitizado copiável, dados comuns de reprodução e informação explícita de métricas indisponíveis.
- Android: FPS/bitrate/faixas, buffers/live offset e frames renderizados/descartados, além do codec/decoder e dispositivo existentes.
- iOS: metadados de faixa FourCC/bitrate/FPS carregados assincronamente por APIs públicas (iOS15+), categoria do dispositivo/SO; decoder permanece indisponível.
- WebView: codec/bitrate declarados da variante HLS.js e frame counters do browser quando suportados; sem inferência de decoder.
- Validação: análise limpa, 94 testes Flutter, 16 testes Android, 4 testes JavaScript, build iOS simulator e 6 integrações iOS passaram; integração verifica codec avc1 de asset MP4.

## Próxima versão — controles e playlist

- Controles próprios habilitados por padrão, com switches independentes para botões, progresso, tempos, título, volume, speed, loader e gestos.
- Velocidades configuráveis, padrão 1/1.5/2/3/4x; cor/estilos da barra e visual escuro.
- Duplo toque por metade da superfície para seek de ±10s e hold temporário 2x com restauração protegida contra comandos posteriores.
- Zoom/pan opcional até 4x e modo compacto com somente progresso após 2s sem interação.
- Slider de volume conforme capacidades da engine; progresso com scrub local e seek no fim do arrasto.
- `LumioPlaylist`/`LumioPlaylistItem`, índice/título observáveis e comandos next/previous/select.
- Filas nativas reais no Media3 e AVQueuePlayer, avanço automático sem recriar textura e looping de item/fila.
- Sequência WebView gerenciada pelo controller, com índice preservado ao trocar de engine.
- Headers default por controller e por abertura/playlist, precedência case-insensitive, `openUrl` e sanitização de segredos de toda a fila.
- Cancelamento seguro de seleção pendente ao descartar o controller.
- Exemplo interativo com seleção de velocidades, compacto, zoom, headers e playlist sintética.
- Validação: 91 testes Flutter, 16 testes nativos Android e 6 integrações iOS passaram; as novas integrações exercitam avanço automático/navegação/textura da fila nativa e sequência WebView com índice preservado ao retornar ao nativo.
- Headers arbitrários continuam limitados ao Android nativo; não foi utilizado recurso não público do AVFoundation.

## 0.1.0 — não publicado

### Implementação inicial

- Plugin Flutter independente, sem `video_player` e sem dependência de GetX.
- Android em Kotlin com Media3/ExoPlayer 1.9.2; iOS em Swift com AVPlayer/AVFoundation.
- Texturas nativas, roteamento de eventos por instância e liberação de recursos no detach.
- Fontes de rede, arquivos locais e assets nos backends nativos; vídeo e áudio-only.
- HLS live/VOD, mídia progressiva; módulos DASH e RTSP no Android.
- Controller público observável com configuração, estado imutável, capacidades e erros tipados.
- Play, pause, seek, retorno ao live, volume, velocidade, looping e retry.
- Troca Nativo ↔ WebView com preservação de intenção de reprodução e tentativa de restaurar posição VOD.
- Fallback automático restrito a fontes/erros elegíveis; erros conhecidos de rede/autenticação são excluídos.
- Engine WebView HTTP(S) com HLS nativo ou HLS.js 1.6.13 empacotado, sem CDN em runtime.
- Configuração de buffer; decoder fallback e target offset live no Android, com capacidades/limitações explícitas no iOS.
- Diagnósticos Android com decoder selecionado; access/error logs AVPlayer e estado da bridge WebView.
- Logs opt-in via callback/stream, erros e diagnósticos sanitizados, sem upload automático.
- Timeout de inicialização/comandos, fila serializada, cancelamento via dispose e cleanup de criações tardias.
- Intenção de play/pause preservada durante buffering, retry e transição de engine.
- WebView iOS com mute/unmute e capacidade explícita de ausência de ganho fracionário de volume.
- View e controles reutilizáveis: play/pause, seek no fim do arrasto, tempos, mute, velocidade, engine, retorno ao live e retry.
- App de exemplo com fontes/modos configuráveis, logs, diagnósticos e fixtures sintéticos MP4/WAV.
- Documentação de uso, toolchain, protocolo nativo e diferenças entre plataformas.

### Validação

- Análise Flutter sem apontamentos.
- 43 testes Flutter do plugin e 1 teste unitário do exemplo aprovados.
- 10 testes unitários Android aprovados.
- Testes Swift de configuração e cálculo de live seek aprovados, com warnings como erros.
- 4 testes isolados JavaScript aprovados.
- Build Android APK aprovado.
- Build e 4 testes de integração aprovados no simulador iPhone 17 Pro / iOS 26.5:
  montagem, vídeo de rede e comandos nativos, troca de engine, WebView,
  vídeo asset/arquivo local e áudio WAV asset.

### Limitações conhecidas

- iOS/WebView não aceitam headers arbitrários; iOS não suporta RTSP/DASH neste backend.
- WebView suporta mídia de rede, não arquivos/assets, e depende de CORS/autoplay/codecs.
- Buffer/decoder/live offset não oferecem os mesmos controles em todas as plataformas.
- Sem codecs próprios, DRM, PiP, fullscreen embutido, serviço de áudio em background,
  seleção de faixas/legendas/qualidade, cache offline ou suporte desktop/Flutter Web.
- HLS/DASH/RTSP e live seek em transmissão real, dispositivos físicos e diferenças
  entre fabricantes não foram certificados pelos testes de integração atuais.
- Licença privada; publicação exige decisão explícita dos titulares.
