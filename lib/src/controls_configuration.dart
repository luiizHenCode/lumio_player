import 'package:flutter/material.dart';

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
    this.showPlayPause = true,
    this.showProgress = true,
    this.showSpeed = true,
    this.showSkipButtons = true,
    this.showVolume = true,
    this.showPlaylistNavigation = true,
    this.showSettings = true,
    this.showTime = true,
    this.showTitle = true,
    this.showRetry = true,
    this.showLiveButton = true,
    this.showLoader = true,
    this.showStatistics = false,
    this.playbackSpeeds = const [1, 1.5, 2, 3, 4],
    this.doubleTapSeek = true,
    this.seekInterval = const Duration(seconds: 10),
    this.holdToSpeed = true,
    this.holdSpeed = 2,
    this.enableZoom = false,
    this.maxZoom = 4,
    this.compact = false,
    this.compactDelay = const Duration(seconds: 2),
    this.progressColor,
    this.backgroundColor = Colors.black87,
    this.foregroundColor = Colors.white,
    this.titleStyle,
  });

  final bool enabled;
  final bool showPlayPause, showProgress, showSpeed, showSkipButtons;
  final bool showVolume, showPlaylistNavigation, showSettings, showTime;
  final bool showTitle, showRetry, showLiveButton, showLoader;

  /// Opt-in debug action. Does not collect anything until the panel is opened.
  final bool showStatistics;
  final List<double> playbackSpeeds;
  final bool doubleTapSeek, holdToSpeed, enableZoom, compact;
  final Duration seekInterval, compactDelay;
  final double holdSpeed, maxZoom;

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
