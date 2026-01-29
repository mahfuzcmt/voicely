class FirebaseConstants {
  FirebaseConstants._();

  // User document fields
  static const String fieldUserId = 'userId';
  static const String fieldEmail = 'email';
  static const String fieldDisplayName = 'displayName';
  static const String fieldPhotoUrl = 'photoUrl';
  static const String fieldStatus = 'status';
  static const String fieldLastSeen = 'lastSeen';
  static const String fieldCreatedAt = 'createdAt';
  static const String fieldUpdatedAt = 'updatedAt';

  // Channel document fields
  static const String fieldChannelId = 'channelId';
  static const String fieldChannelName = 'name';
  static const String fieldChannelDescription = 'description';
  static const String fieldChannelOwnerId = 'ownerId';
  static const String fieldChannelMembers = 'members';
  static const String fieldChannelMemberCount = 'memberCount';
  static const String fieldChannelIsPrivate = 'isPrivate';
  static const String fieldChannelImageUrl = 'imageUrl';

  // Message document fields
  static const String fieldMessageId = 'messageId';
  static const String fieldMessageType = 'type';
  static const String fieldMessageContent = 'content';
  static const String fieldMessageSenderId = 'senderId';
  static const String fieldMessageSenderName = 'senderName';
  static const String fieldMessageTimestamp = 'timestamp';
  static const String fieldMessageAudioUrl = 'audioUrl';
  static const String fieldMessageAudioDuration = 'audioDuration';
  static const String fieldMessageLocation = 'location';

  // Member document fields
  static const String fieldMemberRole = 'role';
  static const String fieldMemberJoinedAt = 'joinedAt';
  static const String fieldMemberIsMuted = 'isMuted';

  // Location document fields
  static const String fieldLatitude = 'latitude';
  static const String fieldLongitude = 'longitude';
  static const String fieldLocationTimestamp = 'timestamp';
}
