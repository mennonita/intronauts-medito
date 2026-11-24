import 'package:in_app_review/in_app_review.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SitOutcome {
  const SitOutcome({
    required this.isTimer,
    required this.naturalEnd,
    required this.endCueRang,
    required this.pausedMs,
  });

  final bool isTimer;
  final bool naturalEnd;
  final bool endCueRang;
  final int pausedMs;

  bool get isClean => pausedMs <= 120000 && (isTimer ? endCueRang : naturalEnd);
}

// Conserva el contrato de los dobles de prueba que usan el método anterior.
extension SitReview on ReviewService {
  Future<void> maybeRequestAfterSit(SitOutcome? outcome) async {
    if (outcome?.isClean != true) return;
    await checkAndRequestReview();
  }
}

class ReviewService {
  static const _reviewRequestKey = 'last_review_request_timestamp';
  static const _minimumDaysBetweenRequests = 90;
  static const _minimumReturnsForReview = 10;

  final InAppReview _inAppReview = InAppReview.instance;
  final StatsManager _statsManager;

  ReviewService({required StatsManager statsManager})
    : _statsManager = statsManager;

  Future<void> checkAndRequestReview() async {
    try {
      if (await _statsManager.returns < _minimumReturnsForReview) {
        return;
      }

      if (!await _canRequestReview()) {
        return;
      }

      await _inAppReview.requestReview();

      await _saveReviewRequestTimestamp();
    } catch (e) {
      AppLogger.e('REVIEW', 'Error checking for app review: $e');
    }
  }

  Future<bool> _canRequestReview() async {
    try {
      if (!await _inAppReview.isAvailable()) {
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      final lastRequestTimestamp = prefs.getInt(_reviewRequestKey) ?? 0;

      if (lastRequestTimestamp == 0) {
        return true;
      }

      final lastRequestDate = DateTime.fromMillisecondsSinceEpoch(
        lastRequestTimestamp,
      );
      final now = DateTime.now();
      final difference = now.difference(lastRequestDate).inDays;

      return difference >= _minimumDaysBetweenRequests;
    } catch (e) {
      return false;
    }
  }

  Future<void> _saveReviewRequestTimestamp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _reviewRequestKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      AppLogger.e('REVIEW', 'Error saving review request timestamp: $e');
    }
  }
}
