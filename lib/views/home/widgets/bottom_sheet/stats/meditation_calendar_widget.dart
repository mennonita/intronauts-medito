import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:flutter/material.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/views/timer/timer_format.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/constants/icons/medito_icons.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/providers/meditation/track_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/utils/calendar_range.dart';
import 'package:medito/utils/practice_history.dart';
import 'package:medito/utils/stats_updater.dart';
import 'package:medito/utils/utils.dart';
import 'package:medito/views/track/track_view.dart';
import 'package:medito/widgets/dialogs/dialogs.dart';
import 'package:medito/widgets/medito_icon.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'bulk_add_sessions_dialog.dart';
import 'manual_session_dialog.dart';

class MeditationCalendarWidget extends ConsumerStatefulWidget {
  final PracticeHistory history;

  const MeditationCalendarWidget({super.key, required this.history});

  @override
  ConsumerState<MeditationCalendarWidget> createState() =>
      _MeditationCalendarWidgetState();
}

class _MeditationCalendarWidgetState
    extends ConsumerState<MeditationCalendarWidget>
    with SingleTickerProviderStateMixin {
  late DateTime _focusedDay;
  late DateTime _selectedDay;
  late DateTime _selectedDayForSessions;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  bool _isAddingSession = false;

  // Range selection: long-press one day to anchor, long-press a second day
  // to complete the range. A third long-press resets to a new anchor.
  DateTime? _rangeStart;
  DateTime? _rangeEnd;

  @override
  void initState() {
    super.initState();
    final today = widget.history.today;
    final todayStart = DateTime(today.year, today.month, today.day);
    _focusedDay = today;
    _selectedDay = today;
    _selectedDayForSessions = todayStart;
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndSelectToday();
    });
  }

  void _checkAndSelectToday() {
    if (!mounted) return;

    final today = widget.history.today;
    final todayStart = DateTime(today.year, today.month, today.day);

    setState(() {
      _selectedDayForSessions = todayStart;
    });
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggleDaySessions(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);

    if (isSameDay(_selectedDayForSessions, dayStart)) {
      return;
    }

    _animationController.reverse().then((_) {
      if (mounted) {
        setState(() {
          _selectedDayForSessions = dayStart;
        });
        _animationController.forward();
      }
    });
  }

  Future<void> _confirmDeleteSession(LocalAudioCompleted session) async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => MeditoDialog(
        title: l10n.deleteSessionTitle,
        content: MeditoDialogBody(l10n.deleteSessionConfirmation),
        actions: [
          MeditoDialogSecondaryButton(
            label: l10n.cancel,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          MeditoDialogDestructiveButton(
            label: l10n.delete,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final errorMessage = l10n.deleteSessionError;

    final success = await deleteSession(session: session);

    if (!mounted) return;

    if (success) {
      await ref.read(statsProvider.notifier).refreshFromLocal();
    } else {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  bool get _hasCompleteRange => _rangeStart != null && _rangeEnd != null;

  bool _isInRange(DateTime day) {
    if (!_hasCompleteRange) return false;
    final dayStart = DateTime(day.year, day.month, day.day);
    return !dayStart.isBefore(_rangeStart!) && !dayStart.isAfter(_rangeEnd!);
  }

  bool _isRangeEndpoint(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    return isSameDay(dayStart, _rangeStart) || isSameDay(dayStart, _rangeEnd);
  }

  List<DateTime> _datesInRange() {
    if (!_hasCompleteRange) return const [];
    return enumerateDays(_rangeStart!, _rangeEnd!);
  }

  void _handleLongPress(DateTime day) {
    final dayStart = startOfDay(day);
    final todayStart = widget.history.today;
    if (dayStart.isAfter(todayStart)) return;

    final next = expandRange(RangeBounds(_rangeStart, _rangeEnd), dayStart);
    if (next.start == _rangeStart && next.end == _rangeEnd) {
      return;
    }
    setState(() {
      _rangeStart = next.start;
      _rangeEnd = next.end;
    });
  }

  void _clearRange() {
    setState(() {
      _rangeStart = null;
      _rangeEnd = null;
    });
  }

  int _projectedReturns(PracticeHistory history, Iterable<DateTime> days) {
    return history.returns +
        days.toSet().difference(history.lifetimeDays).length;
  }

  Future<void> _showBulkAddDialog(BuildContext context) async {
    if (!_hasCompleteRange) return;
    final dates = _datesInRange();

    final history = widget.history;
    final existing = history.days;
    final newSessionDays = dates.where((d) {
      final start = DateTime(d.year, d.month, d.day);
      return !existing.contains(start);
    }).toList();
    final projected = _projectedReturns(history, dates);

    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => BulkAddSessionsDialog(
        rangeStart: _rangeStart!,
        rangeEnd: _rangeEnd!,
        dayCount: dates.length,
        newSessionsCount: newSessionDays.length,
        currentReturns: history.returns,
        projectedReturns: projected,
      ),
    );

    if (minutes == null || !mounted) return;

    setState(() {
      _isAddingSession = true;
    });

    final added = await addManualSessions(
      dates: newSessionDays,
      durationMinutes: minutes,
    );

    if (!mounted) return;

    setState(() {
      _isAddingSession = false;
      _rangeStart = null;
      _rangeEnd = null;
      if (added > 0) {
        _selectedDay = dates.last;
        _selectedDayForSessions = DateTime(
          dates.last.year,
          dates.last.month,
          dates.last.day,
        );
        _focusedDay = dates.last;
      }
    });
    _animationController.forward();
  }

  BulkSessionPreview _computeBulkPreview(DateTime start, DateTime end) {
    final dates = enumerateDays(start, end);
    final history = widget.history;
    final existing = history.days;
    final newSessions = dates.where((d) => !existing.contains(d)).length;
    final projected = _projectedReturns(history, dates);
    return BulkSessionPreview(
      dayCount: dates.length,
      newSessionsCount: newSessions,
      currentReturns: history.returns,
      projectedReturns: projected,
    );
  }

  Future<void> _showAddSessionDialog(BuildContext context) async {
    final selectedDate = _selectedDayForSessions;

    final result = await showDialog<ManualSessionResult>(
      context: context,
      // The dialog has an explicit Cancel button; a barrier tap silently
      // discarding the user's input here looks like a successful add.
      barrierDismissible: false,
      builder: (context) => ManualSessionDialog(
        selectedDate: selectedDate,
        bulkPreviewBuilder: _computeBulkPreview,
      ),
    );

    if (result == null || !mounted) return;

    switch (result) {
      case ManualSessionSingleResult(:final dateTime, :final duration):
        setState(() {
          _isAddingSession = true;
          final dayStart = DateTime(
            dateTime.year,
            dateTime.month,
            dateTime.day,
          );
          _selectedDayForSessions = dayStart;
          _selectedDay = dayStart;
          _focusedDay = dayStart;
        });
        _animationController.forward();

        final success = await addManualSession(
          dateTime: dateTime,
          durationMinutes: duration,
        );

        if (success && mounted) {
          await ref.read(statsProvider.notifier).refreshFromLocal();
        }

        if (mounted) {
          setState(() {
            _isAddingSession = false;
          });
        }
      case ManualSessionBulkResult(
        :final rangeStart,
        :final rangeEnd,
        :final duration,
      ):
        final dates = enumerateDays(rangeStart, rangeEnd);
        final history = widget.history;
        final existing = history.days;
        final newSessionDays = dates
            .where((d) => !existing.contains(d))
            .toList();

        setState(() {
          _isAddingSession = true;
        });

        await addManualSessions(
          dates: newSessionDays,
          durationMinutes: duration,
        );

        if (!mounted) return;

        await ref.read(statsProvider.notifier).refreshFromLocal();

        if (!mounted) return;

        setState(() {
          _isAddingSession = false;
          final last = dates.isNotEmpty ? dates.last : rangeEnd;
          _selectedDay = last;
          _selectedDayForSessions = DateTime(last.year, last.month, last.day);
          _focusedDay = last;
        });
        _animationController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    final meditationDates = history.days;
    final sessions = [...?history.sessionsByDay[_selectedDayForSessions]]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final rangeDays = _datesInRange();
    final rangeNewSessions = rangeDays
        .where((day) => !meditationDates.contains(day))
        .length;
    final rangeProjectedReturns = _projectedReturns(history, rangeDays);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildCalendarCard(context, meditationDates: meditationDates),
        _buildDayDetailsCard(
          context,
          sessions: sessions,
          rangeDays: rangeDays,
          rangeNewSessions: rangeNewSessions,
          currentReturns: history.returns,
          rangeProjectedReturns: rangeProjectedReturns,
        ),
      ],
    );
  }

  Widget _buildCalendarCard(
    BuildContext context, {
    required Set<DateTime> meditationDates,
  }) {
    return Container(
      decoration: _cardDecoration(context),
      padding: const EdgeInsets.all(16),
      child: TableCalendar<dynamic>(
        firstDay: DateTime.utc(2020, 1, 1),
        lastDay: widget.history.today,
        currentDay: widget.history.today,
        focusedDay: _focusedDay.isAfter(widget.history.today)
            ? widget.history.today
            : _focusedDay,
        selectedDayPredicate: (day) {
          // While a range is active, only range endpoints get selected styling.
          if (_rangeStart != null) return _isRangeEndpoint(day);
          return isSameDay(_selectedDay, day);
        },
        calendarFormat: CalendarFormat.month,
        startingDayOfWeek: StartingDayOfWeek.monday,
        headerStyle: _calendarHeaderStyle(context),
        calendarStyle: _calendarStyle(context),
        calendarBuilders: CalendarBuilders(
          defaultBuilder: (context, date, events) => _buildDefaultDayCell(
            context,
            date,
            meditationDates: meditationDates,
          ),
          todayBuilder: (context, date, events) => _buildTodayDayCell(
            context,
            date,
            meditationDates: meditationDates,
          ),
          selectedBuilder: (context, date, events) =>
              _buildSelectedDayCell(context, date),
        ),
        daysOfWeekStyle: _daysOfWeekStyle(context),
        onDaySelected: _onDaySelected,
        onDayLongPressed: (day, focusedDay) => _handleLongPress(day),
        onPageChanged: (focusedDay) {
          setState(() {
            _focusedDay = focusedDay;
          });
        },
      ),
    );
  }

  HeaderStyle _calendarHeaderStyle(BuildContext context) {
    final theme = Theme.of(context);
    return HeaderStyle(
      formatButtonVisible: false,
      titleCentered: true,
      titleTextStyle:
          theme.textTheme.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: googleSans,
          ) ??
          TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: googleSans,
            color: theme.colorScheme.onSurface,
          ),
      leftChevronIcon: MeditoIcon(
        assetName: MeditoIcons.arrowLeft,
        size: 20,
        color: theme.colorScheme.onSurface,
      ),
      rightChevronIcon: MeditoIcon(
        assetName: MeditoIcons.arrowRight,
        size: 20,
        color: theme.colorScheme.onSurface,
      ),
    );
  }

  CalendarStyle _calendarStyle(BuildContext context) {
    return CalendarStyle(
      outsideDaysVisible: false,
      weekendTextStyle: _dayTextStyle(context),
      defaultTextStyle: _dayTextStyle(context),
      selectedDecoration: BoxDecoration(
        color: context.brandAccent,
        shape: BoxShape.circle,
      ),
      todayTextStyle: _dayTextStyle(context, fontWeight: FontWeight.w600),
      todayDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: context.brandAccent, width: 2),
      ),
    );
  }

  DaysOfWeekStyle _daysOfWeekStyle(BuildContext context) {
    final style = (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
        .copyWith(
          fontFamily: googleSans,
          color: Theme.of(context).colorScheme.onSurface.withOpacityValue(0.6),
          fontSize: 12,
        );

    return DaysOfWeekStyle(weekdayStyle: style, weekendStyle: style);
  }

  Widget? _buildDefaultDayCell(
    BuildContext context,
    DateTime date, {
    required Set<DateTime> meditationDates,
  }) {
    final dayStart = startOfDay(date);
    final hasMeditation = meditationDates.contains(dayStart);
    final inRange = _isInRange(date);

    if (inRange && !hasMeditation) {
      return _buildDayCircle(
        context,
        date,
        color: context.brandAccent.withOpacityValue(0.20),
      );
    }

    if (hasMeditation) {
      return _buildDayCircle(
        context,
        date,
        color: context.brandAccent.withOpacityValue(inRange ? 0.32 : 0.15),
        fontWeight: FontWeight.w600,
      );
    }

    return null;
  }

  Widget _buildTodayDayCell(
    BuildContext context,
    DateTime date, {
    required Set<DateTime> meditationDates,
  }) {
    final dayStart = startOfDay(date);
    final hasMeditation = meditationDates.contains(dayStart);
    final backgroundColor = hasMeditation
        ? context.brandAccent.withOpacityValue(0.25)
        : Theme.of(context).colorScheme.surface;

    return _buildDayCircle(
      context,
      date,
      color: backgroundColor,
      fontWeight: FontWeight.w600,
      border: Border.all(color: context.brandAccent, width: 2),
    );
  }

  Widget _buildSelectedDayCell(BuildContext context, DateTime date) {
    final fillColor = context.brandAccent;

    if (_isRangeEndpoint(date)) {
      return Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: fillColor.withOpacityValue(0.30),
          shape: BoxShape.circle,
        ),
        child: _buildDayCircle(
          context,
          date,
          color: fillColor,
          margin: const EdgeInsets.all(3),
          textColor: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      );
    }

    return _buildDayCircle(
      context,
      date,
      color: fillColor,
      textColor: Theme.of(context).colorScheme.onPrimary,
      fontWeight: FontWeight.w700,
    );
  }

  Widget _buildDayCircle(
    BuildContext context,
    DateTime date, {
    required Color color,
    EdgeInsets margin = const EdgeInsets.all(4),
    Color? textColor,
    FontWeight? fontWeight,
    BoxBorder? border,
  }) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: border,
      ),
      child: Center(
        child: Text(
          '${date.day}',
          style: _dayTextStyle(
            context,
            color: textColor,
            fontWeight: fontWeight,
          ),
        ),
      ),
    );
  }

  TextStyle _dayTextStyle(
    BuildContext context, {
    Color? color,
    FontWeight? fontWeight,
  }) {
    final theme = Theme.of(context);
    return (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontFamily: googleSans,
      color: color ?? theme.colorScheme.onSurface,
      fontWeight: fontWeight,
    );
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    // A regular tap dismisses any in-progress range and behaves like
    // single-day selection.
    if (_rangeStart != null) {
      _clearRange();
    }
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });
    _toggleDaySessions(selectedDay);
  }

  Widget _buildDayDetailsCard(
    BuildContext context, {
    required List<LocalAudioCompleted> sessions,
    required List<DateTime> rangeDays,
    required int rangeNewSessions,
    required int currentReturns,
    required int rangeProjectedReturns,
  }) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Container(
        margin: const EdgeInsets.only(top: 16),
        decoration: _cardDecoration(context),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailsTitle(context, rangeDays),
            const SizedBox(height: 8),
            _buildDetailsSubtitle(context, sessions),
            const SizedBox(height: 16),
            _buildSessionList(context, sessions),
            const SizedBox(height: 16),
            _hasCompleteRange
                ? _buildRangeActions(
                    context,
                    rangeNewSessions: rangeNewSessions,
                    currentReturns: currentReturns,
                    rangeProjectedReturns: rangeProjectedReturns,
                  )
                : _buildAddSessionButton(context),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsTitle(BuildContext context, List<DateTime> rangeDays) {
    return Text(
      _hasCompleteRange
          ? AppLocalizations.of(context)!.daysSelected(rangeDays.length)
          : DateFormat('EEEE, MMMM d, y').format(_selectedDayForSessions),
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontFamily: googleSans,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildDetailsSubtitle(
    BuildContext context,
    List<LocalAudioCompleted> sessions,
  ) {
    final l10n = AppLocalizations.of(context)!;

    if (_hasCompleteRange) {
      return Text(
        '${DateFormat('MMM d').format(_rangeStart!)} – ${DateFormat('MMM d, y').format(_rangeEnd!)}',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: googleSans,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );
    }

    return Text(
      '${sessions.length} ${sessions.length == 1 ? l10n.session : l10n.sessions}',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontFamily: googleSans,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildSessionList(
    BuildContext context,
    List<LocalAudioCompleted> sessions,
  ) {
    if (_isAddingSession) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: CircularProgressIndicator(color: context.brandAccent),
        ),
      );
    }

    if (_hasCompleteRange || sessions.isEmpty) return const SizedBox.shrink();

    return Column(
      children: sessions.asMap().entries.map((entry) {
        final index = entry.key;
        final session = entry.value;
        final isLast = index == sessions.length - 1;
        return Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
          child: _SessionItemWidget(
            key: ValueKey(session.id + session.timestamp.toString()),
            session: session,
            onLongPress: () => _confirmDeleteSession(session),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildRangeActions(
    BuildContext context, {
    required int rangeNewSessions,
    required int currentReturns,
    required int rangeProjectedReturns,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: context.brandAccent.withOpacityValue(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RangePreviewRow(
                label: l10n.returnsLabel,
                value: '$currentReturns',
              ),
              const SizedBox(height: 6),
              _RangePreviewRow(
                label: l10n.projectedReturnsLabel,
                value: '$rangeProjectedReturns',
                emphasize: rangeProjectedReturns != currentReturns,
              ),
              const SizedBox(height: 6),
              _RangePreviewRow(
                label: l10n.newSessions,
                value: '$rangeNewSessions',
              ),
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _isAddingSession || rangeNewSessions == 0
                ? null
                : () => _showBulkAddDialog(context),
            icon: Icon(
              Icons.add,
              size: 20,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            label: Text(
              l10n.addSessionsToSelectedDays,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: googleSans,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: Colors.transparent,
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              side: BorderSide(color: context.brandAccent),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: _isAddingSession ? null : _clearRange,
            child: Text(
              l10n.cancel,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: googleSans,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withOpacityValue(0.7),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAddSessionButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _showAddSessionDialog(context),
        icon: Icon(
          Icons.add,
          size: 20,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        label: Text(
          AppLocalizations.of(context)!.addSession,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFamily: googleSans,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withOpacityValue(0.2),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration(BuildContext context) {
    return BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: Theme.of(context).colorScheme.onSurface.withOpacityValue(0.08),
        width: 1,
      ),
    );
  }
}

class _SessionItemWidget extends ConsumerWidget {
  final LocalAudioCompleted session;
  final VoidCallback? onLongPress;

  const _SessionItemWidget({
    super.key,
    required this.session,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = DateTime.fromMillisecondsSinceEpoch(session.timestamp);
    final timeFormat = DateFormat('h:mm a');
    final isManual = isManualSession(session);
    final timerLength = timerSessionDuration(session.id);
    final isTimer = timerLength != null;
    final trackAsync = isManual || isTimer
        ? null
        : ref.watch(tracksProvider(trackId: session.id));

    final content = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withOpacityValue(0.08),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              timeFormat.format(date),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: googleSans,
                fontWeight: FontWeight.w600,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withOpacityValue(0.7),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isManual ? ColorConstants.graphite : context.brandAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: isTimer
                ? Text(
                    AppLocalizations.of(context)!.timerHistoryTitle(
                      formatTimerLength(
                        timerLength,
                        AppLocalizations.of(context)!,
                      ),
                    ),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: googleSans,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  )
                : isManual
                ? Text(
                    getManualSessionTitle(
                      session.id,
                      AppLocalizations.of(context)!,
                    ),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: googleSans,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  )
                : trackAsync!.when(
                    data: (track) => Text(
                      track.title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: googleSans,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    loading: () => Text(
                      'Loading...',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: googleSans,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    error: (_, _) => Text(
                      'Track ${session.id}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: googleSans,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
          ),
          if (!isManual)
            Icon(
              Icons.chevron_right_rounded,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withOpacityValue(0.6),
              size: 20,
            ),
        ],
      ),
    );

    if (isManual) {
      return InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: content,
      );
    }

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => isTimer
                ? const TimerView(source: AnalyticsEventConstants.sourceHistory)
                : TrackView(trackId: session.id),
          ),
        );
      },
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: content,
    );
  }
}

class _RangePreviewRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;

  const _RangePreviewRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: googleSans,
            color: theme.colorScheme.onSurface.withOpacityValue(0.75),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: googleSans,
            fontWeight: FontWeight.w700,
            color: emphasize
                ? context.brandAccent
                : theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
