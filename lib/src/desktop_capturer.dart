import 'dart:async';
import 'dart:typed_data';

import 'package:webrtc_interface/webrtc_interface.dart';

enum SourceType { Screen, Window }

/// VGV fork addition (vgv/macos-window-capture): the kind of source the user
/// chose in the macOS-native `SCContentSharingPicker`.
enum PickedSourceKind { display, window, application }

/// VGV fork addition: the result of [DesktopCapturer.pickAndCaptureDisplayMedia].
/// Capture has already started natively on the exact `SCContentFilter` the user
/// picked (a display, window, or application), so [stream] carries live frames
/// of just that selection — a window pick captures that window, not the screen.
class PickedDisplayMedia {
  PickedDisplayMedia({
    required this.stream,
    required this.trackId,
    required this.kind,
    required this.sourceName,
  });

  /// The live capture stream, ready to be published (e.g. via LiveKit).
  final MediaStream stream;

  /// WebRTC track id of the capture track — matches the video track in
  /// [stream] and the id emitted by [DesktopCapturer.onSelectedSourceStopped].
  final String trackId;

  /// Whether the user picked a display, a window, or an application.
  final PickedSourceKind kind;

  /// Human-readable label for the picked source (window title / app name /
  /// display label). May be empty when the OS provides none.
  final String sourceName;
}

final desktopSourceTypeToString = <SourceType, String>{
  SourceType.Screen: 'screen',
  SourceType.Window: 'window',
};

final tringToDesktopSourceType = <String, SourceType>{
  'screen': SourceType.Screen,
  'window': SourceType.Window,
};

class ThumbnailSize {
  ThumbnailSize(this.width, this.height);
  factory ThumbnailSize.fromMap(Map<dynamic, dynamic> map) {
    return ThumbnailSize(map['width'], map['height']);
  }
  int width;
  int height;

  Map<String, int> toMap() => {'width': width, 'height': height};
}

abstract class DesktopCapturerSource {
  /// The identifier of a window or screen that can be used as a
  /// chromeMediaSourceId constraint when calling
  String get id;

  /// A screen source will be named either Entire Screen or Screen index,
  /// while the name of a window source will match the window title.
  String get name;

  ///A thumbnail image of the source. jpeg encoded.
  Uint8List? get thumbnail;

  /// specified in the options passed to desktopCapturer.getSources.
  /// The actual size depends on the scale of the screen or window.
  ThumbnailSize get thumbnailSize;

  /// The type of the source.
  SourceType get type;

  StreamController<String> get onNameChanged => throw UnimplementedError();

  StreamController<Uint8List> get onThumbnailChanged =>
      throw UnimplementedError();
}

abstract class DesktopCapturer {
  StreamController<DesktopCapturerSource> get onAdded =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onRemoved =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onNameChanged =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onThumbnailChanged =>
      throw UnimplementedError();

  ///Get the screen source of the specified types
  Future<List<DesktopCapturerSource>> getSources({
    required List<SourceType> types,
    ThumbnailSize? thumbnailSize,
  });

  /// Updates the list of screen sources of the specified types
  Future<bool> updateSources({required List<SourceType> types});

  /// VGV fork addition (vgv/macos-window-capture): presents the macOS-native
  /// content picker (`SCContentSharingPicker`, macOS 14+) so the user chooses
  /// a display, window, or application, and starts capturing that exact
  /// selection. Returns the started [PickedDisplayMedia], or `null` when the
  /// user cancels the picker.
  ///
  /// macOS-only. Throws on platforms without the picker, or when the running
  /// macOS predates 14.0.
  Future<PickedDisplayMedia?> pickAndCaptureDisplayMedia() =>
      throw UnimplementedError();

  /// VGV fork addition: emits the [PickedDisplayMedia.trackId] whenever a
  /// picker-started capture stops for a reason other than the app stopping the
  /// track — the user hit the system "Stop Sharing" control, or the source
  /// window/app closed. The app unpublishes the track in response.
  Stream<String> get onSelectedSourceStopped => throw UnimplementedError();
}
