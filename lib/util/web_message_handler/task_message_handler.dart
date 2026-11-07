import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/task_runner_service.dart';
import 'package:town_pass/util/web_message_handler/tp_web_message_handler.dart';

/// 執行任務腳本，自動操作台北通服務頁。
///
/// 網頁送 `{ id, script, slots }` 開始，送 `{ action: 'stop' }` 停止。
/// 每一步回 `{ id, status: 'partial', step, say }`，完成回 `{ id, status: 'done', result }`；
/// 失敗回 `{ id, status: 'error', code, step, message }`，
/// `code` 為 `offline`、`not_allowed`、`step_failed`、`stopped`。
class RunTaskMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'run_task';

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
    final TaskRunnerService runner = Get.find<TaskRunnerService>();

    if (message['action'] == 'stop') {
      await runner.stop();
      return;
    }

    final Object? id = message['id'];
    try {
      final Map<String, Object?> result = await runner.run(
        script: message['script'] as Map? ?? const {},
        slots: message['slots'] as Map? ?? const {},
        onStep: (step, say) => onReply?.call(replyWebMessage(
          data: {'id': id, 'status': 'partial', 'step': step, 'say': say},
        )),
      );
      onReply?.call(replyWebMessage(
        data: {'id': id, 'status': 'done', 'result': result},
      ));
    } on TaskException catch (error) {
      onReply?.call(replyWebMessage(
        data: {'id': id, 'status': 'error', 'code': error.code, 'step': error.step, 'message': error.message},
      ));
    }
  }
}
