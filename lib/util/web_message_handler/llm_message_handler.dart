import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/llm_service.dart';
import 'package:town_pass/util/web_message_handler/tp_web_message_handler.dart';

/// `llm_status`：回報裝置端模型狀態，並順便預熱。
///
/// 規格（docs/系統設計文件.md 第三節）：
/// - 網頁 → App：`{ id }`
/// - App → 網頁：`{ id, status: 'done', state }`，
///   `state` 為 `missing`／`loading`／`ready`。
/// - 收到時如果模型還沒載入，就開始載入；網頁一打開就送一次，順便預熱，
///   之後輪詢到 `ready` 為止。載入中會多帶 `progress`（下載百分比）。
class LlmStatusMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'llm_status';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    final Object? id = (message is Map) ? message['id'] : null;
    final LlmService llm = Get.find<LlmService>();

    // 開始（或重試）載入，但不等它完成——立刻回覆目前狀態，網頁端輪詢。
    if (!llm.isReady) {
      unawaited(llm.warmUp());
    }

    onReply?.call(replyWebMessage(data: {
      if (id != null) 'id': id,
      'status': 'done',
      'state': llm.state,
      if (llm.state == LlmService.stateLoading) 'progress': llm.downloadPercent,
      if (llm.lastError != null) 'message': llm.lastError,
    }));
  }
}

/// `llm_ask`：裝置端 LLM 推論（串流）。
///
/// 規格（docs/系統設計文件.md 第三節）：
/// - 網頁 → App：`{ id, system, prompt, maxTokens }`；prompt 由網頁組好，
///   App 只負責推論，維持通用。
/// - App → 網頁：`partial`（累積全文）、`done`、
///   `error`（code 為 `not_ready`、`busy`、`failed`）。
/// - 一次只跑一個請求，忙碌時回 `busy`。
class LlmAskMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'llm_ask';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    // 網頁逾時或取消時送 { action: 'stop' }：中止目前的推論，釋放 busy（不回覆）
    if (message is Map && message['action'] == 'stop') {
      await Get.find<LlmService>().stopGeneration();
      return;
    }
    if (message is! Map) {
      onReply?.call(replyWebMessage(data: {
        'status': 'error',
        'code': 'failed',
        'message': 'llm_ask 的 data 必須是物件',
      }));
      return;
    }
    final Map data = message;
    final Object? id = data['id'];
    final LlmService llm = Get.find<LlmService>();

    if (!llm.isReady || llm.isBusy) {
      onReply?.call(replyWebMessage(data: {
        if (id != null) 'id': id,
        'status': 'error',
        'code': llm.isReady ? 'busy' : 'not_ready',
      }));
      return;
    }

    String text = '';
    try {
      await for (final String chunk in llm.generate(
        system: data['system'] as String?,
        prompt: data['prompt'] as String? ?? '',
        maxTokens: data['maxTokens'] as int?,
      )) {
        text += chunk;
        onReply?.call(replyWebMessage(data: {
          if (id != null) 'id': id,
          'status': 'partial',
          'text': text,
        }));
      }
      onReply?.call(replyWebMessage(data: {
        if (id != null) 'id': id,
        'status': 'done',
        'text': text,
      }));
    } catch (error) {
      onReply?.call(replyWebMessage(data: {
        if (id != null) 'id': id,
        'status': 'error',
        'code': 'failed',
        'message': error.toString(),
      }));
    }
  }
}
