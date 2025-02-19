import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'client.dart';
import 'logger.dart';

class FrameRate {
  FrameRate({required this.ideal, required this.max});
  int ideal;
  int max;
  Map<String, dynamic> toMap() => {
        'ideal': ideal,
        'max': max,
      };
}

class MediaTrackConstraints {
  MediaTrackConstraints({required this.frameRate, required this.height, required this.width});

  /// Properties of video tracks
  FrameRate frameRate;
  int height;
  int width;

  Map<String, dynamic> toMap() => {
        'width': {'ideal': width},
        'height': {'ideal': height},
        'frameRate': frameRate.toMap()
      };
}

class VideoConstraints {
  VideoConstraints({required this.constraints, required this.encodings});
  final MediaTrackConstraints constraints;
  final RTCRtpEncoding encodings;
}

var resolutions = ['qvga', 'vga', 'shd', 'hd', 'fhd', 'qhd'];

var videoConstraints = <String, VideoConstraints>{
  'qvga': VideoConstraints(
      constraints: MediaTrackConstraints(width: 320, height: 180, frameRate: FrameRate(ideal: 15, max: 30)), encodings: RTCRtpEncoding(maxBitrate: 150000, maxFramerate: 15)),
  'vga': VideoConstraints(
      constraints: MediaTrackConstraints(width: 640, height: 360, frameRate: FrameRate(ideal: 30, max: 60)), encodings: RTCRtpEncoding(maxBitrate: 500000, maxFramerate: 30)),
  'shd': VideoConstraints(
      constraints: MediaTrackConstraints(width: 960, height: 540, frameRate: FrameRate(ideal: 30, max: 60)), encodings: RTCRtpEncoding(maxBitrate: 1200000, maxFramerate: 30)),
  'hd': VideoConstraints(
      constraints: MediaTrackConstraints(width: 1280, height: 720, frameRate: FrameRate(ideal: 30, max: 60)), encodings: RTCRtpEncoding(maxBitrate: 2500000, maxFramerate: 30)),
  'fhd': VideoConstraints(
      constraints: MediaTrackConstraints(width: 1920, height: 1080, frameRate: FrameRate(ideal: 30, max: 60)), encodings: RTCRtpEncoding(maxBitrate: 4000000, maxFramerate: 30)),
  'qhd': VideoConstraints(
      constraints: MediaTrackConstraints(width: 2560, height: 1440, frameRate: FrameRate(ideal: 30, max: 60)), encodings: RTCRtpEncoding(maxBitrate: 8000000, maxFramerate: 30)),
};

enum Layer { none, low, medium, high }

Map<Layer, String> layerStringType = {Layer.none: 'none', Layer.low: 'low', Layer.medium: 'medium', Layer.high: 'high'};

class Encoding {
  Layer? layer;
  int? maxBitrate;
  int? maxFramerate;
}

class Constraints {
  Constraints({this.resolution, this.deviceId, this.codec, this.audio, this.video, this.simulcast});
  String? resolution;
  String? codec;
  bool? simulcast;
  bool? audio;
  bool? video;
  String? deviceId;

  static final defaults = Constraints(resolution: 'hd', codec: 'vp8', audio: true, video: true, simulcast: false);
}

class LocalStream {
  LocalStream(this._stream, this._constraints);
  final Constraints _constraints;
  RTCPeerConnection? _pc;
  final MediaStream _stream;

  MediaStream get stream => _stream;

  static Future<LocalStream> getUserMedia({Constraints? constraints}) async {
    var stream = await navigator.mediaDevices.getUserMedia(
        {'audio': LocalStream.computeAudioConstraints(constraints ?? Constraints.defaults), 'video': LocalStream.computeVideoConstraints(constraints ?? Constraints.defaults)});
    return LocalStream(stream, constraints ?? Constraints.defaults);
  }

  static Future<LocalStream> getDisplayMedia({Constraints? constraints}) async {
    var stream = await navigator.mediaDevices.getDisplayMedia({
      'video': true,
    });
    return LocalStream(stream, Constraints.defaults);
  }

  static dynamic computeAudioConstraints(Constraints constraints) {
    if (constraints.audio != null) {
      return true;
    } else if (constraints.video! && constraints.resolution != null) {
      return {'deviceId': constraints.deviceId};
    }
    return false;
  }

  static dynamic computeVideoConstraints(Constraints constraints) {
    if (constraints.video! && constraints.resolution == null) {
      return true;
    } else if (constraints.video! && constraints.resolution != null) {
      var resolution = videoConstraints[constraints.resolution]!.constraints;
      var mobileConstraints = WebRTC.platformIsWeb
          ? {}
          : {
              'mandatory': {
                'minWidth': '1280',
                'minHeight': '720',
                'minFrameRate': '30',
              },
              'facingMode': 'user',
              'optional': []
            };
      return {...resolution.toMap(), ...mobileConstraints};
    }
    return false;
  }

  /// 'audio' | 'video'
  MediaStreamTrack? getTrack(String kind) {
    var tracks;
    if (kind == 'video') {
      tracks = _stream.getVideoTracks();
      return tracks.length > 0 ? _stream.getVideoTracks()[0] : null;
    }
    tracks = _stream.getAudioTracks();
    return tracks.length > 0 ? _stream.getAudioTracks()[0] : null;
  }

  /// 'audio' | 'video'
  Future<MediaStreamTrack> getNewTrack(String kind) async {
    var stream = await navigator.mediaDevices.getUserMedia({
      kind: kind == 'video' ? LocalStream.computeVideoConstraints(_constraints) : LocalStream.computeAudioConstraints(_constraints),
    });
    return stream.getTracks()[0];
  }

  void publishTrack({required MediaStreamTrack track}) async {
    if (_pc != null) {
      if (track.kind == 'video' && _constraints.simulcast!) {
        var idx = resolutions.indexOf(_constraints.resolution!);
        var encodings = <RTCRtpEncoding>[
          RTCRtpEncoding(
            rid: 'f',
            active: true,
            maxBitrate: videoConstraints[resolutions[idx]]!.encodings.maxBitrate,
            minBitrate: 256000,
            scaleResolutionDownBy: 1.0,
            maxFramerate: videoConstraints[resolutions[idx]]!.encodings.maxFramerate,
          )
        ];

        if (idx - 1 >= 0) {
          encodings.add(RTCRtpEncoding(
            rid: 'h',
            active: true,
            scaleResolutionDownBy: 2.0,
            maxBitrate: videoConstraints[resolutions[idx - 1]]!.encodings.maxBitrate,
            minBitrate: 128000,
            maxFramerate: videoConstraints[resolutions[idx - 1]]!.encodings.maxFramerate,
          ));
        }

        if (idx - 2 >= 0) {
          encodings.add(RTCRtpEncoding(
            rid: 'q',
            active: true,
            minBitrate: 64000,
            scaleResolutionDownBy: 4.0,
            maxBitrate: videoConstraints[resolutions[idx - 2]]!.encodings.maxBitrate,
            maxFramerate: videoConstraints[resolutions[idx - 2]]!.encodings.maxFramerate,
          ));
        }

        var transceiver = await _pc?.addTransceiver(
            track: track,
            init: RTCRtpTransceiverInit(
              streams: [_stream],
              direction: TransceiverDirection.SendOnly,
              sendEncodings: encodings,
            ));
        setPreferredCodec(transceiver);
      } else {
        var transceiver = await _pc?.addTransceiver(
            track: track,
            init: RTCRtpTransceiverInit(
              streams: [_stream],
              direction: TransceiverDirection.SendOnly,
              sendEncodings: track.kind == 'video' ? [videoConstraints[_constraints.resolution]!.encodings] : [],
            ));
        if (track.kind == 'video') {
          setPreferredCodec(transceiver);
        }
      }
    }
  }

  void setPreferredCodec(RTCRtpTransceiver? transceiver) {
    // TODO(cloudwebrtc): need to add implementation in flutter-webrtc.
    /*
    if ('setCodecPreferences' in transceiver) {
      var  cap = RTCRtpSender.getCapabilities('video');
      if (!cap) return;
      var  selCodec = cap.codecs.find(
        (c) => c.mimeType == `video/${Constraints.codec.toUpperCase()}` || c.mimeType == `audio/OPUS`,
      );
      if (selCodec) {
        transceiver.setCodecPreferences([selCodec]);
      }
    }
    */
  }

//!!  prev 를 없애지말고  sender에서만 스탑을 하고 계속 replaceTrack 으로 대체하면 안되나??
  Future<void> updateTrack_({
    required MediaStreamTrack next,
    /* MediaStreamTrack? prev */
  }) async {
    //await _stream.addTrack(next);
    // If published, replace published track with track from new device
    if (next.enabled) {
      // await _stream.removeTrack(prev);
      //await prev.stop();
      if (_pc != null) {
        await _pc!.getSenders().then((senders) => senders.forEach((RTCRtpSender sender) {
              if (sender.track?.kind == next.kind) {
                //sender.track?.stop(); //이걸 스탑해버리면 replacetrack 에서 track 이 null 이라고 오류남..
                sender.replaceTrack(next); //MediaStreamTrack has been disposed.  두번째 부터는 이렇게 나옴..
              }
            }));
      }
    } else {
      await _stream.addTrack(next);

      if (_pc != null) {
        publishTrack(track: next);
      }
    }
  }

  Future<void> updateTrack({required MediaStreamTrack? next, MediaStreamTrack? prev}) async {
    //await _stream.addTrack(next);
    // If published, replace published track with track from new device

    if (next != null && prev != null && prev.enabled) {
      // await _stream.removeTrack(prev);
      //  await prev.stop();

      if (_pc != null) {
        print('replaceTrack   pc 가 null 인가??  $_pc');
        await _pc!.getSenders().then((senders) => senders.forEach((RTCRtpSender sender) {
              print('replaceTrack 할건가  sender   ${sender.track}');
              if (sender.track?.kind == next.kind) {
                print('replaceTrack 할건가');
                //   sender.track?.stop();
                sender.replaceTrack(next);
              }
            }));
      }
    } else {
      print('replaceTrack 안할건가'); //!! 계속 replace 를 안하고 계속 새로 publish 를 해버리네...   이게 문젠데...
      await _stream.addTrack(next!);

      if (_pc != null) {
        publishTrack(track: next);
      }
    }
  }

  Future<void> publish(RTCPeerConnection pc) async {
    _pc = pc;
    _stream.getTracks().forEach((track) async => publishTrack(track: track));
  }

  Future<void> unpublish() async {
    if (_pc != null) {
      var tracks = _stream.getTracks();
      await _pc!.getSenders().then((senders) => senders.forEach((RTCRtpSender s) async {
            //  if (tracks.contains((e) => s.track?.id == e.id)) {
            if (tracks.firstWhereOrNull((e) => s.track?.id == e.id) != null) {
              if (s.track != null) {
                await _pc?.removeTrack(s);
              }
              // await s.track!.stop();
            }
          }));
    }
  }

  /// 'audio' | 'video'
  Future<void> switchDevice(String kind, {required String deviceId}) async {
    _constraints.deviceId = deviceId;
    var prev = getTrack(kind);
    var next = await getNewTrack(kind);
    await updateTrack(next: next, prev: prev);
  }

  // 'audio' | 'video'
  Future<void> mute(String kind) async {
    return;
    var track = getTrack(kind);
    if (track != null) {
      print('mute mute mute :: $kind');
      print(track);

      // await _stream.removeTrack(track); //!! 이걸 안써서   unmute 때 track null 이라고 removetrack 에서 오류 나는거 아닌가???   //!!!!!!! 하 씨발 맞네.....
      //!! 그래도 똑같이 서버에서는 잔여 track 이 남아있네...
      // await track.stop(); //!! 이게 나중이어야 함..

      if (_pc != null) {
        await _pc!.getSenders().then((senders) => senders.forEach((RTCRtpSender sender) async {
              if (sender.track?.kind == track.kind) {
                if (sender.track != null) {
                  await _pc?.removeTrack(sender);
                }
                await sender.track?.stop();
                //  sender.replaceTrack(next);
              }
            }));
      }
    }
  }
  //todo 근데 일단 mute unmute 는 로컬에서 되는거 같은데.. 문제는 로컬에서 로컬 스트림 화면도 멈춘다는거.......
  //todo 이걸 mute unmute 를 활용해서 publish unpublish 를 하면?? 아님 mute 를 서버에  await s.track!.stop();  하게 하면??

  /// 'audio' | 'video'
  Future<void> unmute_(String kind) async {
    var prev = getTrack(kind);
    print('prev');
    print(prev);
    var track = await getNewTrack(kind);
    await updateTrack(
      next: prev!, /* prev: prev */
    );
  }

  /// 'audio' | 'video'
  Future<void> unmute(String kind) async {
    var prev = getTrack(kind);
    var track = await getNewTrack(kind);
    print('prev');
    print(prev); //!! mute 때 removetrack 을 해서 그런가...   null 이 되네...
    await updateTrack(next: prev!, prev: prev);
  }
}

class RemoteStream {
  RTCDataChannel? api;
  late MediaStream stream;
  late bool audio;
  late Layer video;
  late Layer _videoPreMute;
  String get id => stream.id;

  Function(Layer layer)? preferLayer;
  Function(String kind)? mute;
  Function(String kind)? unmute;
}

final jsonEncoder = JsonEncoder();
RemoteStream makeRemote(MediaStream stream, Transport transport) {
  var remote = RemoteStream();
  remote.stream = stream;
  remote.audio = true;
  remote.video = Layer.none;
  remote._videoPreMute = Layer.high;

  var select = () {
    var call = {
      'streamId': remote.id,
      'video': layerStringType[remote.video],
      'audio': remote.audio,
    };
    if (transport.api == null) {
      log.warn('api datachannel not ready yet');
    }

    if (transport.api == null || (transport.api != null && transport.api?.state != RTCDataChannelState.RTCDataChannelOpen)) {
      /// queue call if we aren't open yet
      transport.onapiopen = () {
        transport.api?.send(RTCDataChannelMessage(jsonEncoder.convert(call)));
      };
    }

    transport.api?.send(RTCDataChannelMessage(jsonEncoder.convert(call)));
  };

  remote.preferLayer = (Layer layer) {
    remote.video = layer;
    select();
  };

  remote.mute = (kind) {
    if (kind == 'audio') {
      remote.audio = false;
    } else if (kind == 'video') {
      remote._videoPreMute = remote.video;
      remote.video = Layer.none;
    }
    select();
  };

  remote.unmute = (kind) {
    if (kind == 'audio') {
      remote.audio = true;
    } else if (kind == 'video') {
      remote.video = remote._videoPreMute;
    }
    select();
  };

  return remote;
}
