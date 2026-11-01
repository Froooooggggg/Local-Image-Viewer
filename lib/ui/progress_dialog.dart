import 'package:flutter/material.dart';

/// 带取消按钮的模态进度框。
///
/// 需求：导入图集的过程中要能中断。取消是**协作式**的 ——
/// 调用方在每一项的边界检查 [ProgressHandle.cancelled]，已完成的项保留，
/// 不再开始新的项（不做强杀，避免留下写了一半的索引）。
class ProgressHandle {
  ProgressHandle._();

  final ValueNotifier<String> _text = ValueNotifier<String>('处理中…');
  final ValueNotifier<double?> _value = ValueNotifier<double?>(null);
  bool _cancelled = false;

  /// 用户是否点了取消。
  bool get cancelled => _cancelled;

  /// 更新进度。[total] 为 0 时显示不确定进度。
  void update(int done, int total, String label) {
    if (total > 0) {
      _value.value = (done / total).clamp(0.0, 1.0);
      _text.value = '$label（$done/$total）';
    } else {
      _value.value = null;
      _text.value = label;
    }
  }

  /// 只改文字，保持当前进度值。
  void setText(String label) => _text.value = label;
}

/// 弹出进度框，返回控制句柄与关闭回调。
///
/// 接收 [NavigatorState] 而不是 BuildContext：调用点通常位于 `await`
/// （选择文件）之后，直接传 Navigator 可以避免"跨异步间隙使用 BuildContext"，
/// 也省掉每个调用点各自取 context 的样板代码。
({ProgressHandle handle, Future<void> Function() finish}) showProgressDialog(
  NavigatorState navigator, {
  String initial = '处理中…',
  bool cancellable = true,
}) {
  final context = navigator.context;
  final handle = ProgressHandle._();
  handle._text.value = initial;

  final done = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: handle._value,
              builder: (_, progress, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 40,
                        child: progress == null
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                '${(progress * 100).round()}%',
                                style: const TextStyle(fontSize: 12),
                              ),
                      ),
                      Expanded(
                        child: ValueListenableBuilder<String>(
                          valueListenable: handle._text,
                          builder: (_, t, _) => Text(
                            t,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: const Color(0xFF26262C),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '大压缩包首次导入需要一些时间，请勿退出。',
              style: TextStyle(fontSize: 11, color: Color(0xFF8B8F98)),
            ),
          ],
        ),
        actions: [
          if (cancellable)
            TextButton(
              onPressed: () {
                // 只置标志：由调用方在安全的边界停止，避免打断写入。
                handle._cancelled = true;
                handle._text.value = '正在取消…';
              },
              child: const Text('取消'),
            ),
        ],
      ),
    ),
  );

  return (
    handle: handle,
    finish: () async {
      navigator.pop();
      await done;
      // 对话框退场动画可能还没跑完，此时 dispose 会抛错，推迟到帧结束。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handle._text.dispose();
        handle._value.dispose();
      });
    },
  );
}
