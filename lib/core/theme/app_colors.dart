import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Primary colors - Zello-inspired orange/yellow
  static const Color primary = Color(0xFFFF9800);
  static const Color primaryLight = Color(0xFFFFB74D);
  static const Color primaryDark = Color(0xFFF57C00);

  // Secondary colors
  static const Color secondary = Color(0xFF2196F3);
  static const Color secondaryLight = Color(0xFF64B5F6);
  static const Color secondaryDark = Color(0xFF1976D2);

  // Background colors
  static const Color backgroundDark = Color(0xFF121212);
  static const Color backgroundLight = Color(0xFFFAFAFA);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF2D2D2D);
  static const Color cardLight = Color(0xFFFFFFFF);

  // Text colors
  static const Color textPrimaryDark = Color(0xFFFFFFFF);
  static const Color textSecondaryDark = Color(0xFFB3B3B3);
  static const Color textPrimaryLight = Color(0xFF212121);
  static const Color textSecondaryLight = Color(0xFF757575);

  // Status colors
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFF44336);
  static const Color warning = Color(0xFFFF9800);
  static const Color info = Color(0xFF2196F3);

  // PTT specific colors
  static const Color pttIdle = Color(0xFF424242);
  static const Color pttActive = Color(0xFF4CAF50);
  static const Color pttReceiving = Color(0xFF2196F3);
  static const Color pttWaiting = Color(0xFFFF9800);

  // Online status colors
  static const Color online = Color(0xFF4CAF50);
  static const Color away = Color(0xFFFF9800);
  static const Color busy = Color(0xFFF44336);
  static const Color offline = Color(0xFF9E9E9E);
}
