import 'package:flutter/material.dart';

/// 单行文本：**放得下就静止，放不下就自动来回滚动**。
///
/// 需求：应用里名称展示不全，需要增加显示区域；若影响排版可以用滚动的字体。
///
/// 为什么不用简单的省略号：图集名往往前几十个字符都相同（同一合集的不同卷），
/// 省略号恰好把区别最大的尾部裁掉。滚动能在**不改变排版高度**的前提下
/// 让用户看到完整名称。
///
/// 实现要点：
///   * 用 [LayoutBuilder] 拿到可用宽度，再用 TextPainter 量出文本实际宽度，
///     只有真正溢出时才启动动画（放得下就完全静止，不做无谓的重绘）。
///   * 滚动到底后停顿一下再回到开头，避免来回摆动过于急促。
///   * 不可见时不跑动画（TickerMode 关闭时自动暂停）。
class AutoScrollText extends StatefulWidget {
  const AutoScrollText(
    this.text, {
    super.key,
    this.style,
    this.gap = 48,
    this.pause = const Duration(milliseconds: 1200),
    this.pixelsPerSecond = 26,
  });

  final String text;
  final TextStyle? style;

  /// 滚到尾部后，文本末尾与开头之间的留白（逻辑像素）。
  final double gap;

  /// 每次到达一端后的停顿时长。
  final Duration pause;

  final double pixelsPerSecond;

  @override
  State<AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<AutoScrollText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _scrollController = ScrollController();

  double _textWidth = 0;
  bool _needsScroll = false;
  double _lastMaxWidth = -1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
  }

  void _onTick() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_controller.value);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 到尾部后停顿，再回到开头重新开始。
    Future<void>.delayed(widget.pause, () {
      if (!mounted || !_needsScroll) return;
      _scrollController.jumpTo(0);
      _controller.value = 0;
      _start();
    });
  }

  void _start() {
    if (!_needsScroll) return;
    _controller.duration = Duration(
      milliseconds: ((_textWidth + widget.gap) / widget.pixelsPerSecond * 1000)
          .round(),
    );
    _controller.forward(from: 0);
  }

  /// 每帧量一次，**只在"是否需要滚动"发生变化时** setState。
  ///
  /// 不在 LayoutBuilder 里排回调：那样每帧都会排一次测量并触发重建，
  /// 形成无谓的持续重绘。这里只在状态真正翻转时才更新界面。
  void _sync({required double maxWidth}) {
    if (!mounted || maxWidth <= 0) return;
    if (_textWidth > 0 && maxWidth == _lastMaxWidth) return;

    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    _lastMaxWidth = maxWidth;

    final needs = painter.width > maxWidth + 0.5;
    if (needs == _needsScroll && painter.width == _textWidth) return;

    _textWidth = painter.width;
    _needsScroll = needs;
    // 不能在 build 期间 setState，推迟到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      if (_needsScroll) {
        _start();
      } else {
        _controller.stop();
        _controller.value = 0;
      }
    });
  }

  @override
  void didUpdateWidget(AutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.stop();
      _controller.value = 0;
      _textWidth = 0;
      _lastMaxWidth = -1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _sync(maxWidth: constraints.maxWidth);
        return ClipRect(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: _scrollController,
            physics: const NeverScrollableScrollPhysics(),
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}
