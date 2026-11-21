import 'dart:io';

import 'package:flutter/services.dart';
import 'package:medito/providers/player/player_provider.dart';

class PlaybackAccount {
  static const _channel = MethodChannel('intronauts/playback_account');

  static Future<void> bind(String clientId, {String? userId}) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('bind', {
        'clientId': clientId,
        'userId': ?userId,
      });
    }
  }

  static Future<void> clear() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('clear');
    } else if (Platform.isIOS) {
      await iosAudioHandler.stop();
    }
  }
}
