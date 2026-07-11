import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/theme/app_colors.dart';
import '../../core/bili/bili_api.dart';
import '../../core/bili/bili_auth.dart';

/// 哔哩哔哩扫码登录页。生成二维码 → 轮询状态 → 成功落 Cookie 并回填昵称后 `pop(true)`。
/// 二维码失效可点刷新重生成。Cookie 存安全存储(见 [BiliAuth]),不进云同步。
class BiliLoginPage extends StatefulWidget {
  const BiliLoginPage({super.key});

  @override
  State<BiliLoginPage> createState() => _BiliLoginPageState();
}

class _BiliLoginPageState extends State<BiliLoginPage> {
  String? _qrUrl;
  String? _key;
  Timer? _poll;
  BiliQrState _state = BiliQrState.waiting;
  String _hint = '正在生成二维码…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _regenerate();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _regenerate() async {
    _poll?.cancel();
    setState(() {
      _qrUrl = null;
      _state = BiliQrState.waiting;
      _hint = '正在生成二维码…';
      _busy = true;
    });
    try {
      final qr = await BiliAuth.instance.qrGenerate();
      if (!mounted) return;
      setState(() {
        _qrUrl = qr.url;
        _key = qr.key;
        _hint = '用哔哩哔哩 App 扫码登录';
        _busy = false;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 复用 expired 态:露出「刷新二维码」按钮 + 错误图标,避免卡在无限转圈无从重试。
        _state = BiliQrState.expired;
        _hint = '二维码生成失败,点下方刷新:$e';
        _busy = false;
      });
    }
  }

  Future<void> _tick() async {
    final key = _key;
    if (key == null || _busy) return;
    _busy = true;
    try {
      final s = await BiliAuth.instance.qrPoll(key);
      if (!mounted) return;
      setState(() => _state = s);
      switch (s) {
        case BiliQrState.success:
          _poll?.cancel();
          // 拉昵称回填(失败不影响登录成功)。
          try {
            await BiliApi.instance.refreshProfile();
          } catch (_) {}
          if (mounted) Navigator.of(context).pop(true);
          return;
        case BiliQrState.scanned:
          _hint = '已扫描,请在手机上确认登录';
          break;
        case BiliQrState.waiting:
          _hint = '用哔哩哔哩 App 扫码登录';
          break;
        case BiliQrState.expired:
          _poll?.cancel();
          _hint = '二维码已失效,点下方刷新';
          break;
        case BiliQrState.error:
          // 偶发网络抖动:不打断,继续下一轮。
          break;
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final expired = _state == BiliQrState.expired;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        foregroundColor: p.textPrimary,
        elevation: 0,
        title: const Text('登录哔哩哔哩'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 236,
                height: 236,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: p.line),
                ),
                alignment: Alignment.center,
                child: _qrUrl == null
                    ? (expired
                        ? const Icon(Icons.wifi_off_rounded,
                            color: Colors.black38, size: 36)
                        : const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ))
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          QrImageView(
                            data: _qrUrl!,
                            version: QrVersions.auto,
                            size: 204,
                            // 二维码固定黑白(白底容器),不随主题反色导致扫不出。
                            eyeStyle: const QrEyeStyle(
                                eyeShape: QrEyeShape.square,
                                color: Color(0xFF000000)),
                            dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Color(0xFF000000)),
                          ),
                          if (expired)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.86),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.refresh_rounded,
                                        color: Colors.black54, size: 30),
                                    const SizedBox(height: 4),
                                    Text('二维码已失效',
                                        style: TextStyle(
                                            color: Colors.black.withValues(
                                                alpha: 0.7),
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 18),
              Text(
                _hint,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _state == BiliQrState.scanned
                        ? p.accent
                        : p.textMuted,
                    fontSize: 13,
                    height: 1.5),
              ),
              const SizedBox(height: 16),
              if (expired)
                FilledButton.icon(
                  onPressed: _busy ? null : _regenerate,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新二维码'),
                ),
              const SizedBox(height: 8),
              Text('登录信息仅存本机(安全存储),不会同步或导出。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}
