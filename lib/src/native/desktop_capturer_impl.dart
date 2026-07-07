import 'dart:async';
import 'dart:typed_data';

import '../desktop_capturer.dart';
import 'event_channel.dart';
import 'media_stream_impl.dart';
import 'utils.dart';

class DesktopCapturerSourceNative extends DesktopCapturerSource {
  DesktopCapturerSourceNative(
    this._id,
    this._name,
    this._thumbnailSize,
    this._type,
  );
  factory DesktopCapturerSourceNative.fromMap(Map<dynamic, dynamic> map) {
    var sourceType = (map['type'] as String) == 'window'
        ? SourceType.Window
        : SourceType.Screen;
    var source = DesktopCapturerSourceNative(
      map['id'],
      map['name'],
      ThumbnailSize.fromMap(map['thumbnailSize']),
      sourceType,
    );
    if (map['thumbnail'] != null) {
      source.thumbnail = map['thumbnail'] as Uint8List;
    }
    return source;
  }

  //ignore: close_sinks
  final StreamController<String> _onNameChanged = StreamController.broadcast(
    sync: true,
  );

  @override
  StreamController<String> get onNameChanged => _onNameChanged;

  final StreamController<Uint8List> _onThumbnailChanged =
      StreamController.broadcast(sync: true);

  @override
  StreamController<Uint8List> get onThumbnailChanged => _onThumbnailChanged;

  Uint8List? _thumbnail;
  String _name;
  final String _id;
  final ThumbnailSize _thumbnailSize;
  final SourceType _type;

  set thumbnail(Uint8List? value) {
    _thumbnail = value;
  }

  set name(String name) {
    _name = name;
  }

  @override
  String get id => _id;

  @override
  String get name => _name;

  @override
  Uint8List? get thumbnail => _thumbnail;

  @override
  ThumbnailSize get thumbnailSize => _thumbnailSize;

  @override
  SourceType get type => _type;
}

class DesktopCapturerNative extends DesktopCapturer {
  DesktopCapturerNative._internal() {
    FlutterWebRTCEventChannel.instance.handleEvents.stream.listen((data) {
      var event = data.keys.first;
      Map<dynamic, dynamic> map = data[event];
      handleEvent(event, map);
    });
  }
  static final DesktopCapturerNative instance =
      DesktopCapturerNative._internal();

  @override
  StreamController<DesktopCapturerSource> get onAdded => _onAdded;
  final StreamController<DesktopCapturerSource> _onAdded =
      StreamController.broadcast(sync: true);

  @override
  StreamController<DesktopCapturerSource> get onRemoved => _onRemoved;
  final StreamController<DesktopCapturerSource> _onRemoved =
      StreamController.broadcast(sync: true);

  @override
  StreamController<DesktopCapturerSource> get onNameChanged => _onNameChanged;
  final StreamController<DesktopCapturerSource> _onNameChanged =
      StreamController.broadcast(sync: true);

  @override
  StreamController<DesktopCapturerSource> get onThumbnailChanged =>
      _onThumbnailChanged;
  final StreamController<DesktopCapturerSource> _onThumbnailChanged =
      StreamController.broadcast(sync: true);

  final Map<String, DesktopCapturerSourceNative> _sources = {};

  // VGV fork (vgv/macos-window-capture): OS-initiated stops of a picker
  // capture (system "Stop Sharing", source window closed) surface here.
  final StreamController<String> _onSelectedSourceStopped =
      StreamController.broadcast(sync: true);

  @override
  Stream<String> get onSelectedSourceStopped => _onSelectedSourceStopped.stream;

  void handleEvent(String event, Map<dynamic, dynamic> map) async {
    switch (event) {
      case 'selectedSourceStopped':
        // VGV fork: a picker-started capture stopped outside the app's
        // control; surface its trackId so the app can unpublish.
        final trackId = map['trackId'] as String?;
        if (trackId != null) {
          _onSelectedSourceStopped.add(trackId);
        }
        break;
      case 'desktopSourceAdded':
        final source = DesktopCapturerSourceNative.fromMap(map);
        if (_sources[source.id] == null) {
          _sources[source.id] = source;
          _onAdded.add(source);
        }
        break;
      case 'desktopSourceRemoved':
        final id = map['id'] as String;
        if (_sources[id] != null) {
          _onRemoved.add(_sources.remove(id)!);
        }
        break;
      case 'desktopSourceThumbnailChanged':
        final source = _sources[map['id'] as String];
        if (source != null) {
          try {
            source.thumbnail = map['thumbnail'] as Uint8List;
            _onThumbnailChanged.add(source);
            source.onThumbnailChanged.add(source.thumbnail!);
          } catch (e) {
            print('desktopSourceThumbnailChanged: $e');
          }
        }
        break;
      case 'desktopSourceNameChanged':
        final source = _sources[map['id'] as String];
        if (source != null) {
          source.name = map['name'];
          _onNameChanged.add(source);
          source.onNameChanged.add(source.name);
        }
        break;
    }
  }

  void errorListener(Object obj) {
    if (obj is Exception) {
      throw obj;
    }
  }

  @override
  Future<List<DesktopCapturerSource>> getSources({
    required List<SourceType> types,
    ThumbnailSize? thumbnailSize,
  }) async {
    _sources.clear();
    final response = await WebRTC.invokeMethod(
      'getDesktopSources',
      <String, dynamic>{
        'types': types.map((type) => desktopSourceTypeToString[type]).toList(),
        if (thumbnailSize != null) 'thumbnailSize': thumbnailSize.toMap(),
      },
    );
    if (response == null) {
      throw Exception('getDesktopSources return null, something wrong');
    }
    for (var source in response['sources']) {
      var desktopSource = DesktopCapturerSourceNative.fromMap(source);
      _sources[desktopSource.id] = desktopSource;
    }
    return _sources.values.toList();
  }

  @override
  Future<bool> updateSources({required List<SourceType> types}) async {
    final response = await WebRTC.invokeMethod(
      'updateDesktopSources',
      <String, dynamic>{
        'types': types.map((type) => desktopSourceTypeToString[type]).toList(),
      },
    );
    if (response == null) {
      throw Exception('updateSources return null, something wrong');
    }
    return response['result'] as bool;
  }

  // VGV fork addition (vgv/macos-window-capture).
  @override
  Future<PickedDisplayMedia?> pickAndCaptureDisplayMedia() async {
    final response = await WebRTC.invokeMethod(
      'getDisplayMediaWithPicker',
      <String, dynamic>{},
    );
    if (response == null) {
      throw Exception('getDisplayMediaWithPicker returned null');
    }
    // The user dismissed the picker without choosing — a no-op, not an error.
    if (response['cancelled'] == true) {
      return null;
    }
    final streamId = response['streamId'] as String;
    final stream = MediaStreamNative(streamId, 'local');
    stream.setMediaTracks(response['audioTracks'], response['videoTracks']);
    final videoTracks = response['videoTracks'] as List<dynamic>;
    final trackId = videoTracks.first['id'] as String;
    final source = response['source'] as Map<dynamic, dynamic>?;
    final kind = _pickedKindFromString(source?['kind'] as String?);
    final name = (source?['name'] as String?) ?? '';
    return PickedDisplayMedia(
      stream: stream,
      trackId: trackId,
      kind: kind,
      sourceName: name,
    );
  }

  static PickedSourceKind _pickedKindFromString(String? value) {
    switch (value) {
      case 'window':
        return PickedSourceKind.window;
      case 'application':
        return PickedSourceKind.application;
      case 'display':
      default:
        return PickedSourceKind.display;
    }
  }

  Future<Uint8List?> getThumbnail(DesktopCapturerSourceNative source) async {
    final response = await WebRTC.invokeMethod(
      'getDesktopSourceThumbnail',
      <String, dynamic>{
        'sourceId': source.id,
        'thumbnailSize': {
          'width': source.thumbnailSize.width,
          'height': source.thumbnailSize.height,
        },
      },
    );
    if (response == null || !response is Uint8List?) {
      throw Exception('getDesktopSourceThumbnail return null, something wrong');
    }
    return response as Uint8List?;
  }
}
