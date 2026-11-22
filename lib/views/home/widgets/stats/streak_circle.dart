import 'package:medito/providers/practice_history_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/icons/medito_icons.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/providers/settings/settings_providers.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/views/home/widgets/stats/streak_circle_controller.dart';
import 'package:medito/widgets/medito_icon.dart';
import '../../../../constants/colors/color_constants.dart';
import 'streak_circle_constants.dart';
import 'streak_ring.dart';

class StreakCircle extends ConsumerStatefulWidget {
  final VoidCallback onTap;

  const StreakCircle({super.key, required this.onTap});

  @override
  ConsumerState<StreakCircle> createState() => StreakCircleState();
}

class StreakCircleState extends ConsumerState<StreakCircle>
    with TickerProviderStateMixin {
  late final StreakCircleController _controller;

  @override
  void initState() {
    super.initState();
    _controller = StreakCircleController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _controller.reduceMotion = MediaQuery.disableAnimationsOf(context);
    final history = ref.watch(practiceHistoryProvider);
    final zen = ref.watch(zenModeProvider);

    return history.when(
      loading: _buildShimmer,
      error: (_, _) => _buildErrorState(ref),
      data: (history) {
        final practicedToday = history.days.contains(history.today);
        _controller.updateAnimation(practicedToday);
        return zen
            ? _buildZenModeCircle(practicedToday)
            : _buildReturnsCircle(history.returns, practicedToday);
      },
    );
  }

  Widget _buildReturnsCircle(int returns, bool practicedToday) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(
      StreakCircleConstants.borderRadius,
    );

    return _ring(
      active: practicedToday,
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          label: l10n.returnsCompletion(returns),
          button: true,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: borderRadius,
            child: Ink(
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: borderRadius,
              ),
              child: Padding(
                padding: StreakCircleConstants.padding,
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.returnsHomeLabel,
                        style: theme.textTheme.labelSmall,
                      ),
                      Text(
                        '$returns',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        l10n.returnsHomeCaption,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ring({required bool active, required Widget child}) {
    if (!active) return child;
    return StreakRing(
      animation: _controller.animationController,
      color: context.brandAccent,
      strokeWidth: StreakCircleConstants.ringWidth,
      child: child,
    );
  }

  Widget _buildShimmer() {
    return Container(
      decoration: BoxDecoration(
        color: ColorConstants.onyx,
        borderRadius: BorderRadius.circular(StreakCircleConstants.borderRadius),
      ),
      child: Padding(
        padding: StreakCircleConstants.padding,
        child: const SizedBox(
          width: 24,
          height: 22,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: ColorConstants.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZenModeCircle(bool practicedToday) {
    return _ring(
      active: practicedToday,
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          label: AppLocalizations.of(context)!.viewPracticeStats,
          button: true,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(
              StreakCircleConstants.borderRadius,
            ),
            child: Ink(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(
                  StreakCircleConstants.borderRadius,
                ),
              ),
              child: Padding(
                padding: StreakCircleConstants.padding,
                child: ExcludeSemantics(
                  child: MeditoIcon(
                    assetName: practicedToday
                        ? MeditoIcons.fire
                        : MeditoIcons.sun,
                    size: StreakCircleConstants.iconSize,
                    color: practicedToday
                        ? context.brandAccent
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: ColorConstants.onyx,
        borderRadius: BorderRadius.circular(StreakCircleConstants.borderRadius),
      ),
      child: Padding(
        padding: StreakCircleConstants.padding,
        child: Semantics(
          label: AppLocalizations.of(context)!.refresh,
          button: true,
          child: GestureDetector(
            onTap: () => ref.refresh(statsProvider),
            child: ExcludeSemantics(
              child: MeditoIcon(
                assetName: MeditoIcons.help,
                color: ColorConstants.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
