enum HlsCacheLimit {
  off(0),
  mib256(256 * 1024 * 1024),
  mib512(512 * 1024 * 1024),
  gib1(1024 * 1024 * 1024);

  const HlsCacheLimit(this.bytes);

  static const defaultValue = HlsCacheLimit.mib512;

  final int bytes;
}
