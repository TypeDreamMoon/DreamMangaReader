import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Bilibili **WBI 签名**(2023 起大量 Web API 需要)。
///
/// 流程:① 从 `x/web-interface/nav` 拿 `wbi_img.img_url` / `sub_url`,取文件名(去扩展名)
/// 得 img_key / sub_key;② 按固定 [_mixinKeyEncTab] 重排 `img_key+sub_key` 取前 32 字符
/// 得 mixin_key;③ 给参数加 `wts`(秒),按 key 排序,值里滤掉 `!'()*`,urlencode 拼 query,
/// `w_rid = md5(query + mixin_key)`。纯函数,可单测(见 test/bili_wbi_test.dart)。
///
/// 算法与常量对照社区文档 bilibili-API-collect(docs/misc/sign/wbi)。
const List<int> _mixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, //
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, //
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, //
  36, 20, 34, 44, 52
];

/// 从 `img_url`/`sub_url` 取 key:文件名去扩展名。
/// 如 `https://i0.hdslb.com/bfs/wbi/7cd0849413....png` → `7cd0849413...`。
String biliKeyFromUrl(String url) {
  final name = url.split('/').last;
  final dot = name.indexOf('.');
  return dot >= 0 ? name.substring(0, dot) : name;
}

/// 重排 `imgKey+subKey` 取前 32 字符得 mixin_key。
String biliMixinKey(String imgKey, String subKey) {
  final raw = imgKey + subKey;
  final sb = StringBuffer();
  for (final i in _mixinKeyEncTab) {
    if (i >= 0 && i < raw.length) sb.writeCharCode(raw.codeUnitAt(i));
  }
  final s = sb.toString();
  return s.length > 32 ? s.substring(0, 32) : s;
}

final RegExp _wbiFilter = RegExp(r"[!'()*]");

/// 用 [mixinKey] 给 [params] 做 WBI 签名,返回**含 wts + w_rid 的新参数表**(值全转成串)。
/// [nowSec] 可注入(测试/固定时间);默认取当前 unix 秒。
Map<String, String> biliWbiSign(Map<String, dynamic> params, String mixinKey,
    {int? nowSec}) {
  final wts = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final all = <String, String>{};
  params.forEach((k, v) => all[k] = '$v');
  all['wts'] = '$wts';
  final keys = all.keys.toList()..sort();
  final query = keys.map((k) {
    final v = all[k]!.replaceAll(_wbiFilter, '');
    return '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}';
  }).join('&');
  final wRid = md5.convert(utf8.encode(query + mixinKey)).toString();
  return {...all, 'w_rid': wRid};
}
