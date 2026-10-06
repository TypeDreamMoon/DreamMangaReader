import 'package:flutter/material.dart';

import '../../app/local_media_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../ui/ui.dart';
import 'local_library_actions.dart';

/// 本地库两页(列表页与详情页)共用的零件:滚动区留白、提示横幅、区块标题行,
/// 以及两个 State 逐字相同的脚手架(引导 / 防连点闸门 / 提示出口)。
///
/// 单独成文件是因为两页是**同级**的:谁 import 谁都会拧成一个环,而这几块在两边
/// 一模一样,留在各自文件里只会随时间长歪。
///
/// 这里只放「两页都在用」的东西;只在一页出现的视觉块(库卡片的图标块、
/// 条目的序号列、`_Badge` 之类)留在各自文件里,不为了对称搬过来。

/// 本地库两页共用的滚动区留白。
const EdgeInsets kLocalLibraryPagePadding = EdgeInsets.fromLTRB(16, 6, 16, 24);

/// 本地库页面的脚手架:一次性的 `LocalMediaScope` 引导 + 「一次只跑一个操作」的闸门。
///
/// 两个页面的这段逻辑完全一样,差别只有构造 [LocalLibraryActions] 时那颗桥:
/// 列表页直接把 `widget.bridge` 递进来(为 null 时由 actions 自己造一个),
/// 详情页则在引导之外先解析出自己的那份(播放前 `stat` 还要用它)。
mixin LocalLibraryPageScaffold<T extends StatefulWidget> on State<T> {
  LocalMediaStore? _store;
  LocalLibraryActions? _actions;
  bool _bootstrapped = false;
  bool _busy = false;

  /// 引导出来的索引;首次 `didChangeDependencies` 之前是 null。
  @protected
  LocalMediaStore? get localStore => _store;

  /// 引导出来的编排;测试注入了就用注入的那份。
  @protected
  LocalLibraryActions? get localActions => _actions;

  /// 正在跑一次「加库 / 重扫」:页面据此禁用按钮并显示进度。
  @protected
  bool get localBusy => _busy;

  /// 首次 `didChangeDependencies` 时解析 store 与 actions;重复调用是空操作。
  ///
  /// `context.l10n` 在闸门之前读,和重构前一致(它是每次依赖变化都要注册的本地化
  /// 依赖);`LocalMediaScope.of` 仍然只在首次解析时调用。
  @protected
  void bootstrapLocalLibrary({
    LocalMediaStore? store,
    LocalLibraryActions? actions,
    LocalMediaBridge? bridge,
  }) {
    final l10n = context.l10n;
    if (_bootstrapped) return;
    _bootstrapped = true;
    final resolved = store ?? LocalMediaScope.of(context);
    _store = resolved;
    _actions = actions ??
        LocalLibraryActions(
          store: resolved,
          l10n: l10n,
          bridge: bridge,
          report: (message, kind) {
            if (!mounted) return;
            showAppNotify(context, message, kind: kind);
          },
        );
  }

  /// 跑一次操作:期间 [localBusy] 为真,结束后复位。
  ///
  /// 还没引导出 actions、或上一次还没跑完时直接返回 —— 防连点就发生在这里,
  /// 所以页面不用自己写 `if (_busy) return`。
  @protected
  Future<void> runLocalLibraryAction(
    Future<void> Function(LocalLibraryActions actions) body,
  ) async {
    final actions = _actions;
    if (actions == null || _busy) return;
    setState(() => _busy = true);
    try {
      await body(actions);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 改名对话框:一个输入框 + 取消/保存。
///
/// 返回 `null` 表示用户取消;返回空串表示「清掉自定义名字、恢复原名」——
/// 只有条目允许这样([allowEmpty] 为真),库名空着会让卡片只剩「未知标题」,
/// 所以那种情况下保存按钮直接禁用。
///
/// 用 StatefulWidget 拿住 controller(而不是 `try/finally` 里 dispose):
/// 对话框退场动画期间输入框还在树上,提前 dispose 会炸。
Future<String?> showLocalRenameDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required String initial,
  bool allowEmpty = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (context) => _LocalRenameDialog(
        title: title,
        hint: hint,
        initial: initial,
        allowEmpty: allowEmpty,
      ),
    );

class _LocalRenameDialog extends StatefulWidget {
  const _LocalRenameDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.allowEmpty,
  });

  final String title;
  final String hint;
  final String initial;
  final bool allowEmpty;

  @override
  State<_LocalRenameDialog> createState() => _LocalRenameDialogState();
}

class _LocalRenameDialogState extends State<_LocalRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final canSave = widget.allowEmpty || _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('local-rename-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (canSave) _submit();
        },
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: canSave ? _submit : null,
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}

/// 一条提示横幅:图标 + 一段文字(可选一个尾部动作)。
///
/// 列表页的「加载警告」与详情页的「加载警告 / 需要重新授权」结构完全相同,
/// 差别只有图标、配色、文字样式与那个「重新授权」按钮。
class LocalNoticeCard extends StatelessWidget {
  const LocalNoticeCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.message,
    required this.messageStyle,
    this.action,
  });

  final IconData icon;
  final Color iconColor;
  final String message;
  final TextStyle messageStyle;

  /// 横幅右侧的动作按钮;没有就是纯文字横幅。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return AppCard(
      radius: 8,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 9),
          Expanded(child: Text(message, style: messageStyle)),
          if (action != null) action,
        ],
      ),
    );
  }
}

/// 区块标题行:图标 + 标题 + 右侧的条目数(「本地库」「剧集」两处同款)。
class LocalSectionHeader extends StatelessWidget {
  const LocalSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.trailing,
  });

  final IconData icon;
  final String title;

  /// 右侧的浅色小字(条目数)。
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Icon(icon, color: p.accent, size: 20),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(trailing, style: TextStyle(color: p.textMuted, fontSize: 11.5)),
      ],
    );
  }
}
