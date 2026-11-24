import '../../l10n/app_localizations.dart';
import '../background_sounds/background_sounds_model.dart';

typedef BellSoundId = String;

const defaultBellSoundId = 'actual';

class BellSound {
  const BellSound(
    this.id,
    this.assetKey,
    this.durationMs,
    this.name, {
    this.premium = false,
  });

  // Todas las campanas del temporizador son gratis (decisión del dueño).
  const BellSound._mp3(this.id, String file, this.durationMs, this.name)
    : premium = false,
      assetKey = 'assets/audio/bells/$file.mp3';

  final BellSoundId id;
  final String assetKey;
  final int durationMs;
  final String Function(AppLocalizations) name;
  final bool premium;

  static BellSound resolve(Object? id) =>
      _byId[id] ?? _byId[defaultBellSoundId]!;

  static final _byId = {for (final sound in bellSounds) sound.id: sound};
}

final List<BellSound> bellSounds = List.unmodifiable([
  BellSound(
    defaultBellSoundId,
    kSessionBellAsset,
    6000,
    (l10n) => l10n.bellSoundActual,
  ),
  BellSound._mp3(
    'cuenco_tibetano',
    'g1-cuenco-tibetano',
    12042,
    (l10n) => l10n.bellSoundTibetanBowl,
  ),
  BellSound._mp3(
    'bloque_madera',
    'g2-bloque-madera',
    1202,
    (l10n) => l10n.bellSoundWoodBlock,
  ),
  BellSound._mp3(
    'campanilla',
    'g3-campanilla',
    8046,
    (l10n) => l10n.bellSoundSmallBell,
  ),
  BellSound._mp3(
    'gong_suave',
    'g4-gong-suave',
    10815,
    (l10n) => l10n.bellSoundSoftGong,
  ),
  BellSound._mp3(
    'cuenco_cristal',
    'g5-cuenco-cristal',
    10527,
    (l10n) => l10n.bellSoundCrystalBowl,
  ),
  BellSound._mp3(
    'diapason',
    'g6-diapason',
    8046,
    (l10n) => l10n.bellSoundTuningFork,
  ),
  BellSound._mp3(
    'gong_viento',
    'p1-gong-viento',
    13009,
    (l10n) => l10n.bellSoundWindGong,
  ),
  BellSound._mp3(
    'tambor_marco',
    'p2-tambor-marco',
    5042,
    (l10n) => l10n.bellSoundFrameDrum,
  ),
  BellSound._mp3(
    'handpan',
    'p3-handpan',
    5146,
    (l10n) => l10n.bellSoundHandpan,
  ),
  BellSound._mp3(
    'palo_lluvia',
    'p4-palo-lluvia',
    5799,
    (l10n) => l10n.bellSoundRainstick,
  ),
  BellSound._mp3(
    'campana_templo',
    'p5-campana-templo',
    15047,
    (l10n) => l10n.bellSoundTempleBell,
  ),
  BellSound._mp3(
    'cuenco_grave',
    'p6-cuenco-grave',
    12669,
    (l10n) => l10n.bellSoundLargeBowl,
  ),
  BellSound._mp3(
    'tingsha',
    'p7-tingsha',
    8046,
    (l10n) => l10n.bellSoundTingsha,
  ),
  BellSound._mp3(
    'kalimba',
    'p8-kalimba',
    1176,
    (l10n) => l10n.bellSoundKalimba,
  ),
  BellSound._mp3(
    'flauta',
    'p9-flauta',
    5381,
    (l10n) => l10n.bellSoundBambooFlute,
  ),
  BellSound._mp3(
    'campanas_viento',
    'p10-campanas-viento',
    5329,
    (l10n) => l10n.bellSoundWindChimes,
  ),
]);
