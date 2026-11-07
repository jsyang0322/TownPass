import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/speech_service.dart';
import 'package:town_pass/util/web_message_handler/tp_web_message_handler.dart';

/// 語音辨識（只在裝置端辨識）。
///
/// 網頁送 `{ id, action: 'start', locale }` 開始聽，送 `{ action: 'stop' }` 提早結束。
/// 說話中回 `{ id, status: 'partial', text }`，使用者停頓後回 `{ id, status: 'done', text }`；
/// 失敗回 `{ id, status: 'error', code, message }`，`code` 為 `permission`、`unavailable`、`no_speech`。
class VoiceListenMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'voice_listen';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    if (message is! Map) {
      return;
    }
    final SpeechService speech = Get.find<SpeechService>();

    if (message['action'] == 'stop') {
      await speech.stopListening();
      return;
    }

    final Object? id = message['id'];
    try {
      final String text = await speech.listen(
        locale: message['locale'] ?? 'zh-TW',
        onPartial: (text) => onReply?.call(replyWebMessage(
          data: {'id': id, 'status': 'partial', 'text': text},
        )),
      );
      onReply?.call(replyWebMessage(
        data: {'id': id, 'status': 'done', 'text': text},
      ));
    } on SpeechException catch (error) {
      onReply?.call(replyWebMessage(
        data: {'id': id, 'status': 'error', 'code': error.code, 'message': error.message},
      ));
    }
  }
}

/// 語音朗讀（zh-TW，系統語音，離線可用）。
///
/// 網頁送 `{ id, text, rate? }`，念完回 `{ id, status: 'done' }`；被 `{ action: 'stop' }` 中斷時也回 `done`。
/// `rate` 為 0.5 時是正常語速，不帶時用 [SpeechService.defaultSpeechRate]。
class TtsSpeakMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'tts_speak';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    if (message is! Map) {
      return;
    }
    final SpeechService speech = Get.find<SpeechService>();

    if (message['action'] == 'stop') {
      await speech.stopSpeaking();
      return;
    }

    final Object? id = message['id'];
    try {
      await speech.speak(
        message['text'] ?? '',
        rate: (message['rate'] as num?)?.toDouble(),
      );
      onReply?.call(replyWebMessage(
        data: {'id': id, 'status': 'done'},
      ));
    } on SpeechException catch (error) {
      onReply?.call(replyWebMessage(
        data: {'id': id, 'status': 'error', 'code': error.code, 'message': error.message},
      ));
    }
  }
}
