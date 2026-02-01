import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'floor_control_model.freezed.dart';
part 'floor_control_model.g.dart';

@freezed
sealed class FloorControlModel with _$FloorControlModel {
  const FloorControlModel._();

  const factory FloorControlModel({
    required String speakerId,
    required String speakerName,
    required DateTime startedAt,
    required DateTime expiresAt,
  }) = _FloorControlModel;

  factory FloorControlModel.fromJson(Map<String, dynamic> json) =>
      _$FloorControlModelFromJson(json);

  factory FloorControlModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Floor control document is empty');
    }
    return FloorControlModel(
      speakerId: data['speakerId'] ?? '',
      speakerName: data['speakerName'] ?? '',
      startedAt: (data['startedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'speakerId': speakerId,
      'speakerName': speakerName,
      'startedAt': Timestamp.fromDate(startedAt),
      'expiresAt': Timestamp.fromDate(expiresAt),
    };
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
