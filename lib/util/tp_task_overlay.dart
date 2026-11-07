import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/task_runner_service.dart';
import 'package:town_pass/util/tp_button.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// 腳本執行中疊在服務頁上的浮層：上方「操作中」與目前步驟的字幕，底部大的「停止」按鈕。
///
/// 執行結束後浮層收起，頁面交還使用者自己操作。[enabled] 為 false 時直接顯示 [child]。
class TPTaskOverlay extends StatefulWidget {
  final bool enabled;
  final Widget child;

  const TPTaskOverlay({
    super.key,
    required this.enabled,
    required this.child,
  });

  @override
  State<TPTaskOverlay> createState() => _TPTaskOverlayState();
}

class _TPTaskOverlayState extends State<TPTaskOverlay> {
  TaskRunnerService get _runner => Get.find<TaskRunnerService>();

  @override
  void dispose() {
    // 頁面關閉（關閉按鈕、返回、滑動返回）時，還在執行就停止
    if (widget.enabled) {
      _runner.detach();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return Stack(
      children: [
        widget.child,
        Obx(
          () => switch (_runner.running.value) {
            false => const SizedBox.shrink(),
            true => SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: TPColors.grayscale900.withValues(alpha: 0.9),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const TPText('操作中', style: TPTextStyles.bodySemiBold, color: TPColors.secondary500),
                          const SizedBox(height: 4),
                          TPText(_runner.caption.value, style: TPTextStyles.h3Regular, color: TPColors.white),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        height: 64,
                        child: TPButton.alarm(
                          text: '停止',
                          onPressed: _runner.stop,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          },
        ),
      ],
    );
  }
}
