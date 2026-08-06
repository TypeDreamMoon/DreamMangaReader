/// URL 凭据脱敏。
///
/// 更新包地址、HLS 分片地址常带签名参数(`token`、`sig`、`X-Amz-Signature`…)。原始异常
/// 文本会同时进入 UI 提示和日志,所以任何要展示或落盘的错误串都得先过这里。
///
/// 做两件事:
/// 1. 把文本里每个 URL 重建成只含 scheme/host/port/path 的形式,丢掉 query 和 fragment;
/// 2. 对散落在 URL 之外的 `key=value` 凭据参数打码。
///
/// 之前更新模块和播放模块各自维护(或遗漏)了这套逻辑,现在统一收口在此。
String redactUrlCredentials(String value) {
  final withoutQueries = value.replaceAllMapped(
    RegExp(r'''https?://[^\s<>"']+'''),
    (match) {
      final raw = match.group(0)!;
      final trailing = RegExp(r'[),.;:]+$').firstMatch(raw)?.group(0) ?? '';
      final url = trailing.isEmpty
          ? raw
          : raw.substring(0, raw.length - trailing.length);
      final uri = Uri.tryParse(url);
      if (uri == null) return '[redacted URL]$trailing';
      // 注意:Uri.replace(query: null) 表示"该组件保持原值",不是"删除该组件"。
      // 想真正丢掉 query/fragment 必须显式重建 Uri,否则签名参数会原样留在文本里。
      final bare = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      );
      return '$bare$trailing';
    },
  );
  // 注意:Dart 的 String.replaceAll 不解释 `$1` 反向引用(会原样写出字面量),
  // 分组替换必须走 replaceAllMapped。
  return withoutQueries
      .replaceAllMapped(
        RegExp(
          r'\b(token|ts|sig|signature|key|password|secret)=[^\s&]+',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}=[redacted]',
      )
      .trim();
}
