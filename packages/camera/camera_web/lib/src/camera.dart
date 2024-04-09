// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui';
import 'dart:ui_web' as ui_web;

import 'package:web/helpers.dart';
import 'package:web/web.dart' as web;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'camera_service.dart';
import 'types/types.dart';

String _getViewType(int cameraId) => 'plugins.flutter.io/camera_$cameraId';

/// A camera initialized from the media devices in the current window.
/// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices
///
/// The obtained camera stream is constrained by [options] and fetched
/// with [CameraService.getMediaStreamForOptions].
///
/// The camera stream is displayed in the [videoElement] wrapped in the
/// [divElement] to avoid overriding the custom styles applied to
/// the video element in [_applyDefaultVideoStyles].
/// See: https://github.com/flutter/flutter/issues/79519
///
/// The camera stream can be played/stopped by calling [play]/[stop],
/// may capture a picture by calling [takePicture] or capture a video
/// by calling [startVideoRecording], [pauseVideoRecording],
/// [resumeVideoRecording] or [stopVideoRecording].
///
/// The camera zoom may be adjusted with [setZoomLevel]. The provided
/// zoom level must be a value in the range of [getMinZoomLevel] to
/// [getMaxZoomLevel].
///
/// The [textureId] is used to register a camera view with the id
/// defined by [_getViewType].
class Camera {
  /// Creates a new instance of [Camera]
  /// with the given [textureId] and optional
  /// [options] and [window].
  Camera({
    required this.textureId,
    required CameraService cameraService,
    this.options = const CameraOptions(),
    this.recorderOptions = const (audioBitrate: null, videoBitrate: null),
  }) : _cameraService = cameraService;

  // A torch mode constraint name.
  // See: https://w3c.github.io/mediacapture-image/#dom-mediatracksupportedconstraints-torch
  static const String _torchModeKey = 'torch';

  /// The texture id used to register the camera view.
  final int textureId;

  /// The camera options used to initialize a camera, empty by default.
  final CameraOptions options;

  /// The options used to initialize a MediaRecorder.
  final ({int? audioBitrate, int? videoBitrate}) recorderOptions;

  /// The video element that displays the camera stream.
  /// Initialized in [initialize].
  late final web.VideoElement videoElement;

  /// The wrapping element for the [videoElement] to avoid overriding
  /// the custom styles applied in [_applyDefaultVideoStyles].
  /// Initialized in [initialize].
  late final web.HTMLDivElement divElement;

  /// The camera stream displayed in the [videoElement].
  /// Initialized in [initialize] and [play], reset in [stop].
  web.MediaStream? stream;

  /// The stream of the camera video tracks that have ended playing.
  ///
  /// This occurs when there is no more camera stream data, e.g.
  /// the user has stopped the stream by changing the camera device,
  /// revoked the camera permissions or ejected the camera device.
  ///
  /// MediaStreamTrack.onended:
  /// https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamTrack/onended
  Stream<web.MediaStreamTrack> get onEnded => onEndedController.stream;

  /// The stream controller for the [onEnded] stream.
  @visibleForTesting
  final StreamController<web.MediaStreamTrack> onEndedController = StreamController<web.MediaStreamTrack>.broadcast();

  /// The stream of the camera video recording errors.
  ///
  /// This occurs when the video recording is not allowed or an unsupported
  /// codec is used.
  ///
  /// MediaRecorder.error:
  /// https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder/error_event
  Stream<web.ErrorEvent> get onVideoRecordingError => videoRecordingErrorController.stream;

  /// The stream controller for the [onVideoRecordingError] stream.
  @visibleForTesting
  final StreamController<web.ErrorEvent> videoRecordingErrorController = StreamController<web.ErrorEvent>.broadcast();

  StreamSubscription<web.Event>? _onVideoRecordingErrorSubscription;

  /// The camera flash mode.
  @visibleForTesting
  FlashMode? flashMode;

  /// The camera service used to get the media stream for the camera.
  final CameraService _cameraService;

  /// The current browser window used to access media devices.
  @visibleForTesting
  web.Window? window = web.window;

  /// The recorder used to record a video from the camera.
  @visibleForTesting
  web.MediaRecorder? mediaRecorder;

  /// The list of consecutive video data files recorded with [mediaRecorder].
  final List<web.Blob> _videoData = <web.Blob>[];

  /// Completes when the video recording is stopped/finished.
  Completer<XFile>? _videoAvailableCompleter;

  /// A data listener fired when a new part of video data is available.
  void Function(web.Event)? _videoDataAvailableListener;

  /// A listener fired when a video recording is stopped.
  void Function(web.Event)? _videoRecordingStoppedListener;

  /// A builder to merge a list of blobs into a single blob.
  @visibleForTesting
  // TODO(stuartmorgan): Remove this 'ignore' once we don't analyze using 2.10
  // any more. It's a false positive that is fixed in later versions.
  // ignore: prefer_function_declarations_over_variables
  web.Blob Function(List<web.Blob> blobs, String type) blobBuilder =
      (List<web.Blob> blobs, String type) => web.Blob(blobs.toJS, BlobPropertyBag(type: type));

  /// The stream that emits a [VideoRecordedEvent] when a video recording is created.
  Stream<VideoRecordedEvent> get onVideoRecordedEvent => videoRecorderController.stream;

  /// The stream controller for the [onVideoRecordedEvent] stream.
  @visibleForTesting
  final StreamController<VideoRecordedEvent> videoRecorderController = StreamController<VideoRecordedEvent>.broadcast();

  /// Initializes the camera stream displayed in the [videoElement].
  /// Registers the camera view with [textureId] under [_getViewType] type.
  /// Emits the camera default video track on the [onEnded] stream when it ends.
  Future<void> initialize() async {
    stream = await _cameraService.getMediaStreamForOptions(
      options,
      cameraId: textureId,
    );

    videoElement = web.VideoElement();

    divElement = web.HTMLDivElement()
      ..style.setProperty('object-fit', 'cover')
      ..append(videoElement);

    ui_web.platformViewRegistry.registerViewFactory(
      _getViewType(textureId),
      (_) => divElement,
    );

    videoElement
      ..autoplay = false
      ..muted = true
      ..srcObject = stream
      ..setAttribute('playsinline', '');

    _applyDefaultVideoStyles(videoElement);

    final List<web.MediaStreamTrack> videoTracks = stream!.getVideoTracks().toDart;

    if (videoTracks.isNotEmpty) {
      final web.MediaStreamTrack defaultVideoTrack = videoTracks.first;
      
      defaultVideoTrack.onended = (web.Event event) {
        onEndedController.add(defaultVideoTrack);
      }.toJS;
      
    }
  }

  /// Starts the camera stream.
  ///
  /// Initializes the camera source if the camera was previously stopped.
  Future<void> play() async {
    if (videoElement.srcObject == null) {
      stream = await _cameraService.getMediaStreamForOptions(
        options,
        cameraId: textureId,
      );
      videoElement.srcObject = stream;
    }
    await videoElement.play().toDart;
  }

  /// Pauses the camera stream on the current frame.
  void pause() {
    videoElement.pause();
  }

  /// Stops the camera stream and resets the camera source.
  void stop() {
    final List<web.MediaStreamTrack> videoTracks = stream!.getVideoTracks().toDart;
    if (videoTracks.isNotEmpty) {
      onEndedController.add(videoTracks.first);
    }

    final List<web.MediaStreamTrack>? tracks = stream?.getTracks().toDart;
    if (tracks != null) {
      for (final web.MediaStreamTrack track in tracks) {
        track.stop();
      }
    }
    videoElement.srcObject = null;
    stream = null;
  }

  /// Captures a picture and returns the saved file in a JPEG format.
  ///
  /// Enables the camera flash (torch mode) for a period of taking a picture
  /// if the flash mode is either [FlashMode.auto] or [FlashMode.always].
  Future<XFile> takePicture() async {
    final bool shouldEnableTorchMode = flashMode == FlashMode.auto || flashMode == FlashMode.always;

    if (shouldEnableTorchMode) {
      _setTorchMode(enabled: true);
    }

    final int videoWidth = videoElement.videoWidth;
    final int videoHeight = videoElement.videoHeight;
    final web.HTMLCanvasElement canvas = web.HTMLCanvasElement()
      ..width = videoHeight
      ..height = videoHeight;
    final bool isBackCamera = getLensDirection() == CameraLensDirection.back;

    // Flip the picture horizontally if it is not taken from a back camera.
    if (!isBackCamera) {
      canvas.context2D
        ..translate(videoWidth, 0)
        ..scale(-1, 1);
    }

    canvas.context2D.drawImageScaled(videoElement, 0, 0, videoWidth.toDouble(), videoHeight.toDouble());

    web.Blob blob = web.Blob();
    canvas.toBlob(
        (web.Blob? blob) {
          blob = blob!;
        }.toJS,
        'image/jpeg');

    if (shouldEnableTorchMode) {
      _setTorchMode(enabled: false);
    }

    return XFile(web.URL.createObjectURL(blob));
  }

  /// Returns a size of the camera video based on its first video track size.
  ///
  /// Returns [Size.zero] if the camera is missing a video track or
  /// the video track does not include the width or height setting.
  Size getVideoSize() {
    final List<web.MediaStreamTrack> videoTracks =
        videoElement.srcObject?.callMethod('getVideoTracks'.toJS) ?? <web.MediaStreamTrack>[];
    if (videoTracks.isEmpty) {
      return Size.zero;
    }

    final web.MediaStreamTrack defaultVideoTrack = videoTracks.first;
    final MediaTrackSettings defaultVideoTrackSettings = defaultVideoTrack.getSettings();

    final int width = defaultVideoTrackSettings.width;
    final int height = defaultVideoTrackSettings.height;

    return Size(width.toDouble(), height.toDouble());
  }

  /// Sets the camera flash mode to [mode] by modifying the camera
  /// torch mode constraint.
  ///
  /// The torch mode is enabled for [FlashMode.torch] and
  /// disabled for [FlashMode.off].
  ///
  /// For [FlashMode.auto] and [FlashMode.always] the torch mode is enabled
  /// only for a period of taking a picture in [takePicture].
  ///
  /// Throws a [CameraWebException] if the torch mode is not supported
  /// or the camera has not been initialized or started.
  void setFlashMode(FlashMode mode) {
    final web.MediaDevices? mediaDevices = window?.navigator.mediaDevices;

    final bool torchModeSupported =
        mediaDevices?.getSupportedConstraints().getProperty(_torchModeKey.toJS) as bool? ?? false;

    if (!torchModeSupported) {
      throw CameraWebException(
        textureId,
        CameraErrorCode.torchModeNotSupported,
        'The torch mode is not supported in the current browser.',
      );
    }

    // Save the updated flash mode to be used later when taking a picture.
    flashMode = mode;

    // Enable the torch mode only if the flash mode is torch.
    _setTorchMode(enabled: mode == FlashMode.torch);
  }

  /// Sets the camera torch mode constraint to [enabled].
  ///
  /// Throws a [CameraWebException] if the torch mode is not supported
  /// or the camera has not been initialized or started.
  void _setTorchMode({required bool enabled}) {
    final List<web.MediaStreamTrack> videoTracks = stream?.getVideoTracks().toDart ?? <web.MediaStreamTrack>[];

    if (videoTracks.isNotEmpty) {
      final web.MediaStreamTrack defaultVideoTrack = videoTracks.first;

      final bool canEnableTorchMode = defaultVideoTrack.getCapabilities()[_torchModeKey] as bool? ?? false;

      if (canEnableTorchMode) {
        defaultVideoTrack.applyConstraints(
          MediaTrackConstraints()
            ..advanced = <MediaTrackConstraintSet>[
              MediaTrackConstraintSet()..setProperty(_torchModeKey.toJS, enabled.toJS)
            ].toJS,
        );
      } else {
        throw CameraWebException(
          textureId,
          CameraErrorCode.torchModeNotSupported,
          'The torch mode is not supported by the current camera.',
        );
      }
    } else {
      throw CameraWebException(
        textureId,
        CameraErrorCode.notStarted,
        'The camera has not been initialized or started.',
      );
    }
  }

  /// Returns the camera maximum zoom level.
  ///
  /// Throws a [CameraWebException] if the zoom level is not supported
  /// or the camera has not been initialized or started.
  double getMaxZoomLevel() => _cameraService.getZoomLevelCapabilityForCamera(this).maximum;

  /// Returns the camera minimum zoom level.
  ///
  /// Throws a [CameraWebException] if the zoom level is not supported
  /// or the camera has not been initialized or started.
  double getMinZoomLevel() => _cameraService.getZoomLevelCapabilityForCamera(this).minimum;

  /// Sets the camera zoom level to [zoom].
  ///
  /// Throws a [CameraWebException] if the zoom level is invalid,
  /// not supported or the camera has not been initialized or started.
  void setZoomLevel(double zoom) {
    final ZoomLevelCapability zoomLevelCapability = _cameraService.getZoomLevelCapabilityForCamera(this);

    if (zoom < zoomLevelCapability.minimum || zoom > zoomLevelCapability.maximum) {
      throw CameraWebException(
        textureId,
        CameraErrorCode.zoomLevelInvalid,
        'The provided zoom level must be in the range of ${zoomLevelCapability.minimum} to ${zoomLevelCapability.maximum}.',
      );
    }

    zoomLevelCapability.videoTrack.applyConstraints(
      MediaTrackConstraints()
        ..advanced = <MediaTrackConstraintSet>[
          MediaTrackConstraintSet()..setProperty(ZoomLevelCapability.constraintName.toJS, zoom.toJS)
        ].toJS,
    );
  }

  /// Returns a lens direction of this camera.
  ///
  /// Returns null if the camera is missing a video track or
  /// the video track does not include the facing mode setting.
  CameraLensDirection? getLensDirection() {
    final List<web.MediaStreamTrack> videoTracks =
        videoElement.srcObject?.callMethod('getVideoTracks'.toJS) ?? <web.MediaStreamTrack>[];

    if (videoTracks.isEmpty) {
      return null;
    }

    final web.MediaStreamTrack defaultVideoTrack = videoTracks.first;
    final String facingMode = defaultVideoTrack.getSettings().facingMode;
    return _cameraService.mapFacingModeToLensDirection(facingMode);
  }

  /// Returns the registered view type of the camera.
  String getViewType() => _getViewType(textureId);

  /// Starts a new video recording using [web.MediaRecorder].
  ///
  /// Throws a [CameraWebException] if the provided maximum video duration is invalid
  /// or the browser does not support any of the available video mime types
  /// from [_videoMimeType].
  Future<void> startVideoRecording({Duration? maxVideoDuration}) async {
    if (maxVideoDuration != null && maxVideoDuration.inMilliseconds <= 0) {
      throw CameraWebException(
        textureId,
        CameraErrorCode.notSupported,
        'The maximum video duration must be greater than 0 milliseconds.',
      );
    }

    mediaRecorder ??= web.MediaRecorder(
      videoElement.srcObject! as MediaStream,
      MediaRecorderOptions(
        mimeType: _videoMimeType,
        audioBitsPerSecond: recorderOptions.audioBitrate ?? 0,
        videoBitsPerSecond: recorderOptions.videoBitrate ?? 0,
      ),
    );

    _videoAvailableCompleter = Completer<XFile>();

    _videoDataAvailableListener = (web.Event event) => _onVideoDataAvailable(event, maxVideoDuration);

    _videoRecordingStoppedListener = (web.Event event) => _onVideoRecordingStopped(event, maxVideoDuration);

    mediaRecorder!.addEventListener(
      'dataavailable',
      _videoDataAvailableListener?.toJS,
    );

    mediaRecorder!.addEventListener(
      'stop',
      _videoRecordingStoppedListener?.toJS,
    );

    mediaRecorder?.onerror = (web.Event event) {
      final web.ErrorEvent error = event as web.ErrorEvent;
      videoRecordingErrorController.add(error);
    }.toJS;

    if (maxVideoDuration != null) {
      mediaRecorder!.start(maxVideoDuration.inMilliseconds);
    } else {
      // Don't pass the null duration as that will fire a `dataavailable` event directly.
      mediaRecorder!.start();
    }
  }

  void _onVideoDataAvailable(
    web.Event event, [
    Duration? maxVideoDuration,
  ]) {
    final web.Blob? blob = (event as web.BlobEvent).data;

    // Append the recorded part of the video to the list of all video data files.
    if (blob != null) {
      _videoData.add(blob);
    }

    // Stop the recorder if the video has a maxVideoDuration
    // and the recording was not stopped manually.
    if (maxVideoDuration != null && mediaRecorder!.state == 'recording') {
      mediaRecorder!.stop();
    }
  }

  Future<void> _onVideoRecordingStopped(
    web.Event event, [
    Duration? maxVideoDuration,
  ]) async {
    if (_videoData.isNotEmpty) {
      // Concatenate all video data files into a single blob.
      final String videoType = _videoData.first.type;
      final web.Blob videoBlob = blobBuilder(_videoData, videoType);

      // Create a file containing the video blob.
      final XFile file = XFile(
        web.URL.createObjectURL(videoBlob),
        mimeType: _videoMimeType,
        name: videoBlob.hashCode.toString(),
      );

      // Emit an event containing the recorded video file.
      videoRecorderController.add(
        VideoRecordedEvent(textureId, file, maxVideoDuration),
      );

      _videoAvailableCompleter?.complete(file);
    }

    // Clean up the media recorder with its event listeners and video data.
    mediaRecorder?.removeEventListener(
      'dataavailable',
      _videoDataAvailableListener?.toJS,
    );

    mediaRecorder?.removeEventListener(
      'stop',
      _videoDataAvailableListener?.toJS,
    );

    await _onVideoRecordingErrorSubscription?.cancel();

    mediaRecorder = null;
    _videoDataAvailableListener = null;
    _videoRecordingStoppedListener = null;
    _videoData.clear();
  }

  /// Pauses the current video recording.
  ///
  /// Throws a [CameraWebException] if the video recorder is uninitialized.
  Future<void> pauseVideoRecording() async {
    if (mediaRecorder == null) {
      throw _videoRecordingNotStartedException;
    }
    mediaRecorder!.pause();
  }

  /// Resumes the current video recording.
  ///
  /// Throws a [CameraWebException] if the video recorder is uninitialized.
  Future<void> resumeVideoRecording() async {
    if (mediaRecorder == null) {
      throw _videoRecordingNotStartedException;
    }
    mediaRecorder!.resume();
  }

  /// Stops the video recording and returns the captured video file.
  ///
  /// Throws a [CameraWebException] if the video recorder is uninitialized.
  Future<XFile> stopVideoRecording() async {
    if (mediaRecorder == null || _videoAvailableCompleter == null) {
      throw _videoRecordingNotStartedException;
    }

    mediaRecorder!.stop();

    return _videoAvailableCompleter!.future;
  }

  /// Disposes the camera by stopping the camera stream,
  /// the video recording and reloading the camera source.
  Future<void> dispose() async {
    // Stop the camera stream.
    stop();

    await videoRecorderController.close();
    mediaRecorder = null;
    _videoDataAvailableListener = null;

    // Reset the [videoElement] to its initial state.
    videoElement
      ..srcObject = null
      ..load();
      
    await onEndedController.close();

    await _onVideoRecordingErrorSubscription?.cancel();
    _onVideoRecordingErrorSubscription = null;
    await videoRecordingErrorController.close();
  }

  /// Returns the first supported video mime type (amongst mp4 and webm)
  /// to use when recording a video.
  ///
  /// Throws a [CameraWebException] if the browser does not support
  /// any of the available video mime types.
  String get _videoMimeType {
    const List<String> types = <String>[
      'video/webm;codecs="vp9,opus"',
      'video/mp4',
      'video/webm',
    ];

    return types.firstWhere(
      (String type) => web.MediaRecorder.isTypeSupported(type),
      orElse: () => throw CameraWebException(
        textureId,
        CameraErrorCode.notSupported,
        'The browser does not support any of the following video types: ${types.join(',')}.',
      ),
    );
  }

  CameraWebException get _videoRecordingNotStartedException => CameraWebException(
        textureId,
        CameraErrorCode.videoRecordingNotStarted,
        'The video recorder is uninitialized. The recording might not have been started. Make sure to call `startVideoRecording` first.',
      );

  /// Applies default styles to the video [element].
  void _applyDefaultVideoStyles(web.VideoElement element) {
    final bool isBackCamera = getLensDirection() == CameraLensDirection.back;

    // Flip the video horizontally if it is not taken from a back camera.
    if (!isBackCamera) {
      element.style.transform = 'scaleX(-1)';
    }

    element.style
      ..transformOrigin = 'center'
      ..pointerEvents = 'none'
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'cover';
  }
}
