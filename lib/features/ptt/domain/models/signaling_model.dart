import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'signaling_model.freezed.dart';
part 'signaling_model.g.dart';

enum SignalingType { offer, answer }

@freezed
sealed class SignalingModel with _$SignalingModel {
  const SignalingModel._();

  const factory SignalingModel({
    required String id,
    required SignalingType type,
    required String fromUserId,
    required String toUserId,
    required String sdp,
    required DateTime createdAt,
  }) = _SignalingModel;

  factory SignalingModel.fromJson(Map<String, dynamic> json) =>
      _$SignalingModelFromJson(json);

  factory SignalingModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Signaling document is empty');
    }
    return SignalingModel(
      id: doc.id,
      type: SignalingType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => SignalingType.offer,
      ),
      fromUserId: data['fromUserId'] ?? '',
      toUserId: data['toUserId'] ?? '',
      sdp: data['sdp'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'type': type.name,
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      'sdp': sdp,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}

@freezed
sealed class IceCandidateModel with _$IceCandidateModel {
  const IceCandidateModel._();

  const factory IceCandidateModel({
    required String id,
    required String fromUserId,
    required String toUserId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
    required DateTime createdAt,
  }) = _IceCandidateModel;

  factory IceCandidateModel.fromJson(Map<String, dynamic> json) =>
      _$IceCandidateModelFromJson(json);

  factory IceCandidateModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('ICE candidate document is empty');
    }
    return IceCandidateModel(
      id: doc.id,
      fromUserId: data['fromUserId'] ?? '',
      toUserId: data['toUserId'] ?? '',
      candidate: data['candidate'] ?? '',
      sdpMid: data['sdpMid'] ?? '',
      sdpMLineIndex: data['sdpMLineIndex'] ?? 0,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
