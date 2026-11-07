import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/speech_service.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';

/// 執行網頁送來的任務腳本：開啟台北通服務頁，逐步朗讀、操作，並回報進度。
///
/// `open`、`say`、`stop` 在這裡處理；`click`、`fill`、`read`、`wait` 交給注入頁面的
/// `assets/task_runner/runner.js`。腳本是開發時寫好的，LLM 只負責挑腳本、填關鍵字；
/// 執行器只開放白名單網域，腳本停在登入之前；付款拆成兩段腳本，
/// 網頁複誦金額、使用者說「對」之後才會送來第二段（見設計文件第四節安全規則）。
class TaskRunnerService extends GetxService {
  static const Set<String> allowedHosts = {'taipei-pass-service.vercel.app'};
  static const List<String> _pageSteps = ['click', 'fill', 'read', 'wait'];

  /// 操作中浮層顯示用
  final RxBool running = false.obs;
  final RxString caption = ''.obs;

  SpeechService get _speech => Get.find<SpeechService>();

  InAppWebViewController? _controller;
  Completer<void>? _pageLoaded;
  Completer<void> _stopSignal = Completer<void>();
  bool _stopped = false;
  String? _runnerJs;

  /// 目前這次執行，收尾（念完、收起浮層）後完成；沒有在執行時為 null
  Future<void>? _current;

  /// 執行 [script]，回傳 `read` 步驟讀到的內容（以 `as` 為 key）。
  ///
  /// 每一步開始時以 [onStep] 回報；失敗時丟出 [TaskException]，
  /// `code` 為 `offline`、`not_allowed`、`step_failed`、`stopped`。
  Future<Map<String, Object?>> run({
    required Map script,
    required Map slots,
    required void Function(int step, String say) onStep,
  }) async {
    // 同時只跑一個：上一個還在跑就先停掉，並等它收尾完再開始。
    // 不等的話，上一個收尾時會把 running 設回 false，這一個的浮層和停止按鈕就失效了
    while (_current case Future<void> previous) {
      await stop();
      await previous;
    }

    final Completer<void> finished = Completer<void>();
    _current = finished.future;
    _stopped = false;
    _stopSignal = Completer<void>();
    try {
      return await _run(script: script, slots: slots, onStep: onStep);
    } finally {
      _current = null;
      finished.complete();
    }
  }

  Future<Map<String, Object?>> _run({
    required Map script,
    required Map slots,
    required void Function(int step, String say) onStep,
  }) async {
    final List<Map> steps = [for (final Object? step in script['steps'] ?? const []) step as Map];
    final List<Uri> urls = [
      for (final Map step in steps)
        if (step['open'] case String url) Uri.parse(url),
    ];
    if (urls.isEmpty || urls.any((uri) => uri.scheme != 'https' || !allowedHosts.contains(uri.host))) {
      throw const TaskException('not_allowed', 0, '只能開啟台北通的服務頁');
    }
    if (!await _isOnline(urls.first.host)) {
      throw const TaskException('offline', 0, '目前沒有網路，無法開啟服務頁');
    }
    // 檢查網路的期間按了停止：還沒開頁面，直接結束
    if (_stopped) {
      throw const TaskException('stopped', 0, '已停止');
    }

    final Map<String, Object?> values = {...slots.cast<String, Object?>()};
    final Map<String, Object?> result = {};
    caption.value = '';
    running.value = true;

    int index = 0;
    try {
      for (; index < steps.length; index++) {
        final Map step = _fillValues(steps[index], values) as Map;
        final String say = switch (step) {
          {'stop': String text} => text,
          {'say': String text} => text,
          _ => '',
        };

        if (say.isNotEmpty) {
          caption.value = say;
        }
        onStep(index, say);

        // 每一步先念再做，讓使用者跟得上
        if (step['say'] case String text) {
          await _unlessStopped(_speech.speak(text), index);
        }

        if (step['open'] case String url) {
          await _unlessStopped(_open(url), index);
        } else if (step['stop'] case String text) {
          await _unlessStopped(_speech.speak(text), index);
          return result;
        } else if (_pageSteps.any(step.containsKey)) {
          final Object? value = await _unlessStopped(_runOnPage(step, index), index);
          if (step['read'] case {'as': String name}) {
            values[name] = value;
            result[name] = value;
          }
        }
      }
      return result;
    } on TaskException catch (error) {
      if (error.code == 'stopped') {
        await _speech.speak('好的，已經停止。');
      } else {
        caption.value = '這一步沒有成功';
        await _speech.speak('這一步沒有成功，頁面已經打開，您可以自己接著操作。');
      }
      rethrow;
    } catch (error) {
      caption.value = '這一步沒有成功';
      await _speech.speak('這一步沒有成功，頁面已經打開，您可以自己接著操作。');
      throw TaskException('step_failed', index, error.toString());
    } finally {
      running.value = false;
    }
  }

  /// 使用者按了浮層的停止、返回，或網頁送了 `{ action: 'stop' }`。
  Future<void> stop() async {
    // 看 _current 而不是 running：檢查網路的期間 running 還是 false，這時也要能停
    if (_current == null || _stopped) {
      return;
    }
    _stopped = true;
    _stopSignal.complete();
    await _speech.stopSpeaking();
  }

  /// 執行任務的服務頁建立 WebView 時呼叫。
  void attach(InAppWebViewController controller) {
    _controller = controller;
  }

  /// 執行任務的服務頁關閉時呼叫；還在執行就當成停止。
  void detach() {
    _controller = null;
    stop();
  }

  /// 服務頁每次載入完成（onLoadStop）時呼叫。
  void onPageLoaded() {
    final Completer<void>? pageLoaded = _pageLoaded;
    if (pageLoaded != null && !pageLoaded.isCompleted) {
      pageLoaded.complete();
    }
  }

  Future<void> _open(String url) async {
    _pageLoaded = Completer<void>();
    if (_controller case InAppWebViewController controller) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      // 不 await：toNamed 要等頁面關閉才會回傳。
      // 助手網頁本身也是 webView 路由，GetX 預設會擋掉重複的路由，所以要關掉 preventDuplicates
      Get.toNamed(
        TPRoute.webView,
        arguments: WebViewArgument(url: url, runsTask: true),
        preventDuplicates: false,
      );
    }
    await _pageLoaded!.future.timeout(const Duration(seconds: 20));
  }

  Future<Object?> _runOnPage(Map step, int index) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) {
      throw TaskException('step_failed', index, '服務頁沒有開啟');
    }

    // 每一步都注入：示範站是 Vue 單頁應用，換頁不一定觸發 onLoadStop；
    // runner.js 會檢查版本，重複注入不會重複定義
    _runnerJs ??= await rootBundle.loadString('assets/task_runner/runner.js');
    await controller.evaluateJavascript(source: _runnerJs!);

    final CallAsyncJavaScriptResult? reply = await controller.callAsyncJavaScript(
      functionBody: 'return await window.__tpRunner.run(step);',
      arguments: {'step': step},
    );
    return switch (reply?.value) {
      {'ok': true, 'value': final Object? value} => value,
      {'message': final Object? message} => throw TaskException('step_failed', index, '$message'),
      _ => throw TaskException('step_failed', index, reply?.error ?? '頁面沒有回應'),
    };
  }

  /// 等 [work] 完成；中途按了停止就立刻結束，不等頁面上的動作做完。
  Future<T> _unlessStopped<T>(Future<T> work, int index) async {
    final Object? value = await Future.any<Object?>([work, _stopSignal.future]);
    if (_stopped) {
      throw TaskException('stopped', index, '已停止');
    }
    return value as T;
  }

  /// 把步驟中的 `{plate}` 這類寫法換成關鍵字或前面 `read` 讀到的值。
  Object? _fillValues(Object? value, Map<String, Object?> values) {
    return switch (value) {
      String text => text.replaceAllMapped(
          RegExp(r'\{(\w+)\}'),
          (match) => '${values[match[1]] ?? match[0]}',
        ),
      Map map => {for (final MapEntry entry in map.entries) entry.key: _fillValues(entry.value, values)},
      List list => [for (final Object? item in list) _fillValues(item, values)],
      _ => value,
    };
  }

  Future<bool> _isOnline(String host) async {
    try {
      final List<InternetAddress> addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}

class TaskException implements Exception {
  final String code;
  final int step;
  final String message;

  const TaskException(this.code, this.step, this.message);

  @override
  String toString() => 'TaskException($code, step $step): $message';
}
