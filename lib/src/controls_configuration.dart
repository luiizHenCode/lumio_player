import 'package:flutter/material.dart';

/// Automatic follows the media mode; live media always uses live controls.
enum LumioControlsLayout { automatic, live, complete, simplified }

/// The single trailing action in the simplified video layout.
enum LumioSimplifiedControl { speed, volume }

/// Controls below the media or over its bottom edge.
enum LumioControlsPlacement { below, overlay }

/// Presentation and gestures for both the player view and standalone controls.
///
/// [enabled] (and `LumioPlayerView.controls`) disables all chrome and gestures,
/// but not the loading indicator: use [showLoader] to disable that separately.
/// Switches for buttons do not disable the corresponding surface gesture.
/// Call [validate] when constructing a configuration outside a player widget.
@immutable
class LumioControlsConfiguration {
  const LumioControlsConfiguration({
    this.enabled = true,
    this.layout = LumioControlsLayout.automatic,
    this.placement = LumioControlsPlacement.below,
    this.liveLabel = 'AO VIVO',
    this.playingLabel = 'REPRODUZINDO',
    this.pausedLabel = 'PAUSADO',
    this.loadingLabel = 'CARREGANDO',
    this.simplifiedControl = LumioSimplifiedControl.speed,
    this.showStatus = true,
    this.showFullscreen = true,
    this.showPlayPause = true,
    this.showProgress = true,
    this.previewWhileScrubbing = false,
    this.scrubPreviewInterval = const Duration(milliseconds: 150),
    this.showSpeed = true,
    this.showSkipButtons = true,
    this.showVolume = true,
    this.showVolumeSlider = false,
    this.showPlaylistNavigation = true,
    this.showPreviousItem = true,
    this.showNextItem = true,
    this.showSettings = false,
    this.showTime = true,
    this.showLiveTime = false,
    this.showTitle = true,
    this.showRetry = true,
    this.showLiveButton = true,
    this.showLoader = true,
    this.bufferingIndicatorDelay = const Duration(milliseconds: 700),
    this.bufferingLabel = 'Carregando…',
    this.reconnectingLabel = 'Reconectando…',
    this.showStatistics = false,
    this.playbackSpeeds = const [1, 2, 3, 4],
    this.doubleTapSeek = true,
    this.seekInterval = const Duration(seconds: 10),
    this.holdToSpeed = true,
    this.holdSpeed = 2,
    this.enableZoom = false,
    this.maxZoom = 4,
    this.compact = false,
    this.compactDelay = const Duration(seconds: 5),
    this.progressColor,
    this.backgroundColor = Colors.black,
    this.foregroundColor = Colors.white,
    this.titleStyle,
  });

  final bool enabled;
  final LumioControlsLayout layout;
  final LumioControlsPlacement placement;

  /// Plain status text. Styling is owned by the built-in controls.
  final String liveLabel, playingLabel, pausedLabel, loadingLabel;
  final LumioSimplifiedControl simplifiedControl;
  final bool showStatus, showFullscreen;

  /// Individual playlist actions, subordinate to [showPlaylistNavigation].
  final bool showPreviousItem, showNextItem;
  final bool showPlayPause, showProgress, showSpeed, showSkipButtons;

  /// Opt-in seeks while dragging seekable VOD. Playback is temporarily paused
  /// and resumes only after a successful final seek if it was playing before.
  final bool previewWhileScrubbing;

  /// Minimum interval between preview seeks; the final seek bypasses this delay.
  final Duration scrubPreviewInterval;
  final bool showVolume, showPlaylistNavigation, showSettings, showTime;
  final bool showTitle, showRetry, showLoader;

  /// Visual debounce after observed playback; never delays opening or recovery.
  /// Zero shows the small media badge immediately. Must not be negative.
  final Duration bufferingIndicatorDelay;

  /// Media badge labels, independent of the controls' [loadingLabel].
  final String bufferingLabel, reconnectingLabel;

  /// Retained for source compatibility. The live label is always informational.
  @Deprecated(
    'Live status is informational; call controller.seekToLive() explicitly.',
  )
  final bool showLiveButton;

  /// Opt-in gain slider, visible only when [showVolume] and gain support are enabled.
  final bool showVolumeSlider;

  /// Opt-in live elapsed-time label; also requires [showTime].
  final bool showLiveTime;

  /// Opt-in debug action. Does not collect anything until the panel is opened.
  final bool showStatistics;
  final List<double> playbackSpeeds;
  final bool doubleTapSeek, holdToSpeed, enableZoom, compact;
  final Duration seekInterval, compactDelay;

  /// Temporary rate when holding the media at 1x. At 2x or above, hold uses 1x.
  /// Other rates below 2x do not start a hold session.
  final double holdSpeed;
  final double maxZoom;

  /// Defaults to the theme's primary color.
  final Color? progressColor;
  final Color backgroundColor, foregroundColor;
  final TextStyle? titleStyle;

  void validate() {
    if (enabled &&
        showSpeed &&
        (playbackSpeeds.isEmpty ||
            playbackSpeeds.any(
              (speed) => !speed.isFinite || speed < .25 || speed > 4,
            ) ||
            playbackSpeeds.toSet().length != playbackSpeeds.length)) {
      throw ArgumentError(
        'Playback speeds must be unique, finite values in .25..4.',
      );
    }
    if (bufferingIndicatorDelay.isNegative) {
      throw ArgumentError('Buffering indicator delay must not be negative.');
    }
    if (scrubPreviewInterval <= Duration.zero) {
      throw ArgumentError('Scrub preview interval must be positive.');
    }
    if (seekInterval <= Duration.zero || compactDelay <= Duration.zero) {
      throw ArgumentError('Seek interval and compact delay must be positive.');
    }
    if (!holdSpeed.isFinite || holdSpeed < .25 || holdSpeed > 4) {
      throw ArgumentError('Hold speed must be finite and in .25..4.');
    }
    if (!maxZoom.isFinite || maxZoom < 1 || maxZoom > 4) {
      throw ArgumentError('Maximum zoom must be finite and in 1..4.');
    }
  }
}
