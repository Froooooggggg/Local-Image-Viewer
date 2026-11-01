import 'package:flutter/material.dart';

/// 底部弹窗的安全外壳：**内容超高时可滚动**，不再出现
/// 「BOTTOM OVERFLOWED BY xx PIXELS」的黄黑警戒线。
///
/// 为什么需要它：`showModalBottomSheet` 的内容高度受屏幕上限约束，
/// 而 `Column(mainAxisSize: MainAxisSize.min)` **不会**因此收缩 —— 内容一旦
/// 超过上限就直接溢出。三点菜单加到 7 项、导入弹窗 3 项带副标题之后都会命中。
///
/// 它同时设置 `isScrollControlled`，让弹窗可以长到屏幕的 [maxHeightRatio]，
/// 超过则内部滚动。
class SheetShell extends StatelessWidget {
  const SheetShell({
    super.key,
    required this.child,
    this.maxHeightRatio = 0.85,
  });

  final Widget child;

  /// 最多占屏幕高度的比例。
  final double maxHeightRatio;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * maxHeightRatio;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          // 内容不高时收紧，保持"刚好包住内容"的外观。
          child: child,
        ),
      ),
    );
  }
}

/// 与 [SheetShell] 配套使用：让弹窗允许长到接近全屏。
const bool kSheetIsScrollControlled = true;
