import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 語音辨識與語音朗讀，供 `voice_listen`、`tts_speak` 與腳本執行器使用。
///
/// 辨識一律要求在裝置端進行（`onDevice: true`），裝置不支援時回報 `unavailable`。
/// 第一次使用時才初始化，避免一開 App 就跳出麥克風權限視窗。
class SpeechService extends GetxService {
  /// 兩個平台都是 0.5 為正常語速（flutter_tts 在 Android 端會乘 2），長輩用的預設值稍慢。
  static const double defaultSpeechRate = 0.42;

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttReady = false;
  bool _ttsReady = false;
  final Map<String, String> _localeIds = {};

  Completer<String>? _listening;
  void Function(String text)? _onPartial;
  String _lastWords = '';

  Completer<void>? _speaking;

  /// 開始聽，使用者停頓後回傳辨識結果；說話中以 [onPartial] 回報目前的文字。
  ///
  /// 失敗時丟出 [SpeechException]，`code` 為 `permission`、`unavailable`、`no_speech`。
  Future<String> listen({
    String locale = 'zh-TW',
    void Function(String text)? onPartial,
  }) async {
    // 避免把正在念的話辨識進去
    await stopSpeaking();
    if (Platform.isIOS) {
      // 朗讀剛停就開始聽，iOS 的音訊可能還沒切換好（speech_to_text README 的建議）
      await Future.delayed(const Duration(milliseconds: 300));
    }

    await _ensureStt();

    // 上一輪還沒結束：先停掉並等它結束，避免上一輪較晚到的事件把這一輪也結束掉
    if (_listening case Completer<String> previous) {
      await _stt.stop();
      await previous.future
          .then<void>((_) {}, onError: (_) {})
          .timeout(const Duration(seconds: 2), onTimeout: () => _finishListening());
    }

    final Completer<String> completer = Completer<String>();
    _listening = completer;
    _onPartial = onPartial;
    _lastWords = '';

    try {
      await _stt.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          localeId: await _localeIdFor(locale),
          onDevice: true,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          // 長輩說話停頓較長，先設 3 秒，實測後再調
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 30),
        ),
      );
    } catch (error) {
      // iOS 不支援裝置端辨識時會在這裡失敗
      _finishListening(error: SpeechException('unavailable', error.toString()));
    }

    return completer.future;
  }

  /// 提早結束辨識，已經聽到的內容會照常回傳。
  Future<void> stopListening() async {
    if (_listening == null) {
      return;
    }
    await _stt.stop();
  }

  /// 念出 [text]，念完或被 [stopSpeaking] 中斷後才回傳。
  Future<void> speak(String text, {double? rate}) async {
    await _ensureTts();
    await stopSpeaking();

    final Completer<void> completer = Completer<void>();
    _speaking = completer;

    await _tts.setSpeechRate(rate ?? defaultSpeechRate);
    final Object? result = await _tts.speak(text);
    if (result != 1) {
      _finishSpeaking(error: '無法朗讀');
    }

    return completer.future;
  }

  Future<void> stopSpeaking() async {
    if (_speaking == null) {
      return;
    }
    await _tts.stop();
    // iOS 停止朗讀時不會觸發完成的回呼，在這裡自己結束
    _finishSpeaking();
  }

  Future<void> _ensureStt() async {
    if (_sttReady) {
      return;
    }

    final bool available = await _stt.initialize(
      onStatus: _onStatus,
      onError: _onError,
    );
    if (!available) {
      throw switch (await _stt.hasPermission) {
        true => const SpeechException('unavailable', '這支手機無法使用語音辨識'),
        false => const SpeechException('permission', '沒有麥克風或語音辨識權限'),
      };
    }
    _sttReady = true;
  }

  Future<void> _ensureTts() async {
    if (_ttsReady) {
      return;
    }

    await _tts.setLanguage('zh-TW');
    if (Platform.isIOS) {
      // playback：手機切到靜音模式也念得出來
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [],
        IosTextToSpeechAudioMode.voicePrompt,
      );
    }
    // 不設 cancel handler：stop() 之後才收到的 cancel 會誤結束下一句
    _tts.setCompletionHandler(() => _finishSpeaking());
    _tts.setErrorHandler((message) => _finishSpeaking(error: message.toString()));
    _ttsReady = true;
  }

  /// 各平台的繁中 locale 寫法不同（`zh_TW`、`zh-TW`、`cmn-Hant-TW`），
  /// 從手機支援的清單中找出語言與地區都符合的那一個。
  Future<String> _localeIdFor(String locale) async {
    if (_localeIds[locale] case String localeId) {
      return localeId;
    }

    final List<String> parts = locale.toLowerCase().split(RegExp('[-_]'));
    final String language = parts.first;
    final String region = parts.last;

    String result = locale;
    for (final LocaleName name in await _stt.locales()) {
      final List<String> candidate = name.localeId.toLowerCase().split(RegExp('[-_]'));
      final bool sameLanguage = candidate.first == language || (language == 'zh' && candidate.first == 'cmn');
      if (sameLanguage && candidate.last == region) {
        result = name.localeId;
        break;
      }
    }

    _localeIds[locale] = result;
    return result;
  }

  void _onResult(SpeechRecognitionResult result) {
    _lastWords = result.recognizedWords;
    if (result.finalResult) {
      _finishListening();
    } else {
      _onPartial?.call(_lastWords);
    }
  }

  void _onStatus(String status) {
    // 沒有最終結果就結束（例如使用者沒說話）
    if (status == SpeechToText.doneStatus) {
      _finishListening();
    }
  }

  void _onError(SpeechRecognitionError error) {
    final String code = switch (error.errorMsg) {
      'error_permission' || 'error_speech_recognizer_request_not_authorized' => 'permission',
      'error_no_match' || 'error_speech_timeout' => 'no_speech',
      _ => 'unavailable',
    };
    _finishListening(error: SpeechException(code, error.errorMsg));
  }

  void _finishListening({SpeechException? error}) {
    final Completer<String>? completer = _listening;
    _listening = null;
    _onPartial = null;
    if (completer == null || completer.isCompleted) {
      return;
    }

    if (error != null) {
      completer.completeError(error);
    } else if (_lastWords.isEmpty) {
      completer.completeError(const SpeechException('no_speech', '沒有聽到說話'));
    } else {
      completer.complete(_lastWords);
    }
  }

  void _finishSpeaking({String? error}) {
    final Completer<void>? completer = _speaking;
    _speaking = null;
    if (completer == null || completer.isCompleted) {
      return;
    }

    if (error != null) {
      completer.completeError(SpeechException('failed', error));
    } else {
      completer.complete();
    }
  }
}

class SpeechException implements Exception {
  final String code;
  final String message;

  const SpeechException(this.code, this.message);

  @override
  String toString() => 'SpeechException($code): $message';
}
