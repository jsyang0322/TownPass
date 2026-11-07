import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:get/get.dart';

/// 裝置端 LLM 服務（flutter_edge_ai + Gemma 4 E2B，LiteRT-LM 引擎）。
///
/// 介面規格見 TPE_Codefest2026/docs/系統設計文件.md 第三節（llm_status／llm_ask）
/// 與第五節（模型與套件）。設計重點：
/// - 模型不在 App 啟動時載入；第一次收到 `llm_status` 時才開始（[warmUp]）。
/// - 手機上沒有模型檔時，從 flutter_edge_ai 的模型目錄下載 Gemma 4 E2B
///   （需要網路，demo 前要先完成；下載進度見 [downloadPercent]）。
/// - 一次只跑一個請求（[isBusy]），手機記憶體有限。
/// - 推論全程在裝置端，不呼叫任何雲端模型 API（競賽規則）。
class LlmService extends GetxService {
  /// 推論的 context window（prompt＋回覆合計）。.litertlm 最少 1024。
  /// 任務 B 的規定資料（web/src/data/faq/）約 1,500～2,000 字，加上回覆會超過 2048，所以用 4096。
  static const int contextWindowTokens = 4096;

  /// 單次回覆長度上限的預設值（任務 B 的規格建議 150）。
  static const int defaultMaxOutputTokens = 150;

  static const String stateMissing = 'missing';
  static const String stateLoading = 'loading';
  static const String stateReady = 'ready';

  String _state = stateMissing;
  String? _lastError;
  int _downloadPercent = 0;
  bool _busy = false;
  Future<void>? _warmUp;

  /// flutter_edge_ai 的 model 物件。
  /// 以 dynamic 持有：API 以 pub.dev 上 2.5.x 的 README 為準，型別名稱若有出入
  /// 不影響編譯，實機 PoC 時再確認。
  dynamic _model;

  /// `missing`（手機上沒有模型檔）、`loading`（下載或載入中）、`ready`。
  String get state => _state;

  bool get isReady => _state == stateReady;

  bool get isBusy => _busy;

  /// 模型下載進度（0–100）；僅於 [state] 為 loading 且正在下載時有意義。
  int get downloadPercent => _downloadPercent;

  /// 上一次載入失敗的原因（例如沒有網路），給網頁端顯示用。
  String? get lastError => _lastError;

  /// 載入模型，必要時先下載。可重複呼叫：
  /// 進行中或已完成時共用同一個 Future；上次失敗（例如離線）時會重新嘗試。
  Future<void> warmUp() {
    final Future<void>? inFlight = _warmUp;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> task = _initialize();
    _warmUp = task;
    return task;
  }

  Future<void> _initialize() async {
    _state = stateLoading;
    _lastError = null;
    try {
      // 手機上已有模型檔：直接載入（首次需數十秒，所以網頁一開啟就要預熱）。
      _model = await FlutterEdgeAi.getActiveModel(maxTokens: contextWindowTokens);
      _state = stateReady;
    } on NoActiveModelError {
      await _downloadAndLoad();
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _downloadAndLoad() async {
    try {
      await FlutterEdgeAi.installModelFromCatalog(LiteRtLmModels.gemma4E2bIt.generic)
          .withProgress((dynamic progress) {
            _downloadPercent = int.tryParse('$progress') ?? _downloadPercent;
          })
          .install();
      _model = await FlutterEdgeAi.getActiveModel(maxTokens: contextWindowTokens);
      _state = stateReady;
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    _state = stateMissing;
    _lastError = error.toString();
    // 清掉進行中的 Future，下一次 llm_status 會重試（例如接上網路之後）。
    _warmUp = null;
  }

  /// 串流產生文字。yield 的是「增量」片段，呼叫端自行累加
  /// （`llm_ask` 規格的 partial 要回累積全文）。
  ///
  /// 每個請求開一個全新的 chat（任務 A、B 都是單輪、無對話歷史），
  /// 模型本身保持載入狀態，不重複載入。
  Stream<String> generate({
    String? system,
    required String prompt,
    int? maxTokens,
  }) async* {
    if (!isReady) {
      throw StateError('not_ready');
    }
    if (_busy) {
      throw StateError('busy');
    }
    _busy = true;
    try {
      final dynamic chat = await _model.createChat(
        maxOutputTokens: maxTokens ?? defaultMaxOutputTokens,
      );
      // Gemma 的對話模板沒有 system 角色；官方慣例是把 system 併進第一則使用者訊息。
      final String fullPrompt =
          (system == null || system.isEmpty) ? prompt : '$system\n\n$prompt';
      // isUser: true 不能省略，預設是 false，會產生空回覆。
      await chat.addQueryChunk(Message.text(text: fullPrompt, isUser: true));
      await for (final dynamic response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          yield response.token;
        }
      }
    } finally {
      _busy = false;
    }
  }
}
