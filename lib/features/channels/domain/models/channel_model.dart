import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'channel_model.freezed.dart';
part 'channel_model.g.dart';

@freezed
sealed class ChannelModel with _$ChannelModel {
  const ChannelModel._();

  const factory ChannelModel({
    required String id,
    required String name,
    String? description,
    required String ownerId,
    String? imageUrl,
    @Default(false) bool isPrivate,
    @Default(0) int memberCount,
    @Default([]) List<String> memberIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _ChannelModel;

  factory ChannelModel.fromJson(Map<String, dynamic> json) =>
      _$ChannelModelFromJson(json);

  factory ChannelModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChannelModel(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'],
      ownerId: data['ownerId'] ?? '',
      imageUrl: data['imageUrl'],
      isPrivate: data['isPrivate'] ?? false,
      memberCount: data['memberCount'] ?? 0,
      memberIds: List<String>.from(data['memberIds'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'description': description,
      'ownerId': ownerId,
      'imageUrl': imageUrl,
      'isPrivate': isPrivate,
      'memberCount': memberCount,
      'memberIds': memberIds,
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}

@freezed
sealed class ChannelMember with _$ChannelMember {
  const ChannelMember._();

  const factory ChannelMember({
    required String id,
    required String userId,
    required String channelId,
    @Default(MemberRole.member) MemberRole role,
    @Default(false) bool isMuted,
    DateTime? joinedAt,
  }) = _ChannelMember;

  factory ChannelMember.fromJson(Map<String, dynamic> json) =>
      _$ChannelMemberFromJson(json);

  factory ChannelMember.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChannelMember(
      id: doc.id,
      userId: data['userId'] ?? '',
      channelId: data['channelId'] ?? '',
      role: MemberRole.values.firstWhere(
        (e) => e.name == data['role'],
        orElse: () => MemberRole.member,
      ),
      isMuted: data['isMuted'] ?? false,
      joinedAt: (data['joinedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'channelId': channelId,
      'role': role.name,
      'isMuted': isMuted,
      'joinedAt': joinedAt != null
          ? Timestamp.fromDate(joinedAt!)
          : FieldValue.serverTimestamp(),
    };
  }
}

enum MemberRole { owner, admin, member }
