# lumio_player

Plugin Flutter privado para reprodução de vídeo, áudio e transmissões ao vivo em **Android e iOS**, com controller unificado, estado observável, diagnósticos e engine WebView opcional.

É um **plugin nativo independente**: usa AndroidX Media3 ExoPlayer diretamente no Android e AVPlayer/AVFoundation diretamente no iOS. **Não depende de `video_player`**, não encapsula seu controller e não é uma implementação de sua interface de plataforma. A engine WebView roda dentro do app móvel; isso **não significa suporte a Flutter Web**. Não há implementação para desktop.

Versão Dart atual: **0.1.0**. O pacote está em desenvolvimento; capacidades de formato não são garantias de decodificação ou de comportamento idêntico entre plataformas.

## Índice

- [Instalação e compatibilidade](#instalação-e-compatibilidade)
- [Início rápido e ciclo de vida](#início-rápido-e-ciclo-de-vida)
- [Fontes, áudio e live](#fontes-áudio-e-live)
- [Matriz de suporte](#matriz-de-suporte)
- [API, configuração e controles](#api-configuração-e-controles)
- [Engines e fallback](#engines-e-fallback)
- [Estado, erros, logs e diagnósticos](#estado-erros-logs-e-diagnósticos)
- [Arquitetura e protocolo nativo](#arquitetura-e-protocolo-nativo)
- [Exemplo, testes e builds](#exemplo-testes-e-builds)
- [Limitações e roadmap](#limitações-e-roadmap)
- [Licença](#licença)

## Instalação e compatibilidade

`pubspec.yaml` contém `publish_to: none`: **não há instalação publicada no pub.dev**. Em um app com o pacote em uma pasta irmã:

```yaml
dependencies:
  flutter:
    sdk: flutter
  lumio_player:
    path: ../lumio_player
```

Também é possível usar uma dependência Git depois que o pacote estiver disponível em um repositório acessível ao consumidor:

```yaml
dependencies:
  lumio_player:
    git:
      url: <URL_DO_REPOSITORIO_PRIVADO>
      ref: <COMMIT_FIXADO>
      # path: <SUBDIRETORIO_DO_PACOTE> # somente se não estiver na raiz
```

Os campos entre `<...>` são valores a substituir, não um endereço ou uma tag já publicados. Não há remoto Git verificado nesta cópia. Configure acesso ao repositório privado fora do `pubspec.yaml`; não inclua tokens na URL. Prefira um commit fixo para builds reproduzíveis. Execute `flutter pub get` no app consumidor.

### Toolchain: declaração não é validação de compatibilidade

| Camada | Configuração inspecionada |
| --- | --- |
| Manifesto do pacote | **Dart `>=3.12.0 <4.0.0`; Flutter `>=3.44.0`**, mínimos explícitos |
| Resolução atual em `pubspec.lock` | **Dart `>=3.12.0 <4.0.0`; Flutter `>=3.44.0`** |
| Ambiente inspecionado | Flutter **3.44.8** stable, Dart **3.12.2** |
| Exemplo | Dart `^3.12.2` em `example/pubspec.yaml` |
| Android do plugin | **minSdk 24**, **compileSdk 36**, Java/JVM **17** |
| Build Android | AGP **9.0.1**, Kotlin **2.3.20** configurado; wrapper do exemplo Gradle **9.1.0** |
| Media3 | **1.9.2**, incluindo módulos HLS, DASH e RTSP |
| iOS/CocoaPods | Deployment target **13.0**, Swift language mode **5.0** |
| iOS/Swift Package | iOS **13.0**, `swift-tools-version: 5.9`; referência local a `FlutterFramework` |
| App exemplo iOS | Deployment target **15.0**, ajustado para Xcode 27; o plugin permanece em **13.0** |
| Xcode inspecionado | **27.0**; não estabelece um mínimo de Xcode validado |

O lockfile resolve `webview_flutter` e `webview_flutter_android` em **4.14.1**, e `webview_flutter_wkwebview` em **3.26.2**. Mesmo escolhendo somente a engine nativa, essas dependências continuam no pacote. O manifesto agora explicita os mesmos mínimos do lockfile: **Flutter 3.44 e Dart 3.12**. Flutter 3.35/Dart 3.8 não são mais versões admitidas pelo manifesto.

O scaffold Android do exemplo usa `flutter.compileSdkVersion`, `flutter.minSdkVersion`, `flutter.targetSdkVersion` e `flutter.ndkVersion`. No SDK Flutter 3.44.8 inspecionado, os valores efetivos são **compile 36, min 24, target 36 e NDK 28.2.13676358** — não assuma os valores de templates antigos. O plugin fixa compile/min, mas o target do app pertence ao consumidor. AGP 9 tem suporte Kotlin integrado; o plugin aplica `org.jetbrains.kotlin.android` quando `android.builtInKotlin=false`. O exemplo mantém `android.builtInKotlin=false` e `android.newDsl=false`, vindos do template. A versão Kotlin configurada não é uma promessa de ser a mais recente disponível nem de funcionar com qualquer combinação AGP/Flutter.

No iOS, podspec e Swift Package mantêm o mínimo do plugin em **13.0**; o app exemplo usa **15.0** para a toolchain Xcode 27. O podspec está alinhado à versão Dart **0.1.0**, identifica `Lumio Player maintainers` como autor e não contém a homepage fictícia do scaffold. O layout Swift Package depende da integração Flutter, não é um pacote AVPlayer autônomo para compilar isoladamente com `swift test`.

**Antes de integrar no projeto pai**, confira com seus responsáveis o SDK Flutter/Dart adotado, a resolução de dependências, AGP/Gradle/Kotlin/JDK, SDK Android e deployment target iOS efetivos. Use a maior exigência entre app, plugin, dependências e SDK Flutter. Não há matriz de CI que certifique versões antigas ou a compatibilidade com um projeto pai específico.

### Políticas do app consumidor

- Android: o plugin declara `INTERNET`; permissões de arquivos e concessões de `content://` são responsabilidade do app.
- Use HTTPS. Cleartext Android e App Transport Security no iOS continuam sob política do app; o plugin não enfraquece automaticamente essas restrições.
- Assets de mídia devem ser declarados no pacote/app que os fornece. Os assets da engine WebView já estão declarados no manifesto deste plugin.
- Áudio em background, sessão de áudio, foco de áudio e lifecycle precisam ser avaliados no host. Não basta selecionar `mode: audio`.

## Início rápido e ciclo de vida

Importe somente a API pública:

```dart
import 'package:lumio_player/lumio_player.dart';
```

Exemplo mínimo com abertura após o primeiro frame, tratamento assíncrono de falhas e liberação do controller:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lumio_player/lumio_player.dart';

void main() => runApp(const MaterialApp(home: PlayerPage()));

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _player = LumioPlayerController(
    configuration: const LumioPlayerConfiguration(
      engine: LumioPlaybackEngine.automatic,
      autoPlay: true,
    ),
  );
  String? _feedback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  Future<void> _open() async {
    try {
      await _player.open(LumioSource.network(Uri.parse(
        'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
      )));
    } on LumioPlayerError catch (error) {
      if (mounted) setState(() => _feedback = 'Falha: ${error.code}');
    } catch (_) {
      if (mounted) setState(() => _feedback = 'Não foi possível abrir a mídia.');
    }
  }

  Future<void> _release() async {
    try {
      await _player.dispose();
    } catch (_) {
      // Não há UI restante para relatar uma falha de encerramento.
    }
  }

  @override
  void dispose() {
    unawaited(_release()); // State.dispose é síncrono.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Lumio Player')),
    body: Column(
      children: [
        LumioPlayerView(controller: _player),
        if (_feedback != null) Text(_feedback!),
      ],
    ),
  );
}
```

Essa URL é a mídia de demonstração usada pelo exemplo e contata um servidor externo; substitua-a por uma fonte de teste sob seu controle quando necessário.

### `open` antes ou depois de montar a view?

- **Padrão recomendado:** monte `LumioPlayerView` primeiro e inicie `open` no callback pós-frame, como acima. Serve também para áudio.
- **Nativo explícito:** a criação de textura/readiness não depende de montar a view; é possível abrir antes e apresentar a view depois.
- **WebView ou `automatic`:** se iniciar `open` antes de montar, monte a view **enquanto o Future ainda está pendente**. O fallback pode precisar da plataforma WebView para completar o handshake/metadados. Nunca faça `await open()` como pré-condição para construir a view.
- Não esconda a view até `state.initialized == true`; a própria view monta a superfície durante a inicialização e sobrepõe placeholder/loading.
- Monte apenas **uma superfície por controller**. Uma WebView não pode estar em duas views simultâneas.

O controller pertence ao chamador, não à view. Remover a view não chama `dispose()` automaticamente. `LumioPlayerController.dispose()` retorna `Future<void>`, é idempotente e invalida eventos antigos; fora de `State.dispose`, prefira `await controller.dispose()`. Para WebView, remova também o widget: não existe um método cross-platform de descarte da plataforma em `WebViewController`.

`open`, comandos, `retry` e troca de engine são assíncronos. Não deixe seus Futures sem tratamento. `open` concluído significa inicialização de mídia, **não garantia de autoplay bem-sucedido**, especialmente na WebView.

## Fontes, áudio e live

### Rede e formato explícito

```dart
final hls = LumioSource.network(
  Uri.parse('https://media.example.com/live/playlist'),
  format: LumioMediaFormat.hls,
);
final progressive = LumioSource.network(
  Uri.parse('https://media.example.com/video.mp4'),
  format: LumioMediaFormat.progressive,
);
```

`media.example.com` é ilustrativo. Use `hls` para manifests sem extensão: na WebView, `auto` identifica HLS pelo pathname terminado em `.m3u8`. Hints não convertem mídia nem adicionam codecs.

Headers HTTP são suportados **somente no Android nativo**, aplicados via Media3 a manifests, segmentos e mídia progressiva:

```dart
final authenticated = LumioSource.network(
  Uri.parse('https://media.example.com/private/stream.m3u8'),
  headers: {'Authorization': 'Bearer <TOKEN_OBTIDO_COM_SEGURANCA>'},
  format: LumioMediaFormat.hls,
);
```

Não coloque credenciais reais em código/documentação. No iOS e WebView, headers não vazios são **rejeitados**, não silenciosamente ignorados. O iOS não usa a chave não pública `AVURLAssetHTTPHeaderFieldsKey`. Para esses caminhos, avalie URLs assinadas ou autenticação no servidor, sem supor que cookies sejam transportados entre engines. Em RTSP Android, headers HTTP arbitrários não se aplicam; autenticação é a do transporte/URI RTSP.

### Arquivo e asset

```dart
final file = LumioSource.file('/caminho/absoluto/no/dispositivo/video.mp4');
final asset = LumioSource.asset('assets/media/demo.mp4');
final packageAsset = LumioSource.asset(
  'assets/media/demo.mp4',
  package: 'meu_pacote_de_midias',
);
```

O arquivo está no **dispositivo**, não na máquina de desenvolvimento. Android aceita caminho, `file://` e `content://`; iOS aceita caminho absoluto ou URL `file://` legível. O plugin não abre seletor de arquivos nem solicita permissões. A opção `package` gera a chave `packages/<package>/<asset>`.

Para o asset do app, declare no `pubspec.yaml` consumidor:

```yaml
flutter:
  assets:
    - assets/media/demo.mp4
```

Esses exemplos são fontes alternativas; abra uma por vez com `await controller.open(fonte)` e tratamento de erro. A WebView **não reproduz arquivos locais nem Flutter assets de mídia**; carregar seu HTML empacotado não muda essa restrição.

### Áudio e transmissões ao vivo

```dart
final audioController = LumioPlayerController(
  configuration: const LumioPlayerConfiguration(
    mode: LumioPlaybackMode.audio,
    engine: LumioPlaybackEngine.native,
  ),
);
final liveController = LumioPlayerController(
  configuration: const LumioPlayerConfiguration(mode: LumioPlaybackMode.live),
);
```

Monte a view e abra uma fonte compatível como no início rápido; descarte cada controller quando deixar de usá-lo. Áudio usa a mesma API e apresenta placeholder de áudio, sem exigir dimensões de vídeo. Isso não seleciona faixas nem remove automaticamente o vídeo da fonte. Na WebView, vídeo e áudio usam o mesmo elemento HTML `<video>`.

`live` informa a intenção de live e também pode ser detectado pelo backend. Não transforma VOD em live nem garante baixa latência ou DVR. Os controles padrão ocultam o slider VOD e a escolha de velocidade em live e exibem somente um rótulo informativo em negrito (`AO VIVO` por padrão), sem ação de retorno ao vivo. Se necessário, ofereça uma ação própria que chame `controller.seekToLive()`. Duração desconhecida/indefinida aparece como zero, não como uma duração útil para seek.

`seekToLive()` exige inicialização e uma fonte/janela live adequada; não é um seek universal para qualquer fonte marcada `mode: live`:

- **Android:** verifica `isCurrentMediaItemLive` real do Media3 e chama `seekToDefaultPosition()`. O hint sozinho não torna VOD elegível.
- **iOS:** exige item pronto e range seekable válido. Usa o fim do último range menos **0,5 s**, limitado ao início do range. Aceita duração indefinida ou janela deslizante finita explicitamente indicada como live; VOD comum é rejeitado com `LumioPlayerError` de código **`unsupported_live_seek`**.
- **WebView:** usa `hls.liveSyncPosition` quando disponível ou o fim do último range seekable menos **0,5 s**, limitado ao range. Depende de live detectado/indicado e range disponível; falhas do comando HTML são reportadas pela bridge.

Trate o Future como nos demais comandos. A posição escolhida depende da janela e política do backend; não há garantia de latência zero, seek exato no extremo do stream ou DVR completo.

## Matriz de suporte

“Sim” abaixo significa que há um caminho implementado; **container, codec, perfil, dispositivo, servidor e políticas do sistema ainda determinam a reprodução real**.

| Recurso | Android nativo / Media3 | iOS nativo / AVPlayer | WebView móvel |
| --- | --- | --- | --- |
| Rede HTTP(S) | Sim | Sim | Sim, sem credenciais na URI |
| Arquivo local | Sim; inclui `content://` com concessão | Sim; absoluto/`file://` | Não |
| Flutter asset de mídia | Sim | Sim | Não |
| Headers HTTP personalizados | Sim para HTTP(S) | Implementados via options de `AVURLAsset`; veja ressalvas abaixo | Não; rejeitados |
| Progressivo, vídeo e áudio | Conforme extractor/decoder do sistema | Conforme AVFoundation | Conforme elemento HTML/browser |
| HLS, VOD e live | Sim | Sim | HLS nativo preferido; HLS.js se MediaSource/codecs disponíveis |
| DASH | Sim, módulo Media3 | Não; rejeitado | Não; sem engine DASH |
| RTSP | Sim, módulo Media3; não confundir com HTTP headers | Não; rejeitado | Não |
| Hint `auto` | Detecção Media3 | Detecção AVFoundation | HLS por `.m3u8`; demais via browser |
| Buffer detalhado | `DefaultLoadControl` | Preferência de buffer, sem thresholds rígidos | Gerido pelo browser/HLS.js |
| `seekToLive()` | Posição default do item realmente live | Último range live válido menos 0,5 s | Live sync HLS.js ou último range menos 0,5 s |
| `enableDecoderFallback` / `liveTargetOffset` | Aplicados via Media3 | Aceitos, diagnosticados como não aplicados | Ignorados |
| Volume | Ganho 0–1 | Ganho 0–1 | Android: conforme browser; iOS: somente mute/unmute (0/1) |
| Velocidade | Comando nativo | Comando nativo | Sujeita às restrições do browser |
| DRM/configuração de licença | Não implementado | Não implementado | Não implementado |
| Codecs adicionais empacotados | Não | Não | Não |

A enumeração `LumioMediaFormat` descreve **formatos/transporte**, não uma lista de codecs. MP4, por exemplo, não garante que HEVC, AV1 ou qualquer perfil H.264 seja reproduzível. Não há decoder próprio, FFmpeg, instalação de codecs nem conversão de mídia. DRM, aquisição/renovação de licença, FairPlay, Widevine e configuração EME não são expostos pela API, mesmo que as tecnologias subjacentes tenham recursos relacionados.

### HLS da WebView, CORS e rede

`assets/web/player.html`, `player.js` e **HLS.js 1.6.13** são empacotados como assets. **Não há carregamento de scripts por CDN em runtime.** A mídia e seus recursos continuam sendo baixados dos servidores indicados pela fonte/manifests.

HLS.js precisa de MediaSource, codecs compatíveis e CORS em **todos os manifests, segmentos e chaves**, inclusive redirecionamentos. A origem da página local/WebView deve ser considerada na configuração do servidor. Não suponha que uma URL funcionando no player nativo vá funcionar via JavaScript. HLS nativo é preferido quando o browser o reconhece; nesse caso, regras do sistema/browser continuam aplicáveis. Autoplay, mixed content e políticas HTTPS/cleartext podem bloquear a reprodução. O fallback não contorna CORS, autenticação, DRM ou codecs ausentes.

## API, configuração e controles

A API pública é exportada por `lib/lumio_player.dart`: models, `LumioPlayerController`, `LumioPlayerView` e `LumioPlayerControls`. Bridge nativa e engine WebView são detalhes internos.

| Operação do controller | Comportamento |
| --- | --- |
| `open(source)` | Substitui a fonte e espera inicialização |
| `play()` / `pause()` | Exigem mídia inicializada |
| `seekTo(Duration)` | Posição não negativa; backend decide limites/seek real |
| `seekToLive()` | Retorna à posição live do backend quando há fonte/janela live compatível |
| `setVolume(double)` | Finito, entre 0 e 1; iOS WebView aceita somente 0/1 |
| `setSpeed(double)` | Dart exige finito e positivo; limites específicos abaixo |
| `setLooping(bool)` | Altera repetição e preserva opção em reaberturas |
| `setEngine(engine)` | Troca engine; tenta restaurar posição VOD e estado de reprodução |
| `retry()` | Reabre a fonte; tenta restaurar posição VOD; em live não restaura posição anterior |
| `diagnostics()` | Snapshot sob demanda, com sanitização de strings |
| `dispose()` | Libera recursos e rejeita novas operações |

Comandos são serializados. Uma falha não envenena a fila dos comandos seguintes. Os comandos despachados à engine **nativa** têm espera limitada por `configuration.initializationTimeout`; timeout produz `LumioPlayerError(code: 'command_timeout', ...)`. A WebView mantém seus próprios limites de operação. Isso limita a espera, não cancela o método já em execução na plataforma.

Retry, troca de engine e fallback preservam a **intenção explícita de reprodução** (`play`/`pause`), não apenas `state.playing`: uma reprodução em buffering não é confundida com pausa, e retry após pausa permanece pausado. Uma nova chamada `open` reaplica `configuration.autoPlay`. A restauração de posição VOD/continuidade ainda é uma tentativa, não uma transição sem interrupções nem preservação garantida de sessão/autenticação.

Configuração é imutável: para alterar `mode`, buffer, timeout ou opções de decoder/live, crie outro controller, desmonte a superfície anterior e descarte o anterior.

### Defaults da API Dart

| Opção | Default |
| --- | --- |
| `engine` | `LumioPlaybackEngine.automatic` |
| `mode` | `LumioPlaybackMode.video` |
| `autoPlay` | `true` |
| `looping` | `false` |
| `volume` / `speed` | `1` / `1` |
| `initializationTimeout` | 25 segundos |
| `allowAutomaticFallback` | `true` |
| `enableDecoderFallback` | `true` — aplicado somente no Android nativo |
| `liveTargetOffset` | `null` — opcional; `Duration` entre 0 e 60 segundos |
| `buffer.minimum` / `buffer.maximum` | 15 / 50 segundos |
| `buffer.playback` / `buffer.rebuffer` | 2500 ms / 5 segundos |

São os defaults **públicos Dart**; os parsers nativos chamados diretamente têm defaults próprios. A validação Dart exige `0 <= playback/rebuffer <= minimum <= maximum`, volume válido, velocidade positiva e timeout positivo.

- Android aplica buffer em `DefaultLoadControl`; isso não garante reprodução sem stalls nem latência fixa.
- iOS mapeia maximum (ou minimum se maximum estiver ausente no protocolo) para `preferredForwardBufferDuration`. É uma **preferência**, não teto/piso rígido. Os thresholds playback/rebuffer ficam em diagnósticos, mas não são impostos por AVPlayer.
- WebView não aplica a configuração detalhada de buffer.
- iOS aceita velocidade **0.01–4**; WebView **0.25–4**; Android valida velocidade finita positiva, sujeita ao player. A faixa comum de entrada é **0.25–4**, não uma garantia de execução em toda mídia/dispositivo.
- WebView aceita timeout de inicialização entre **1 e 120000 ms**, embora a validação pública Dart só exija valor positivo.

### Decoder fallback e offset live — Android

`enableDecoderFallback` configura `DefaultRenderersFactory.setEnableDecoderFallback` para tentar outros **decoders disponíveis no dispositivo** quando a inicialização de um decoder falha. É diferente do fallback de engine controlado por `allowAutomaticFallback`: não muda para WebView e **não empacota software decoder, FFmpeg ou codecs adicionais**.

`liveTargetOffset` é opcional e aceita `Duration` de **0 a 60 segundos**, inclusive. No Android, vira `MediaItem.LiveConfiguration` com target offset em milissegundos. É um alvo de reprodução live sujeito ao stream e ao Media3, não uma garantia de latência.

```dart
const liveConfiguration = LumioPlayerConfiguration(
  mode: LumioPlaybackMode.live,
  enableDecoderFallback: true,
  liveTargetOffset: Duration(seconds: 3),
);
```

No **iOS**, as duas opções são aceitas/validadas e preservadas em diagnósticos, mas **não aplicadas**: aparecem em `unsupportedSettings`, junto dos thresholds de buffer não suportados. Na **WebView**, são ignoradas. Não anuncie equivalência dessas opções entre plataformas.

### Volume na WebView iOS

Na WebView iOS, `HTMLMediaElement.volume` é efetivamente somente leitura. Por isso, **`controller.capabilities.volumeControl == false`** nessa combinação: significa ausência de controle de ganho fracionário, não ausência de mute.

- `setVolume(0)` silencia e `setVolume(1)` reativa o áudio via `video.muted`.
- Valores intermediários, como `setVolume(0.4)`, são rejeitados pelo controller com `LumioPlayerError(code: 'unsupported_volume_gain', ...)`.
- Ao abrir/trocar para WebView iOS com ganho fracionário desejado, o controller registra um **warning `unsupported_volume_gain`** e preserva esse ganho para eventual retorno à engine nativa. A WebView não aplica esse ganho; seu estado reflete o volume efetivo/mute.
- Um comando explícito de volume bem-sucedido (0 ou 1) substitui o ganho desejado. Depois disso, retornar ao nativo usa o novo valor, não o ganho anterior.

Consulte `capabilities.volumeControl` antes de oferecer slider de ganho e trate a rejeição dos comandos. Os controles de mute/unmute continuam disponíveis.

### UI entregue

Os controles próprios do Lumio vêm habilitados por padrão. São widgets Flutter sobre os backends nativos, não os controles visuais do sistema. `LumioPlayerView` mantém estado de interação (gestos, zoom e timer); o controller continua responsável pela reprodução. `LumioPlayerControls` também pode ser usado separadamente.

```dart
LumioPlayerView(
  controller: player,
  controlsConfiguration: const LumioControlsConfiguration(
    layout: LumioControlsLayout.automatic,
    placement: LumioControlsPlacement.below, // Ou overlay sobre a mídia.
    liveLabel: 'AO VIVO',
    playingLabel: 'REPRODUZINDO',
    pausedLabel: 'PAUSADO',
    loadingLabel: 'CARREGANDO',
    simplifiedControl: LumioSimplifiedControl.speed,
    showStatus: true, // REPRODUZINDO/PAUSADO ou AO VIVO.
    showFullscreen: true,
    playbackSpeeds: [1, 2, 3, 4], // Sequência de toque; pode usar apenas [1, 2].
    showPlayPause: true,
    showProgress: true,
    showSpeed: true,
    showSkipButtons: true,
    showVolume: true, // Botão de silenciar/reativar áudio.
    showVolumeSlider: false, // Opt-in em linha secundária do completo; exige showVolume.
    showPlaylistNavigation: true, // Master dos botões de playlist.
    showPreviousItem: true, // Subordinado a showPlaylistNavigation.
    showNextItem: true, // Independente de showPreviousItem.
    showSettings: false, // Use true para exibir o seletor native/webview/automatic.
    showTime: true, // Tempo dos vídeos gravados.
    showLiveTime: false, // Opt-in: liveLabel · tempo; também exige showTime.
    doubleTapSeek: true,
    seekInterval: Duration(seconds: 10),
    holdToSpeed: true,
    holdSpeed: 2,
    enableZoom: true,
    maxZoom: 4,
    compact: true, // Opt-in; default false.
    compactDelay: Duration(seconds: 5), // Default de inatividade.
    progressColor: Color(0xFF9976BD),
    showLoader: true,
  ),
);
```

- `layout` usa `LumioControlsLayout.automatic` por padrão: escolhe live quando `state.live` ou `controller.configuration.mode == LumioPlaybackMode.live`; caso contrário, usa o completo. Mídia live **sempre sobrepõe** um pedido de layout completo ou simplificado. `LumioControlsLayout.live` também pode ser escolhido explicitamente.
- **Completo** (`complete`): slider ocupa toda a largura; com um intervalo de **8 px** após o widget do slider, aparecem status `REPRODUZINDO`/`PAUSADO` à esquerda e tempo à direita. A linha seguinte reúne play/pause, skips, mute/unmute, velocidade e navegação opcional de playlist à esquerda, com fullscreen fixo à direita. Essa linha **nunca quebra em múltiplas linhas**: os slots dos botões têm entre **32 e 40 px**, com ícones de até **24 px**, e a velocidade usa um slot do mesmo tamanho, inclusive para velocidades personalizadas como `1.5x` e `4x`. As oito ações, incluindo anterior/próximo e fullscreen, cabem em larguras de 320, 360 e 390 px. Em larguras extremamente estreitas, a área de ações à esquerda tem **rolagem horizontal**, sem mover o fullscreen.
- **Simplificado** (`simplified`): play/pause à esquerda, coluna expandida central com slider e status/tempo 8 px abaixo do widget do slider, e uma única ação à direita. Há **8 px de espaço horizontal** entre a coluna central e cada botão lateral visível. `simplifiedControl` escolhe `speed` (default) ou `volume`. Não inclui skips nem fullscreen, mesmo com as respectivas flags ligadas. A opção volume oferece somente mute/unmute, sem slider de ganho.
- **Live** (`live`): `liveLabel` (default `AO VIVO`) em **negrito** à esquerda, mute/unmute e fullscreen à direita; não inclui ponto vermelho, play/pause, velocidade nem slider de progresso. O rótulo é somente informativo: não tem `InkWell`, callback de toque nem tooltip `Return to live` e não chama `seekToLive()`. `showStatus` controla o rótulo; com `showLiveTime: true` e `showTime: true`, aparece `liveLabel · tempo`, inclusive quando `showStatus: false`. `showLiveButton` está **deprecated**, mantido como no-op para compatibilidade: `true` e `false` produzem a mesma UI. Para retorno ao vivo em uma UI própria, chame `controller.seekToLive()` explicitamente.
- Título opcional em todos os layouts: informe `title` na view/controles ou na fonte e mantenha `showTitle: true`. Settings, estatísticas e retry aparecem em linha secundária quando habilitados/aplicáveis. A navegação de playlist integra a linha de ações somente no completo; não aparece no simplificado nem no live, mesmo com as flags habilitadas.
- Por padrão, o thumb do progresso acompanha o arrasto localmente e faz seek somente ao soltar. `previewWhileScrubbing: true` habilita a prévia no próprio vídeo durante o arraste, somente em VOD seekable. A reprodução é pausada temporariamente se estava tocando; ao soltar, o último alvo é enviado antes de retomar. Vídeos que já estavam pausados permanecem pausados. O thumb continua seguindo o dedo, sem saltar com os eventos do player.
- `scrubPreviewInterval` controla a frequência máxima dos comandos de prévia (default **150 ms**, obrigatório ser positivo). Posições intermediárias são substituídas pela mais recente, com no máximo um comando de prévia aguardando resposta; o seek final não espera a janela do throttle. Não são criados outro player nem thumbnails. Cancelamentos, desmontagem, troca de mídia/controller e desabilitação das opções invalidam comandos obsoletos; a retomada só ocorre se a mesma sessão ainda tiver ownership e a mídia continuar válida. Mudanças discretas de acessibilidade também são finalizadas, sem depender de um gesto de soltura. Durante a prévia, o loader central fica oculto para não cobrir os frames; buffers fora dela continuam mostrando o loader normalmente.
- O botão de velocidade avança a cada **toque** pela sequência `playbackSpeeds`, por padrão **1x → 2x → 3x → 4x → 1x**, sem abrir menu ou lista. A sequência personalizada respeita a ordem configurada, com valores únicos de 0.25 a 4, incluindo fracionários: `[.25, 3.5]` cicla **0.25x → 3.5x → 0.25x**. Se a velocidade atual foi definida externamente e não está na sequência, o próximo toque aplica o primeiro valor. **Pressionar e segurar o botão** faz um reset **permanente para 1x**, mesmo se a sequência não contiver `1`; soltar não restaura a velocidade anterior nem avança a sequência. O botão tem altura de **40 px** e fonte de **16 px**, com formatação sem `.0`: `1x`, `2x`, etc., ou `1.5x` quando personalizado. Toque e long press ficam desabilitados antes da inicialização, durante transições e em estado de erro; o botão fica oculto em live. Em vídeos gravados, `showSpeed: false` oculta somente o botão, sem desabilitar o gesto de velocidade sobre a mídia; cada opção é independente.
- Duplo toque confirmado na metade esquerda volta 10 segundos; na direita avança 10 segundos (`seekInterval` configurável), limitado ao intervalo VOD conhecido. Uma pílula no lado correspondente mostra seta e o total solicitado na sequência: `+10s`, `+20s`… ou `-10s`, `-20s`… O total visual acumula o intervalo configurado, mesmo quando a posição efetiva é limitada pelo começo/fim do vídeo. Mudar de direção inicia uma nova contagem. Após 900 ms sem interação, a pílula desaparece e zera o total; enquanto há um ponteiro pressionado, esse prazo fica suspenso. Troca de fonte/item/controller/engine, desabilitação do gesto e estados indisponíveis também limpam o feedback. Um segundo toque cancelado não executa seek.
- Pressionar e segurar **sobre a mídia** altera a velocidade **temporariamente**, conforme o estado atual: de **1x**, aplica `holdSpeed` (default **2x**); de **2x ou mais**, aplica **1x**, independentemente de `holdSpeed`. Assim, com o default, **1x → 2x**, **2x → 1x**, **3x → 1x** e **4x → 1x** enquanto o gesto estiver ativo. Velocidades personalizadas **abaixo de 2x e diferentes de 1x**, como **0.75x** e **1.5x**, não iniciam hold nem mostram overlay. Com `holdSpeed: 3`, somente um hold iniciado em **1x** aplica **3x**; velocidades a partir de **2x** continuam usando **1x** temporário. O overlay mostra o alvo da sessão em uma pílula arredondada no topo, com ícone de velocidade e a mesma formatação do botão, sem `.0` (`2x`, `1x` ou `3x`). Soltar/cancelar restaura a velocidade anterior, respeitando ownership da sessão e revisão dos comandos para não sobrescrever uma alteração mais recente do desenvolvedor, inclusive durante corridas de confirmação nativa ou auto-advance da playlist. Esse gesto temporário é distinto do **reset permanente para 1x no botão de velocidade**.
- Zoom/pan por pinça, opcional e limitado a 4x, somente sobre a mídia. O zoom reseta ao trocar de item/fonte.
- Modo compacto é **opt-in** (`compact: false` por padrão). Com `compact: true`, oculta os demais controles após **5 segundos** de reprodução sem interação (`compactDelay` configurável), mantendo somente a linha de progresso (`lumio-compact-progress`). No modo sobreposto, ela tem **4 px de altura** e fica encostada na borda inferior da superfície; no modo abaixo da mídia, mantém **2 px** no topo da faixa compacta. O slider interativo (`lumio-progress`) é desmontado nesse modo e volta ao revelar os controles. **Toque simples sobre a mídia alterna entre controles visíveis e compactados**; com `compact: false`, apenas revela, sem ocultar. Revelar reinicia o prazo de inatividade; notificações de posição não o reiniciam. A ocultação automática só ocorre durante reprodução pronta, sem buffering. Um toque pode compactar manualmente a mídia pronta mesmo pausada; a próxima atualização de estado pausado volta a revelar os controles. Antes de estar pronta, durante transições, erro ou buffering, os controles permanecem visíveis. Cliques nos controles, duplo toque de seek, hold e pinça não acionam a alternância da superfície.
- O slider de volume aparece em uma **linha secundária abaixo das ações**, somente no completo (incluindo `automatic` com mídia não-live): exige `showVolume: true`, `showVolumeSlider: true` e engine com ganho disponível; WebView iOS apresenta somente mute/unmute. Live e simplificado nunca mostram slider de volume, mesmo com `showVolumeSlider: true`.
- Botões anterior/próximo são opcionais: `showPlaylistNavigation: true` (default) só os mostra quando existe uma playlist e o layout é completo (ou `automatic` com vídeo). O simplificado e o live nunca exibem esses botões. `showPreviousItem` e `showNextItem` (ambos `true` por padrão) permitem ocultar cada botão independentemente: por exemplo, `showPreviousItem: false, showNextItem: true` mostra somente próximo. Ambos são subordinados a `showPlaylistNavigation`; com o master em `false`, nenhum aparece, mesmo com as flags individuais em `true`. Nos extremos da fila, a ação visível indisponível fica desabilitada. Flags de skip, live, retry e escolha de engine são independentes, respeitando a composição de cada layout.
- `showStatus` e `showFullscreen` são `true` por padrão. `showTitle`, `showTime`, `showRetry` e `showLoader` também podem ser desligados. `showLiveButton` é mantido somente para compatibilidade e não altera o comportamento.
- `liveLabel`, `playingLabel`, `pausedLabel` e `loadingLabel` aceitam **somente `String`**, sem builders ou estilos por label. Os defaults são `AO VIVO`, `REPRODUZINDO`, `PAUSADO` e `CARREGANDO`; buffering/carregamento usa `loadingLabel`. Durante a prévia de arraste e o seek final, o status permanece em `pausedLabel`, sem alternar com os eventos internos de buffering; ao finalizar, volta a refletir o estado real.
- `placement` é independente do layout dos controles: `LumioControlsPlacement.below` (default) mantém os controles externos abaixo da mídia; `overlay` os posiciona no fundo de um `Stack` sobre a mídia, sem descontar sua altura do viewport de vídeo. O placement também é preservado no modo compacto e no fullscreen. Em fullscreen sobreposto, os controles expandidos usam padding horizontal de 3% da largura, limitado entre 20 e 40 px, somado aos insets laterais de área segura ainda não consumidos pelo host. O vídeo e a barra compacta continuam ocupando toda a largura; o layout inline mantém seu espaçamento anterior. As chaves de placement são `lumio-controls-below` no wrapper externo e `lumio-controls-overlay` no `Positioned(bottom: 0, left: 0, right: 0)`; as chaves da superfície permanecem iguais. Interagir com os controles não dispara os gestos de seek/velocidade da mídia.
- `progressColor`, `backgroundColor`, `foregroundColor` e `titleStyle` personalizam o visual escuro. Em `below`, o fundo mantém exatamente `backgroundColor` (preto opaco por padrão), inclusive seu alpha quando personalizado. Em `overlay`, o fundo é translúcido: preserva o RGB e multiplica o alpha original por **0.65**, inclusive no modo compacto. Assim, uma cor opaca fica com alpha 0.65; uma cor com alpha 0.5 fica com alpha 0.325.

Para desligar todos os controles e gestos, use `controls: false` ou `LumioControlsConfiguration(enabled: false)`. O loader é independente; desligue com `showLoader: false` se desejar nenhuma UI de carregamento. No live, os reconhecedores de duplo toque para seek e long press para velocidade não são registrados: o toque simples alterna o compacto imediatamente, sem esperar a janela de duplo toque. Nos vídeos, essa janela continua necessária para distinguir os gestos. Zoom pode ser habilitado independentemente. A engine WebView permanece montada durante o carregamento. `fit` funciona na textura nativa e na WebView, sem reabrir a fonte.

### Prévia de vídeo durante o arraste (opt-in)

```dart
LumioPlayerView(
  controller: controller,
  controlsConfiguration: const LumioControlsConfiguration(
    previewWhileScrubbing: true,
    scrubPreviewInterval: Duration(milliseconds: 150),
  ),
)
```

A prévia depende do tempo de seek/decodificação da engine e da rede; não é frame stepping nem garantia de resposta instantânea ou precisão uniforme entre plataformas. No iOS nativo, o seek usa tolerância zero e seu Future aguarda a conclusão reportada pelo AVPlayer. No Android nativo, a prévia usa `seekToPreview`: aplica `SeekParameters.EXACT` temporariamente e aguarda `onRenderedFirstFrame` antes de liberar o próximo alvo coalescido. Há deadline de **2 segundos**: se não chegar callback, o ACK confirma apenas aceitação, registra um warning e incrementa `previewSeekTimeoutCount` nos diagnostics. Seeks normais continuam com ACK imediato. A notificação não comprova timestamp exato nem composição da textura Flutter. Na WebView, o ACK continua indicando aceitação do comando; não garante que um novo frame tenha sido apresentado. O seek final precede o comando de retomada, mas a apresentação visual pode ocorrer depois, conforme o buffering.

`play`, `pause` e `seekTo` aceitam o parâmetro opcional `bool Function()? isCurrent`. O player usa essa guarda para revalidar a sessão quando o comando chega à frente da fila, evitando que ele atue numa nova mídia. Se a guarda rejeitar, a operação lança `StateError`. Chamadas existentes sem a guarda continuam funcionando; **subclasses customizadas que sobrescrevem esses métodos precisam aceitar o novo parâmetro named**. `LumioPlayerControls.onScrubbingChanged` permite que hosts com UI própria acompanhem o início/fim da prévia; o controller continua pertencendo ao host.

### Exemplos de variantes

```dart
// VOD completo; uma fonte live ainda tem prioridade sobre este layout.
LumioPlayerView(
  controller: player,
  title: 'Vídeo gravado',
  controlsConfiguration: const LumioControlsConfiguration(
    layout: LumioControlsLayout.complete,
    showVolumeSlider: true,
  ),
);

// Simplificado com velocidade: play | progresso + status/tempo | 1x.
LumioPlayerView(
  controller: player,
  controlsConfiguration: const LumioControlsConfiguration(
    layout: LumioControlsLayout.simplified,
    simplifiedControl: LumioSimplifiedControl.speed,
  ),
);

// Simplificado com mute/unmute, sem velocidade, skips ou fullscreen.
LumioPlayerView(
  controller: player,
  controlsConfiguration: const LumioControlsConfiguration(
    layout: LumioControlsLayout.simplified,
    simplifiedControl: LumioSimplifiedControl.volume,
  ),
);

// Live explícito. Em automatic, estado ou mode live já seleciona esta UI.
LumioPlayerView(
  controller: liveController,
  title: 'Transmissão ao vivo',
  controlsConfiguration: const LumioControlsConfiguration(
    layout: LumioControlsLayout.live,
    placement: LumioControlsPlacement.overlay,
    liveLabel: 'AO VIVO', // Texto informativo, sem ação de retorno ao vivo.
    showLiveTime: true,
  ),
);
```

`showSpeed`/`showVolume` continuam controlando a ação escolhida no simplificado: ocultá-la não faz aparecer a outra como substituta. `showStatus: false` oculta o status, não o tempo; `showTime: false` oculta o tempo, não o status.

### Fullscreen e ownership da superfície

`LumioPlayerView` oferece fullscreen embutido nos layouts completo e live, quando `showFullscreen: true`, preservando `controlsConfiguration.placement` (`below` ou `overlay`): desmonta a superfície inline antes de montar uma nova superfície em uma rota fullscreen. Durante a rota, a view inline mantém apenas o espaço reservado. Ao sair, espera a animação reversa e a desmontagem da rota (`route.completed`) antes de restaurar a superfície inline, preservando o mesmo controller. **Não são montadas duas WebViews simultaneamente** com o mesmo controller. O app continua responsável pelo ciclo de vida do controller; a navegação fullscreen não transfere sua responsabilidade de `dispose`.

Para controlar fullscreen no host, informe `onToggleFullscreen` (`VoidCallback?`) e `isFullscreen` (`bool`, default `false`) à view. O callback substitui a navegação embutida; o host deve atualizar `isFullscreen`, cuidar da entrada/saída e mover a superfície sem duplicá-la. O fullscreen embutido não força orientação nem altera a UI de sistema (barras/ modo imersivo). Orientação, UI de sistema e políticas de navegação customizadas ficam sob responsabilidade do host.

```dart
LumioPlayerView(
  controller: player,
  isFullscreen: hostIsFullscreen,
  onToggleFullscreen: toggleHostFullscreen,
);

// Controles separados não possuem uma rota/superfície para mover.
LumioPlayerControls(
  controller: player,
  isFullscreen: hostIsFullscreen,
  onToggleFullscreen: toggleHostFullscreen,
  configuration: const LumioControlsConfiguration(
    layout: LumioControlsLayout.complete,
    showFullscreen: true,
  ),
);
```

Nos controles standalone, o botão só aparece se houver callback: não há ícone desabilitado sugerindo uma ação indisponível. `showFullscreen: false` oculta o botão mesmo com callback; o layout simplificado não o inclui por design. Fullscreen não implica Picture-in-Picture nem suporte de reprodução em background.

### Superfície de mídia e captura

`LumioPlayerView.surfaceCaptureKey` aceita uma `GlobalKey` para uma `RepaintBoundary` que envolve somente a mídia, sem os controles. O host pode capturar a textura nativa por essa boundary; WebViews precisam de captura pela plataforma/HTML e continuam sujeitas a CORS. A chave acompanha a rota de fullscreen sem duplicar a superfície.

`mediaWrapper: (context, media) => ...` permite ao host envolver somente a mídia com zoom ou gestos de navegação. O wrapper deve preservar os limites finitos da área do player. Os controles ficam fora dele, evitando que sejam ampliados ou saiam da tela ao aplicar zoom. Para wrappers de zoom próprios, mantenha `enableZoom: false` nos controles do Lumio para não registrar duas implementações de zoom concorrentes.

### Enquadramento: fit, proporção e área disponível

```dart
LumioPlayerView(
  controller: player,
  fit: BoxFit.contain,
  aspectRatio: 16 / 9,
);
```

| Fit | Comportamento |
| --- | --- |
| `BoxFit.contain` (padrão) | Mostra toda a imagem, preservando proporção; pode deixar faixas |
| `BoxFit.cover` | Preenche a área, preservando proporção e cortando as bordas necessárias |
| `BoxFit.fill` | Preenche esticando; pode distorcer a imagem |
| `BoxFit.fitWidth` / `fitHeight` | Ajusta pela largura/altura, preserva proporção e recorta excedentes |
| `BoxFit.none` | Sem escala, centralizado e recortado se necessário |
| `BoxFit.scaleDown` | Não amplia; reduz somente se necessário |

Sem `aspectRatio`, a superfície acompanha a proporção do vídeo (16:9 enquanto desconhecida). `aspectRatio` configura **a área da mídia**, não altera os pixels do vídeo. Com placement `below`, os controles somam altura externa; com `overlay`, não aumentam nem reduzem o viewport definido pela proporção. Serve para gravações e streams e pode mudar em runtime. Enquadramento e proporção são independentes.

Para ocupar toda a área restante da tela, forneça constraints finitas:

```dart
Expanded(
  child: LumioPlayerView(
    controller: player,
    layout: LumioVideoLayout.expand,
    fit: BoxFit.cover,
  ),
);
```

`expand` ocupa a área disponível e ignora `aspectRatio`: com `placement: LumioControlsPlacement.below`, desconta a altura dos controles; com `overlay`, a mídia ocupa todo o viewport e os controles ficam sobrepostos no fundo. Não é uma função de fullscreen/orientação. Dentro de um scroll vertical sem limite de altura, use `SizedBox(height: ...)` ou prefira o layout padrão; o plugin retorna erro descritivo quando falta altura finita.

Se `fit` for omitido, a view acompanha `controller.videoFit` (inicialmente `contain`), permitindo UI própria:

```dart
await player.setVideoFit(BoxFit.cover);
await player.setVideoFit(BoxFit.contain);
```

Um `fit` explícito na view tem precedência. Use uma única view por controller. A WebView aplica CSS/medidas equivalentes, incluindo ajustes de largura/altura após metadados e resize, e mantém o fit no fallback/playlist. Trocar fit não descarta a textura, reabre a URL nem perde a posição. Zoom continua sendo uma transformação separada.

### Playlist nativa

```dart
await player.openPlaylist(
  LumioPlaylist([
    LumioPlaylistItem(source: LumioSource.network(firstUri), title: 'Primeiro vídeo'),
    LumioPlaylistItem(source: LumioSource.asset('assets/second.mp4'), title: 'Segundo vídeo'),
  ], loop: true),
  initialIndex: 0,
);
await player.next();
await player.previous();
await player.selectPlaylistItem(1);
```

No Android, a fila usa `setMediaSources` do Media3. No iOS usa `AVQueuePlayer` com itens reais; o avanço normal acontece nativamente sem recriar o player ou a textura. A seleção manual preserva a intenção de play/pause. `playlist`, `currentItem`, `playlistIndex`, `hasNext`, `hasPrevious` e `title` estão disponíveis no controller; estado inclui `playlistIndex`/`playlistLength`. `looping` do item tem precedência sobre `LumioPlaylist.loop`. Não há promessa de transição gapless.

Na WebView, a sequência é coordenada pelo controller e abre cada fonte ao término da anterior, preservando o índice ao retornar ao nativo. Cada item precisa ser compatível com a engine; não há conversão automática de arquivos/assets para WebView.

### Headers simples

```dart
final player = LumioPlayerController(
  httpHeaders: {'Authorization': 'Bearer $token'},
);
await player.openUrl(url, headers: {'X-Client': 'lumio'}, title: 'Meu vídeo');
// Também aceita open(source, headers: ...) e openPlaylist(playlist, headers: ...).
```

Headers são mesclados sem distinção de caixa: **defaults do controller → fonte individual → headers da abertura**. Arquivos/assets não recebem headers. Na playlist cada item mantém sua própria configuração; segredos de todos os itens são ocultados nos logs/diagnósticos.

**Android e iOS nativos encaminham headers HTTP(S).** No iOS usamos a chave string `AVURLAssetHTTPHeaderFieldsKey`, também usada pelo `video_player`; ela não é uma constante pública documentada do SDK Apple. Headers são preservados por item na playlist e na reconstrução da fila. Nomes inválidos, valores com caracteres de controle e duplicatas case-insensitive são rejeitados no iOS sem expor credenciais. Não há garantia de propagação uniforme para redirects, manifests, segmentos HLS ou chaves: valide a autenticação no servidor/dispositivo e prefira URLs assinadas quando possível. WebView continua rejeitando headers personalizados. Não use headers sensíveis com redirects ou hosts de mídia não confiáveis.

### Áudio, lifecycle e recuperação live

```dart
final player = LumioPlayerController(
  configuration: const LumioPlayerConfiguration(
    mode: LumioPlaybackMode.live,
    audioPolicy: LumioAudioPolicy.preserveHost,
    allowBackgroundPlayback: false,
    volume: 0, // Exemplo: câmera vinculada a uma chamada.
  ),
  recovery: const LumioRecoveryConfiguration(
    enabled: true,
    maxAttempts: 3,
    initialDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 15),
    stallTimeout: Duration(seconds: 20),
    stablePlaybackDuration: Duration(seconds: 30),
  ),
);
```

- `preserveHost` é o default: não altera a sessão compartilhada iOS nem solicita foco Android. Para reprodução independente, selecione explicitamente `mixWithOthers` (iOS `.playback` com mistura; Android sem solicitar foco) ou `exclusive` (iOS `.playback` sem mistura; Android foco gerenciado pelo Media3). A sessão iOS nunca é desativada no dispose. Essas políticas são nativas; WebView segue as regras do browser/host.
- Por default, o controller pausa em `hidden`/`paused`/`detached` e retoma apenas se a intenção de playback continua ativa. `inactive` não causa pausa automática. `allowBackgroundPlayback: true` opta por não pausar, mas **não** cria serviço Android, capabilities iOS, media session, PiP nem suporte de background WebView.
- Recovery é **opt-in**, apenas live de rede com playback solicitado e app em foreground. Erros transitórios identificados e falta de avanço da posição disparam até três restarts, com delays padrão de 1, 2 e 4 segundos. Engine, volume, velocidade e intenção são preservados. Autenticação, fonte inválida, codec não suportado e erros desconhecidos sem sinal de transitoriedade não são repetidos automaticamente.
- O orçamento só é renovado depois de progresso sustentado, não ao receber `initialized`. Pausa, troca de fonte/engine, retry manual, background e dispose invalidam tentativas pendentes. Falha inicial de `open()` continua rejeitando seu Future; recovery depende de intenção de playback ativa.
- O watchdog é uma **heurística de posição**, não detecção de frame congelado nem medição de latência. Mantenha `LumioPlayerView` montado durante erro/reabertura, principalmente com WebView. Observe `transitioning`, estado e erros; o erro terminal permanece disponível.

A validação automatizada não substitui áudio, rede e profiling em dispositivos físicos. Use a [checklist de validação mobile](MOBILE_VALIDATION.md).

Os textos padrão da UI estão em inglês; este README em português não implica localização dos widgets. Para UI própria, use `controls: false`, observe o estado e trate os Futures dos comandos.

### Estatísticas para nerds (opt-in)

```dart
LumioPlayerView(
  controller: player,
  controlsConfiguration: const LumioControlsConfiguration(
    showStatistics: true,
  ),
);

// Também pode abrir por uma ação própria ou embutir em uma tela de debug:
await LumioStatisticsView.show(context, player);
// LumioStatisticsView(controller: player, showRawDetails: true)

final snapshot = await player.diagnostics();
```

O botão abre um painel atualizado a cada 2 segundos. A coleta periódica existe somente enquanto o painel está montado e a aplicação está ativa, sem requisições sobrepostas. O último snapshot é marcado como desatualizado se houver erro. Há ação de cópia do JSON sanitizado para suporte; não existe upload automático nem persistência de identificação.

| Dados | Android nativo | iOS nativo | WebView |
| --- | --- | --- | --- |
| Dispositivo/sistema | Fabricante, modelo, Android/API | Categoria do modelo e versão iOS, sem identificador único | Plataforma da engine; não fornece modelo físico |
| Codec/decoder | MIME/codec e decoder selecionado pelo Media3 | FourCC da faixa, quando AVFoundation disponibiliza; decoder não exposto | Codec declarado da variante HLS.js; decoder HTML não exposto |
| Vídeo/áudio | Resolução, FPS da faixa, bitrates, sample rate/canais nos detalhes | Resolução, FPS/bitrate de faixa quando disponíveis | Resolução, bitrate declarado de variante HLS.js |
| Frames | Contadores renderizados/descartados do decoder | Não disponível nesta implementação | Totais/descartados de `getVideoPlaybackQuality`, se suportado |
| Transmissão | Buffer e distância da borda live | Buffer e access logs: bitrate observado, bytes e stalls | Buffer e estado do browser |

O snapshot inclui engine ativa/solicitada, fallback, tipo de fonte, **hint** de formato, posição/duração, velocidade, volume, índice da playlist e código do último erro. Não trata hint como formato detectado, bitrate da faixa como throughput de rede ou FPS da faixa como FPS renderizado. Metadados iOS são carregados assincronamente pela API pública (iOS 15+); HLS/live pode não expô-los. `—` indica indisponível, não zero. As métricas do decoder representam sua instância; não são garantidas como contadores por sessão completa.

`showStatistics` vem **desabilitado por padrão**, independentemente do modo debug/release. URLs, paths de fonte e valores de headers conhecidos são sanitizados pelo controller. O relatório ainda contém modelo/SO e estado de reprodução; revise antes de compartilhar. Nenhum número de série, ID de publicidade ou identificador único é coletado.

## Engines e fallback

- `native`: sempre backend nativo, sem fallback automático.
- `webview`: força engine HTML de rede; fonte incompatível falha.
- `automatic`: começa em nativo e permite **uma tentativa de fallback para WebView por abertura/retry/seleção de engine**, quando habilitada e elegível.

`requestedEngine` é a escolha do consumidor; `controller.value.engine` é a engine efetivamente ativa. `capabilities` acompanha a engine ativa e a plataforma, não é uma sondagem de codec, URL ou servidor.

A elegibilidade exige `automatic`, `allowAutomaticFallback: true`, engine atual nativa, fallback ainda não usado e fonte HTTP(S) de rede sem headers nem credenciais na URI, não marcada DASH/RTSP. Primeiro são **excluídos códigos que contenham `network`, `http`, `auth` ou `io_`** (sem distinção de maiúsculas/minúsculas). Nos demais códigos, a classificação procura `codec`, `decoder`, `decoding`, `unsupported`, `format`, `render` ou `timeout`. Não analisa a mensagem nem usa `recoverable` como critério.

**Não é mecanismo de recuperação de rede ou autenticação.** Erros comuns de conexão, HTTP 401/403 e autorização não são uma justificativa para mudar engine; o app deve corrigir conectividade, URL, token ou servidor. Não existe loop automático de retry.

O timeout conhecido Media3 `ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT` agora é **excluído**, apesar de conter `timeout`. Já o timeout genérico **`initialization_timeout` continua elegível**, se todos os requisitos forem atendidos. A classificação ainda é textual: um código genérico não permite inferir a causa real como rede ou decoder. Outros erros Android podem chegar como `invalid_argument` e não acionar fallback; falhas assíncronas AVPlayer usam `open_failed`/`playback_failed`, que não identificam decoder para essa regra. Não conte com fallback para toda falha de codec. Para impedir qualquer troca automática, selecione `native` ou desative `allowAutomaticFallback` e trate a falha no host.

Uma fonte com hint `auto` pode passar pela elegibilidade sem ser realmente reproduzível pela WebView. A tentativa pode falhar também por CORS, codec, autoplay, protocolo ou timeout. Consulte a matriz em vez de interpretar `automatic` como suporte universal.

## Estado, erros, logs e diagnósticos

`LumioPlayerController` **estende `ValueNotifier<LumioPlayerState>`**. Leia `.value`, use `addListener`/`removeListener` ou observe com Flutter:

```dart
ValueListenableBuilder<LumioPlayerState>(
  valueListenable: controller,
  builder: (context, state, _) => Text(
    '${state.engine.name} · ${state.position.inSeconds}s'
    '${state.buffering ? ' · carregando' : ''}',
  ),
)
```

O estado imutável contém `initialized`, `playing`, `buffering`, `completed`, `transitioning`, `live`, `position`, `duration`, `bufferedPosition`, `size`, `aspectRatio`, `volume`, `speed`, `engine` e `error`. Os backends emitem eventos em mudanças e atualizações periódicas de cerca de 500 ms; não é uma telemetria frame a frame. Buffer e posição têm semânticas específicas do backend, não uma métrica de download uniforme.

`LumioPlayerError` expõe `code`, `message`, `details`, `recoverable` e `engine` opcional. Um erro pode rejeitar o Future da operação **ou aparecer depois em `value.error`**, durante a reprodução. Observe ambos. `recoverable` sozinho não dispara retry nem garante sucesso; recovery exige opt-in e as condições descritas acima. Falhas dos comandos da engine, inclusive `PlatformException` nativa, são convertidas e lançadas como **`LumioPlayerError` sanitizado**, em vez de repassar a exceção bruta; os logs também ocultam URI/segredos conhecidos. A validação de argumentos e o uso antes de inicialização/depois de descarte continuam podendo produzir `ArgumentError`/`StateError`; trate esses casos além de `LumioPlayerError`.

### Observabilidade opt-in e privacidade

- Passe `logger: (LumioLogEntry entry) { ... }` para receber entradas ou assine `controller.logs`, um stream broadcast. Não há histórico persistido/serviço de upload automático; cancele a assinatura quando não precisar mais dela.
- As entradas contêm timestamp, nível, código, mensagem, engine e `playerId`, um identificador de instância no isolate para correlacionar abertura e descarte. Logs do controller ocultam a URI da fonte, valores conhecidos de headers e URLs HTTP(S)/RTSP em códigos e mensagens.
- `LumioSource.toString()` omite URI/credenciais; **`.uri`, `.headers` e `.toMap()` não são sanitizados** e servem à reprodução. Não os envie para logs.
- `await controller.diagnostics()` coleta sob demanda e sanitiza strings recursivamente em mapas/listas. Expõe `engine`, `requestedEngine`, `fallbackUsed`, `initialized` e o payload da engine em `native` (nome da chave também usado para WebView).
- Android informa sistema/dispositivo, Media3, lista de decoders disponíveis e estado/formato do player. Também expõe **`videoDecoderName` e `audioDecoderName` reais**, capturados via `AnalyticsListener` na inicialização/liberação dos decoders, além de `enableDecoderFallback` e `liveTargetOffsetMs`; nomes podem ser nulos quando não há decoder ativo. iOS informa status/waiting reason, política de buffer, sessão de áudio e até 30 entradas de access/error log. WebView informa bridge, requisições pendentes e estado; não encaminha mensagens brutas do browser/HLS nem corpos de resposta.

A sanitização é **defesa em profundidade, não anonimização completa**. Metadados de dispositivo, comentários nativos, caminhos ou segredos desconhecidos podem continuar sensíveis; revise e minimize o payload antes de armazenar/enviar. Ferramentas de rede/browser e logs do sistema podem mostrar requisições. No iOS, as políticas explícitas de sessão de áudio podem falhar e rejeitar a abertura; `preserveHost` não reconfigura a sessão. Logging opt-in aqui refere-se à observabilidade exposta ao consumidor, não à supressão de todos os logs do sistema.

Depois de falha de inicialização sem fallback, o controller libera a engine; o snapshot posterior pode não conter o player nativo anterior. Capture estado/logs relevantes sem persistir credenciais.

### Confirmação de descarte ao sair da tela

O dono do controller deve chamar `dispose()` ao sair; remover somente `LumioPlayerView` não descarta o controller. `pause()` interrompe a reprodução, mas mantém recursos para retomá-la — não equivale a descarte.

```dart
final controller = LumioPlayerController(
  logger: (entry) => debugPrint(entry.toString()),
);

// No fluxo de encerramento do dono do player:
await controller.dispose();
```

| Código | Significado |
| --- | --- |
| `dispose_started` | Descarte iniciado; novos comandos e eventos de reprodução são rejeitados. |
| `resources_release_started` | Início da liberação de uma assinatura ou engine. |
| `resources_released` | A etapa respondeu com sucesso; inclui recurso e tempo decorrido. |
| `dispose_pending` | Controller desconectado, mas uma criação nativa tardia ainda precisa ser liberada. |
| `disposed` | Todas as etapas rastreadas foram confirmadas, sem falhas. |
| `dispose_failed` | Uma etapa falhou ou excedeu o prazo; as demais continuam sendo tentadas. |
| `dispose_incomplete` | Encerramento sem confirmação completa; não é anunciado como sucesso. |

As etapas têm prazo de 5 segundos; a confirmação JavaScript tem prazo de 2 segundos. A resposta nativa vem depois do teardown. Na WebView, o ACK vem depois de pausar e limpar a mídia, destruir HLS e remover listeners/timers; enviar o script não basta para confirmar. O app também deve remover o widget da WebView: o ACK de mídia não comprova destruição do processo WebView.

`dispose()` é idempotente e retorna o mesmo Future. Para não prender a navegação, ele pode terminar antes de uma resposta tardia de criação nativa: nesse caso registra `dispose_pending`, não `disposed`. Quando essa criação responder, sua liberação será tentada e a confirmação ou falha chegará pelo callback `logger`, mesmo após o fechamento de `controller.logs`. Use o callback para acompanhar esse caso; não dependa somente do stream.

`resources_released` também pode aparecer em troca de mídia/engine ou fallback, sem descarte definitivo do controller. Procure `disposed` com o mesmo `playerId` da inicialização para acompanhar o encerramento final.

Esses logs confirmam as operações de teardown, **não que o sistema operacional já devolveu RAM nem que o garbage collector executou**. Para comprovar ausência de vazamentos em ciclos repetidos de entrada/saída, use Xcode Instruments ou o profiler de memória do Android Studio.

## Arquitetura e protocolo nativo

| Arquivo/camada | Responsabilidade |
| --- | --- |
| `lib/src/models.dart` | Fontes, configuração, estado, erros, logs e capacidades |
| `lib/src/controller.dart` | Fila de comandos, lifecycle, seleção/fallback e sanitização |
| `lib/src/player_view.dart` / `controls_configuration.dart` | Superfície, controles configuráveis, gestos e estado de interação |
| `lib/src/native_bridge.dart` | Bridge Flutter nativa |
| `lib/src/web_engine.dart` e `assets/web/` | WebView, handshake JSON e elemento HTML de mídia |
| `android/src/main/kotlin/dev/lumio/lumio_player/LumioPlayerPlugin.kt` | Media3, fontes, eventos, textura `SurfaceProducer` e diagnósticos |
| `ios/lumio_player/Sources/lumio_player/` | AVQueuePlayer, parsing, registro, textura e lifecycle |

A bridge usa intencionalmente **`MethodChannel` e `EventChannel` manuais, não Pigeon**:

- Métodos: `lumio_player/methods`.
- Eventos compartilhados: `lumio_player/events`, roteados pelo `id` do player.
- `create` retorna `{id, textureId}`.
- `open`, `play`, `pause`, `seek`, `seekToLive`, `volume`, `speed`, `looping`, `diagnostics` e `dispose` usam mapas com `id`; `open` recebe `source` e `config`.
- `open` no protocolo nativo confirma despacho; o controller público espera os eventos de inicialização/erro.
- Eventos `state` e `error` carregam estado/código e identificador. A bridge WebView usa mensagens JSON e acknowledgments próprios, sem expor `id` nativo.

Android usa textura Flutter `SurfaceProducer` com rebind em disponibilidade/cleanup da superfície. iOS usa `AVPlayerItemVideoOutput`, pixel buffers BGRA e `CADisplayLink`; áudio sem vídeo não aloca display link. Desacoplamento do Flutter engine libera players. No iOS, se a categoria ainda for `soloAmbient`, o plugin seleciona `playback` com `mixWithOthers`; preserva sessão previamente configurada pelo host. Há tratamento de interrupções/remoção de saída de áudio, mas isso não constitui serviço de background.

Detalhes adicionais: [Android](android/README.md), [iOS](ios/README.md) e [WebView](assets/web/README.md). As notas nativas sobre Dart ainda ser scaffold/ausência de registro do exemplo são históricas: a API Dart e a declaração de plugin já existem. Seus defaults de canal bruto não substituem os defaults públicos documentados acima.

## Exemplo, testes e builds

`example/lib/main.dart` entrega um app de demonstração com seleção de fonte network/file/asset, pacote de asset, modo, engine, abertura, logs recentes e diagnósticos sanitizados. Mudar modo recria o controller. Há fixtures sintéticos de **2 segundos**, gerados com FFmpeg: `example/assets/sample.mp4` (vídeo) e `example/assets/sample.wav` (áudio), declarados em `example/pubspec.yaml`. No app exemplo, abra-os pelas chaves `assets/sample.mp4` e `assets/sample.wav`; para o WAV, selecione modo áudio. FFmpeg foi usado para gerar os fixtures, **não é dependência de runtime nem decoder do plugin**. A integração também copia o MP4 para um arquivo temporário no dispositivo para validar `LumioSource.file`.

Os comandos abaixo correspondem a testes, wrappers e fontes existentes. Execute cada bloco a partir do diretório indicado. Preparação/build pode baixar dependências e gerar artefatos; playback de rede contata os servidores da mídia.

### Dart/Flutter e JavaScript — raiz do pacote

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
node --check assets/web/player.js
node --test assets/web/player.test.cjs
```

Os testes Dart usam mocks de canais e testes de widgets/models; os JavaScript usam DOM/media/bridge simulados. Não certificam decodificação, CORS, rendering nem reprodução em dispositivo.

**Validação executada nesta implementação:**

| Verificação | Resultado |
| --- | --- |
| Testes Flutter do plugin | **97 aprovados** |
| Teste unitário do exemplo | **1 aprovado** |
| Testes unitários nativos Android | **16 aprovados** |
| Parser/configuração/live seek Swift | **Aprovado**, compilado com warnings como erros |
| Análise Flutter | **Sem apontamentos** |
| Build completo Android APK do exemplo | **Aprovado** |
| Build iOS simulator e integração completa | **Aprovados**, target iOS 15/Xcode 27 |
| Integração no simulador iPhone 17 Pro / iOS 26.5 | **6 testes aprovados**, incluindo playlist nativa, sequência WebView e retenção de índice |
| Testes JavaScript | **5 aprovados**, incluindo os modos de fit |

A integração aprovada cobre **montagem ociosa**, **comandos nativos reais de rede e troca nativo → WebView → nativo**, **abertura somente WebView**, **vídeo asset/arquivo temporário local/áudio WAV asset**, **avanço/navegação da fila nativa com textura preservada** e **avanço da sequência WebView com índice preservado no retorno ao nativo**. Inclui o tratamento de mute/unmute na WebView iOS. É uma aprovação nesses cenários no simulador informado, não em dispositivo físico nem uma certificação de live seek, HLS/DASH/RTSP, todos os codecs ou condições de rede.

Os testes de integração usaram o MP4 público de exemplo do Flutter e fixtures locais sintéticos. HLS/DASH/RTSP, live seek em transmissão real, dispositivos físicos e particularidades de fabricantes ainda precisam de validação própria.

### Android nativo

Pré-requisitos: JDK 17, Android SDK/API 36, Flutter embedding em cache (`flutter precache --android`) e `android/local.properties` com os caminhos locais reais `sdk.dir` e `flutter.sdk`. Esse arquivo é configuração da máquina, não deve conter caminhos copiados de outro desenvolvedor. O script standalone usa `android-arm64/flutter.jar` do cache Flutter.

A partir de `android/`:

```sh
../example/android/gradlew -p . -I validation.init.gradle compileDebugKotlin testDebugUnitTest
```

Alternativamente, a partir de `example/android/`, com o host configurado:

```sh
./gradlew :lumio_player:testDebugUnitTest
```

Os init scripts existentes dão acesso ao embedding para validação nativa; não são dependências a adicionar ao app consumidor. Testes unitários cobrem parsing/argumentos e comportamento detached, não decoders/rede/superfície real.

### iOS: teste do parser — raiz do pacote

O teste usa o parser de produção com Foundation e pode rodar no macOS com as ferramentas Xcode:

```sh
mkdir -p ios/.native-validation
xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors \
  ios/lumio_player/Sources/lumio_player/LumioConfiguration.swift \
  ios/lumio_player/Sources/lumio_player/LumioLiveSeek.swift \
  ios/Tests/ConfigurationTests.swift -o ios/.native-validation/configuration-tests
ios/.native-validation/configuration-tests
```

Esse comando não compila AVPlayer/FlutterTexture nem valida reprodução iOS. Compile a integração completa pelo host Flutter com SDK iOS/Xcode configurados; não há wrapper de testes Swift Package independente.

### App exemplo — a partir de `example/`

```sh
flutter pub get
flutter analyze --no-pub
flutter build apk --debug
flutter build ios --simulator --debug
flutter devices
flutter run -d <ID_ANDROID_OU_IOS>
flutter test integration_test/player_integration_test.dart -d <ID_ANDROID_OU_IOS>
```

Substitua `<ID_ANDROID_OU_IOS>` por um ID real de `flutter devices`. Android precisa do SDK/JDK; iOS requer macOS/Xcode, simulador e dependências nativas resolvidas pela integração Flutter. O build de simulador não exige assinatura de distribuição; builds em dispositivo/release dependem da configuração do host. O exemplo ainda usa assinatura debug no build Android release, inadequada para distribuição.

O teste de integração monta um player ocioso, reproduz fontes locais de vídeo/áudio e inclui cenários **opt-in** de comandos nativos/troca nativo → WebView → nativo e abertura WebView com a superfície montada. Os cenários de rede ficam skipped sem `LUMIO_TEST_URL`. Para habilitá-los:

```sh
flutter test integration_test/player_integration_test.dart -d <ID_ANDROID_OU_IOS> \
  --dart-define=LUMIO_TEST_URL=<URL_HTTPS_DE_TESTE_SEM_CREDENCIAIS>
```

Use mídia não sensível e servidor compatível com a WebView. Esses placeholders não são comandos prontos para executar sem substituição. O cenário nativo exercita abertura, volume, looping, seek, play/pause e troca de engine, incluindo mute/unmute. Os seis testes passaram no simulador iPhone 17 Pro com iOS 26.5, incluindo fila nativa e sequência WebView. Não é uma matriz completa de formatos/dispositivos nem mede performance/latência ou valida live seek.

Valide em dispositivos: HLS/progressivo e áudio, arquivos/assets, seek/loop/fim, falhas HTTP/autenticação, codec indisponível, CORS, autoplay, troca de engine, dispose durante abertura, recriação de superfície Android, interrupções/rota de áudio iOS e background/foreground.

## Limitações e roadmap

### Não entregue / sem garantia embutida

- **Sem serviço Android de background**, notificação/media session completa, controle de lock screen ou integração de comandos remotos.
- **Sem Picture-in-Picture** implementado.
- **Fullscreen por rota está disponível** em `LumioPlayerView`; não implica gerenciamento automático de orientação ou integrações de sistema. Para navegação/políticas próprias, use o callback do host e preserve uma única superfície por controller; não monte uma segunda WebView.
- `allowBackgroundPlayback` oferece opt-in de lifecycle, não garantia de playback em background. No iOS, background pausa polling de frames; continuidade de áudio depende das capabilities/política do host. A engine WebView não fornece suporte de background.
- Sem DRM, codecs próprios, suporte universal de containers, cache offline/download ou player desktop/web.
- Sem seleção/listagem de faixas de áudio, vídeo ou legendas, controle ABR/qualidade, legendas externas ou controles aprofundados de live/DVR. Playlist nativa já está implementada.
- Sem método público dedicado de cancelamento de `open`; descarte o controller ao abandonar a operação. O guard de cancelamento interrompe a espera de inicialização, e `create` agora é limitado pelo orçamento de `initializationTimeout`. Se a criação nativa completar depois do abandono/timeout, o resultado tardio é descartado via `dispose` nativo. Isso não cancela a execução de um método já despachado à plataforma nem garante um prazo global somando cleanup, fallback e restauração de posição.
- WebView iOS permite somente mute/unmute, sem ganho intermediário; veja `capabilities.volumeControl` e `unsupported_volume_gain`.
- Sem garantia de fallback para toda falha nativa, recuperação de rede/auth, latência fixa ou ausência de interrupção ao trocar engine.

### Próximos passos propostos, não compromisso de entrega

1. Ampliar a integração já aprovada com live seek/janelas deslizantes, decoder fallback/offset live, timeout/cancelamento, cleanup tardio e falhas de rede; validar também em dispositivos físicos/Android.
2. Ampliar a matriz de dispositivos/CI para Flutter/AGP/Kotlin/iOS e revisar os avisos de terceiros antes de qualquer decisão de publicação.
3. Evoluir controles já existentes com seleção de faixas/legendas/qualidade, UI de volume, acessibilidade/localização e extensões customizáveis.
4. Evoluir live/DVR além do `seekToLive` já entregue e avaliar lifecycle/foco de áudio e políticas de sessão antes de oferecer garantias adicionais.
5. Ampliar políticas de fullscreen e avaliar PiP/background e integrações de sistema como features explícitas, sem inferi-las a partir do suporte dos players subjacentes.
6. Avaliar cache/DRM conforme requisitos do produto. Não estão implementados nesta versão.

## Licença

O `LICENSE` da raiz mantém o projeto **privado, com todos os direitos reservados** (`All rights reserved`). Nenhuma licença open source foi escolhida. Antes de publicar ou redistribuir, os titulares precisam definir a licença e revisar os avisos de terceiros.

A cópia empacotada de HLS.js tem avisos próprios em [HLS-LICENSE.txt](assets/web/HLS-LICENSE.txt) e o texto Apache 2.0 em [APACHE-2.0.txt](assets/web/APACHE-2.0.txt). Preserve-os ao redistribuir. A licença de um componente de terceiros não define a licença de todo o plugin. O `LICENSE` da raiz também referencia os nomes reais dos avisos empacotados: `HLS-LICENSE.txt` e `APACHE-2.0.txt`.

Consulte também o [CHANGELOG](CHANGELOG.md).
