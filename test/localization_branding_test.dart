import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const allowedKeys = {
    'basedOnMeditoCredit',
    'meditoUrl',
    'blackFridaySubtitle',
    'meditoReliesOnYourDonationsToSurvive',
    'donationBody',
    'donationThankYouBody',
    'donationVisitFoundation',
    'supportContent',
    'donationFormUrl',
    'payPalDonationUrl',
    'bankTransferDetailsUrl',
    'donationRetentionMainMessage',
    'donationRetentionBenefit3',
    'foundationRegistrationInfo',
    'foundationContactInfo',
    'impactCardTestimonial',
    'shopSubtitle',
    'shopSupportNote',
  };
  final formerBrand = RegExp('medito', caseSensitive: false);

  for (final locale in ['es', 'en', 'de']) {
    test('app_$locale.arb solo menciona Medito en los textos permitidos', () {
      final file = File('lib/l10n/app_$locale.arb');
      final messages =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final unexpectedKeys = messages.entries
          .where(
            (entry) =>
                !entry.key.startsWith('@') &&
                !allowedKeys.contains(entry.key) &&
                entry.value is String &&
                formerBrand.hasMatch(entry.value as String),
          )
          .map((entry) => entry.key);

      expect(unexpectedKeys, isEmpty);
    });
  }
}
