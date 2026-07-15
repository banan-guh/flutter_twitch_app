enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel }

class GenericEmote {
  final String id;
  final String code;
  final EmoteType type;
  final String url;
  final bool isAnimated;
  final EmoteScope scope;
  final String? ownerChannel;
  final String? tier;
  final bool isZeroWidth;
  final double relativeScale;
  final double aspectRatio;

  const GenericEmote({
    required this.id,
    required this.code,
    required this.type,
    required this.url,
    this.isAnimated = false,
    this.scope = EmoteScope.global,
    this.ownerChannel,
    this.tier,
    this.isZeroWidth = false,
    this.relativeScale = 1.0,
    this.aspectRatio = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'type': type.index,
    'url': url,
    'isAnimated': isAnimated,
    'scope': scope.index,
    'ownerChannel': ownerChannel,
    'tier': tier,
    'isZeroWidth': isZeroWidth,
    'relativeScale': relativeScale,
    'aspectRatio': aspectRatio,
  };

  factory GenericEmote.fromJson(Map<String, dynamic> json) => GenericEmote(
    id: json['id'] as String,
    code: json['code'] as String,
    type: EmoteType.values[json['type'] as int],
    url: json['url'] as String,
    isAnimated: json['isAnimated'] as bool? ?? false,
    scope: EmoteScope.values[json['scope'] as int? ?? 0],
    ownerChannel: json['ownerChannel'] as String?,
    tier: json['tier'] as String?,
    isZeroWidth: json['isZeroWidth'] as bool? ?? false,
    relativeScale: (json['relativeScale'] as num?)?.toDouble() ?? 1.0,
    aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
  );
}
