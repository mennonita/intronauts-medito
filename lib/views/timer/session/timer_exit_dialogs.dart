import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_timeline.dart';

/// Menos de esto meditado no se guarda: salir no pregunta nada.
const kTimerExitConfirmMinMs = 60000;

/// Lo que elige la persona al salir de una sesión con tiempo meditado.
enum TimerExitChoice { keepMeditating, exitWithoutSaving, saveAndExit }

/// «Terminar» pregunta antes cuando falta un minuto o más de la cuenta
/// regresiva, o cuando aún no se medita un minuto (no se guardaría).
/// El cronómetro y el tiempo extra con un minuto o más terminan sin preguntar.
bool timerEndNeedsConfirmation(TimerTimeline timeline, int positionMs) {
  if (timeline.elapsedMs(positionMs) < kTimerExitConfirmMinMs) return true;
  final remaining = timeline.remainingMs(positionMs);
  return remaining != null && remaining >= kTimerExitConfirmMinMs;
}

/// Pregunta antes de salir: guardar y salir, salir sin guardar o seguir.
/// Cerrar el diálogo sin elegir es seguir meditando.
Future<TimerExitChoice> showTimerExitDialog(
  BuildContext context, {
  required int elapsedMs,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final choice = await showDialog<TimerExitChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.timerExitConfirmTitle),
      content: Text(
        l10n.timerExitConfirmBody(elapsedMs ~/ Duration.millisecondsPerMinute),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, TimerExitChoice.keepMeditating),
          child: Text(l10n.timerKeepMeditating),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, TimerExitChoice.exitWithoutSaving),
          child: Text(l10n.timerExitWithoutSaving),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, TimerExitChoice.saveAndExit),
          child: Text(l10n.timerSaveAndExit),
        ),
      ],
    ),
  );
  return choice ?? TimerExitChoice.keepMeditating;
}

/// Confirma «Terminar». Con menos de un minuto avisa que no se guardará.
/// Devuelve verdadero solo si la persona eligió terminar.
Future<bool> showTimerEndDialog(
  BuildContext context, {
  required int elapsedMs,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.timerEndConfirmTitle),
      content: Text(
        elapsedMs < kTimerExitConfirmMinMs
            ? l10n.timerShortSessionWarning
            : l10n.timerEndConfirmBody(
                elapsedMs ~/ Duration.millisecondsPerMinute,
              ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.timerKeepMeditating),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.timerEndConfirmAction),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
