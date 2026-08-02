class MangaIdentityTracker {
  final Set<String> _seen = <String>{};

  bool add(String sourceId, String mangaId) =>
      _seen.add('$sourceId\u0000$mangaId');

  void clear() => _seen.clear();
}
