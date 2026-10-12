# Validação mobile em dispositivos físicos

Esta checklist registra cenários de aceitação, não resultados já aprovados. Testes Dart com fake channels, compilação e testes de parsers não comprovam comportamento de rede, foco de áudio ou memória real.

## Preparação

- Testar pelo menos um iPhone físico e dois Android de fabricantes/versões diferentes, registrando aparelho, OS, engine, build e protocolo.
- Usar fontes de teste controladas: HLS live, gravação VOD, HTTP autenticado e RTSP Android quando aplicável.
- Não colocar URLs assinadas, tokens, headers ou dados de usuários nos relatórios. Logs e diagnostics também precisam de revisão antes de envio.
- Executar o app manualmente pelo fluxo habitual; esta checklist não requer que o agente rode `flutter run`.

## Rede e recuperação

- [ ] Com live tocando, desligar e religar Wi-Fi; repetir alternando Wi-Fi/dados móveis.
- [ ] Interromper o servidor/segmentos sem encerrar a conexão: observar watchdog de posição, restarts e ausência de retries infinitos.
- [ ] Falhar as três tentativas: erro terminal deve continuar visível, com ação manual de retry.
- [ ] Recuperar apenas por instantes e falhar novamente: `initialized` sozinho não deve renovar orçamento.
- [ ] Recuperar por mais de 30 s de progresso sustentado: nova falha ganha novo orçamento.
- [ ] Simular 401/403 e 404 de manifest/chave: não repetir autenticação ou fonte inexistente automaticamente nem perder o erro.
- [ ] Android HLS live: após iniciar playback, responder 404 para um segmento e manter uma janela nova válida; verificar `hls_live_segment_unavailable`, reabertura e retorno à posição live antes de play.
- [ ] Manter segmentos HLS live indisponíveis: respeitar o orçamento e preservar erro terminal; pausar/sair durante a recuperação cancela a retomada.
- [ ] VOD HLS com segmento 404: não aplicar a recuperação específica de segmento live.
- [ ] iOS: interromper uma live já inicializada; quando a cadeia NSError permitir, observar `ios_live_network_interruption`, reabertura e retorno ao live antes de play.
- [ ] iOS: 404, auth/TLS/codec ou causa desconhecida devem produzir `ios_native_terminal_error`, preservando `nativeErrorPhase` e sem reinícios automáticos.
- [ ] iOS: substituir fonte/item e verificar que readiness, evidência de janela live e erros antigos não autorizam recuperação da nova fonte.
- [ ] Pausar/ocultar/sair durante delay e durante reabertura: não retomar áudio/vídeo após abandono.
- [ ] WebView: manter superfície montada ao mostrar erro; recuperação deve carregar a nova fonte.
- [ ] VOD: não aplicar watchdog live nem perder posição por recovery automático.

O watchdog usa posição. Se frames congelam mas o relógio avança, ele pode não detectar a falha; se o backend reporta posição live constante, pode detectar falso stall. Registrar esses casos antes de reduzir o timeout padrão de 20 s.

## Interfone, áudio e lifecycle

- [ ] Abrir câmera durante chamada WebRTC: câmera muda desde o primeiro frame, chamada sem interrupção.
- [ ] Reconectar câmera durante a chamada: volume continua zero, sem troca indevida de saída de áudio.
- [ ] Ocultar câmera durante reconexão: sem reprodução atrasada; encerrar chamada libera a câmera.
- [ ] Alternar viva-voz, fone e Bluetooth; atender interrupção do sistema e retornar.
- [ ] Background/foreground com `allowBackgroundPlayback: false`: pausa e só retoma se ainda havia intenção de play.
- [ ] Pausar explicitamente antes/durante background: não retomar no retorno.
- [ ] Testar `preserveHost`, `mixWithOthers` e `exclusive` em reprodução independente, incluindo outro app de áudio. Não confundir a política com serviço/background garantido.

## Headers iOS

- [ ] Verificar no servidor o recebimento dos headers no vídeo progressivo.
- [ ] HLS: verificar manifest principal, playlists filhas, segmentos e chaves de criptografia quando usadas.
- [ ] Verificar redirects com infraestrutura controlada e confirmar que credenciais não chegam a hosts indevidos.
- [ ] Playlist/retry: headers corretos em cada item e após reconstrução.

O caminho iOS usa `AVURLAssetHTTPHeaderFieldsKey` como string de options, sem contrato público documentado da Apple. Não registrar como suporte universal de autenticação HLS antes dessas verificações.

## Buffer, posição sob demanda e Platform View

- [ ] Em VOD iOS/WebView, fazer seeks distantes e verificar intervalos separados: a barra não deve pintar os gaps como bufferizados. Android deve mostrar apenas o trecho conhecido pelo Media3, sem presumir início zero.
- [ ] Consultar `getPosition()` após seek, play e pause; comparar com o quadro/timeline sem exigir precisão frame a frame.
- [ ] Trocar fonte/item/engine ou descartar durante uma consulta: o resultado antigo não deve atualizar a nova sessão.
- [ ] Repetir reprodução com `nativeViewType: texture` e `platformView` no mesmo dispositivo/stream. Comparar vídeo preto, rotação, enquadramento, FPS, CPU/memória sem pressupor superioridade de um modo.
- [ ] Platform View: testar todos os fits, clipping, zoom/pan, gestos, overlays e fullscreen ida/volta repetidamente; somente uma superfície deve controlar o player.
- [ ] Testar montagem tardia, desmontagem durante loading, remount, fallback WebView e retorno ao nativo, sem áudio/fonte duplicados.
- [ ] Confirmar que a captura por RepaintBoundary fica indisponível para Platform View e que o host informa isso, sem exportar imagem preta.

## Recursos e desempenho

- [ ] Fazer 30 ciclos abrir/fechar, incluindo sair durante loading, erro e recuperação.
- [ ] Repetir fullscreen e câmera vinculada ao interfone; não acumular players, texturas ou callbacks.
- [ ] Usar Instruments (Allocations/Leaks) no iOS e Memory Profiler no Android: comparar baseline, pico, estabilização após fechamento e tendência ao longo dos ciclos.
- [ ] Registrar CPU, memória e energia por engine sob fonte/resolução iguais.

Logs `disposed` confirmam o protocolo de cleanup, não devolução imediata de RAM ou ausência de vazamentos. Não exigir memória idêntica após cada ciclo: caches do runtime/OS podem permanecer. Investigar crescimento sustentado e recursos ainda ativos.

## Registro de resultado

Para cada cenário: data, dispositivo/OS, engine, fonte sanitizada/protocolo, passos, esperado, observado, aprovado/reprovado e evidência sanitizada. Não marcar cenários não executados como aprovados.
