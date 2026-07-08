import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 统一文本输入框:palette.background 填充 + line/accent 描边(圆角 + 边框状态走
/// 主题 inputDecorationTheme)。各页手搓的 InputDecoration 都走它。
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.obscure = false,
    this.enabled = true,
    this.prefixIcon,
    this.suffixIcon,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.autofocus = false,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final bool obscure;
  final bool enabled;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      maxLines: obscure ? 1 : maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofocus: autofocus,
      autofillHints: autofillHints,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: TextStyle(color: p.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: p.background,
        isDense: true,
        labelStyle: TextStyle(color: p.textMuted, fontSize: 13),
        hintStyle: TextStyle(color: p.textMuted, fontSize: 13),
      ),
    );
  }
}

/// 搜索框预设:前导放大镜 + 搜索键。[AppTextField] 的薄封装,不另起一套控件。
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    required this.controller,
    this.hint = '搜索',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppTextField(
      controller: controller,
      hint: hint,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      prefixIcon: Icon(Icons.search_rounded, size: 18, color: p.textMuted),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}
