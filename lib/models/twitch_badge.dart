class BadgeVersion {
  final String id;
  final String title;
  final String imageUrl;

  const BadgeVersion({
    required this.id,
    required this.title,
    required this.imageUrl,
  });
}

class BadgeSet {
  final String setId;
  final Map<String, BadgeVersion> versions;

  const BadgeSet({required this.setId, required this.versions});
}

class MessageBadge {
  final String setId;
  final String versionId;

  const MessageBadge({required this.setId, required this.versionId});
}
