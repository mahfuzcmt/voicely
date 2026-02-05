import 'package:freezed_annotation/freezed_annotation.dart';

part 'ptt_session_model.freezed.dart';
part 'ptt_session_model.g.dart';

enum PttSessionState {
  idle,
  requestingFloor,
  transmitting,
  receiving,
  error,
}

@freezed
sealed class PttSessionModel with _$PttSessionModel {
  const PttSessionModel._();

  const factory PttSessionModel({
    required String channelId,
    @Default(PttSessionState.idle) PttSessionState state,
    String? currentSpeakerId,
    String? currentSpeakerName,
    String? errorMessage,
    @Default({}) Map<String, PeerConnectionState> peerConnections,
  }) = _PttSessionModel;

  factory PttSessionModel.fromJson(Map<String, dynamic> json) =>
      _$PttSessionModelFromJson(json);

  bool get isIdle => state == PttSessionState.idle;
  bool get isTransmitting => state == PttSessionState.transmitting;
  bool get isReceiving => state == PttSessionState.receiving;
  bool get hasError => state == PttSessionState.error;

  bool get canStartPtt =>
      state == PttSessionState.idle ||
      state == PttSessionState.receiving ||
      state == PttSessionState.error ||
      state == PttSessionState.requestingFloor;
}

enum PeerConnectionStatus {
  connecting,
  connected,
  disconnected,
  failed,
}

@freezed
sealed class PeerConnectionState with _$PeerConnectionState {
  const factory PeerConnectionState({
    required String peerId,
    @Default(PeerConnectionStatus.connecting) PeerConnectionStatus status,
  }) = _PeerConnectionState;

  factory PeerConnectionState.fromJson(Map<String, dynamic> json) =>
      _$PeerConnectionStateFromJson(json);
}
