import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/injection.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../application/feed/feed_status.dart';
import '../../application/feed/feed_update.dart';
import '../../application/quote_store.dart';
import '../../domain/models/instrument.dart';
import '../bloc/watchlist_bloc.dart';
import '../widgets/connection_badge.dart';
import '../widgets/feed_diagnostics.dart';
import '../widgets/price_row.dart';
import '../widgets/status_banner.dart';

class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<WatchlistBloc>(
      create: (_) => getIt<WatchlistBloc>()..add(const WatchlistStarted()),
      child: const _WatchlistView(),
    );
  }
}

class _WatchlistView extends StatelessWidget {
  const _WatchlistView();

  @override
  Widget build(BuildContext context) {
    return BlocListener<WatchlistBloc, WatchlistState>(
      // The feed gives up only when credentials are rejected; that is the one
      // failure the user has to resolve, so hand them back to the login screen.
      listenWhen: (previous, current) => current.connection is FeedFatal,
      listener: (context, state) {
        final status = state.connection as FeedFatal;
        context.read<AuthBloc>().add(AuthSessionExpired(status.message));
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pulse'),
          actions: [
            BlocSelector<WatchlistBloc, WatchlistState, FeedStatus>(
              selector: (state) => state.connection,
              builder: (context, connection) =>
                  ConnectionBadge(status: connection),
            ),
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout, size: 20),
              onPressed: () =>
                  context.read<AuthBloc>().add(const AuthLogoutRequested()),
            ),
          ],
        ),
        body: BlocSelector<WatchlistBloc, WatchlistState, WatchlistStatus>(
          selector: (state) => state.status,
          builder: (context, status) => switch (status) {
            WatchlistStatus.loading => const Center(
              child: CircularProgressIndicator(),
            ),
            WatchlistStatus.failure => const _LoadFailure(),
            WatchlistStatus.ready => const _Watchlist(),
          },
        ),
      ),
    );
  }
}

class _Watchlist extends StatelessWidget {
  const _Watchlist();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Rebuilds on status changes only — a handful of times a minute.
        BlocSelector<WatchlistBloc, WatchlistState, FeedStatus>(
          selector: (state) => state.connection,
          builder: (context, connection) => StatusBanner(status: connection),
        ),
        Expanded(
          child: Stack(
            children: [
              const _InstrumentList(),
              // The staleness treatment is a scrim *over* the list rather than
              // an opacity *around* it: wrapping the list would rebuild every
              // visible row on each connection change, and this way nothing
              // below it is touched at all.
              Positioned.fill(
                child: BlocSelector<WatchlistBloc, WatchlistState, bool>(
                  selector: (state) => state.pricesMayBeStale,
                  builder: (context, stale) => IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: stale ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: const ColoredBox(color: Color(0x9912151A)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        BlocSelector<WatchlistBloc, WatchlistState, FeedStats>(
          selector: (state) => state.stats,
          builder: (context, stats) => FeedDiagnostics(stats: stats),
        ),
      ],
    );
  }
}

/// The list itself. Deliberately watches only [WatchlistState.instruments],
/// which is set once, so nothing about the connection or the prices can cause
/// it to rebuild.
class _InstrumentList extends StatelessWidget {
  const _InstrumentList();

  @override
  Widget build(BuildContext context) {
    final quotes = getIt<QuoteStore>();
    return BlocSelector<WatchlistBloc, WatchlistState, List<Instrument>>(
      selector: (state) => state.instruments,
      builder: (context, instruments) => ListView.builder(
        // A fixed extent lets the viewport skip measuring children, which
        // keeps scrolling cheap while the feed is bursting.
        itemExtent: PriceRow.height,
        itemCount: instruments.length,
        itemBuilder: (context, index) {
          final instrument = instruments[index];
          return PriceRow(
            key: ValueKey(instrument.symbol),
            instrument: instrument,
            quotes: quotes,
          );
        },
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44),
            const SizedBox(height: 16),
            BlocSelector<WatchlistBloc, WatchlistState, String?>(
              selector: (state) => state.error,
              builder: (context, error) => Text(
                error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => context.read<WatchlistBloc>().add(
                const WatchlistRetryRequested(),
              ),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
