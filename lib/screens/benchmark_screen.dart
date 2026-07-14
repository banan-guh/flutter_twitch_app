import 'dart:async';
import 'package:flutter/material.dart';
import '../benchmark/message_latency_benchmark.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';

class BenchmarkScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final List<String> availableChannels;
  final Stream<TwitchMessage>? eventSubMessages;

  const BenchmarkScreen({
    super.key,
    required this.twitchAuth,
    this.availableChannels = const [],
    this.eventSubMessages,
  });

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

enum _Phase { idle, resolving, running, done }

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  _Phase _phase = _Phase.idle;
  String? _error;
  String _channelLogin = '';
  List<PerMessageResult> _results = [];
  String _senderLogin = '';
  String _senderId = '';
  String _broadcasterId = '';
  bool _hasEventSub = false;

  final _channelCtrl = TextEditingController();
  final _numCtrl = TextEditingController(text: '10');

  @override
  void initState() {
    super.initState();
    _hasEventSub = widget.eventSubMessages != null;
    if (widget.availableChannels.isNotEmpty) {
      _channelLogin = widget.availableChannels.first;
      _channelCtrl.text = _channelLogin;
    }
  }

  @override
  void dispose() {
    _channelCtrl.dispose();
    _numCtrl.dispose();
    super.dispose();
  }

  Future<void> _runBenchmark() async {
    final channel = _channelCtrl.text.trim().toLowerCase();
    if (channel.isEmpty) {
      setState(() => _error = 'Enter a channel name.');
      return;
    }

    setState(() {
      _phase = _Phase.resolving;
      _error = null;
      _results = [];
    });

    try {
      final currentUser = await TwitchApi.getCurrentUser(widget.twitchAuth);
      if (currentUser == null) {
        setState(() {
          _phase = _Phase.idle;
          _error = 'Could not resolve current user. Is your token valid?';
        });
        return;
      }
      _senderLogin = currentUser['login']!;
      _senderId = currentUser['id']!;

      final bcId = await TwitchApi.getUserId(widget.twitchAuth, channel);
      if (bcId == null) {
        setState(() {
          _phase = _Phase.idle;
          _error = 'Could not resolve broadcaster ID for "$channel".';
        });
        return;
      }
      _broadcasterId = bcId;

      setState(() => _phase = _Phase.running);

      final bench = LatencyBenchmark(
        auth: widget.twitchAuth,
        channelLogin: channel,
        broadcasterId: _broadcasterId,
        senderId: _senderId,
        senderLogin: _senderLogin,
        numMessages: (int.tryParse(_numCtrl.text) ?? 10).clamp(1, 50),
        eventSubMessages: widget.eventSubMessages,
      );

      _results = await bench.run();

      setState(() => _phase = _Phase.done);
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _error = 'Benchmark failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Message Latency Benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _channelCtrl,
            decoration: const InputDecoration(
              labelText: 'Channel',
              hintText: 'channel name',
              border: OutlineInputBorder(),
            ),
            enabled: _phase == _Phase.idle,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Messages to send:'),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: TextField(
                  keyboardType: TextInputType.number,
                  enabled: _phase == _Phase.idle,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  controller: _numCtrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _hasEventSub
                ? 'EventSub: observing existing connection'
                : 'EventSub: not available (N/A)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          _phase == _Phase.idle || _phase == _Phase.done
              ? FilledButton.icon(
                  onPressed: _phase == _Phase.running || _phase == _Phase.resolving
                      ? null
                      : _runBenchmark,
                  icon: const Icon(Icons.speed),
                  label: Text(_phase == _Phase.done
                      ? 'Run again'
                      : 'Start Benchmark'),
                )
              : const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('Per-message latencies (ms):',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildTable(),
            const SizedBox(height: 24),
            const Text('Summary (ms):',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildSummary(),
          ],
        ],
      ),
    );
  }

  Widget _buildTable() {
    final rows = <DataRow>[];
    for (final r in _results) {
      rows.add(DataRow(cells: [
        DataCell(Text('${r.index}')),
        DataCell(Text(r.postRtt.inMilliseconds.toString())),
        DataCell(Text(r.eventSubDelivery?.inMilliseconds.toString() ?? '—')),
        DataCell(Text(r.ircDelivery?.inMilliseconds.toString() ?? '—')),
      ]));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        columns: const [
          DataColumn(label: Text('#')),
          DataColumn(label: Text('POST RTT')),
          DataColumn(label: Text('EventSub')),
          DataColumn(label: Text('IRC')),
        ],
        rows: rows,
      ),
    );
  }

  List<Duration> _nonNull(List<Duration?> values) =>
      values.whereType<Duration>().toList();

  double _median(List<Duration> sorted) {
    if (sorted.isEmpty) return double.nan;
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid].inMilliseconds.toDouble();
    return (sorted[mid - 1].inMilliseconds + sorted[mid].inMilliseconds) / 2.0;
  }

  Widget _buildSummary() {
    final esValues = _nonNull(_results.map((r) => r.eventSubDelivery).toList());
    final ircValues = _nonNull(_results.map((r) => r.ircDelivery).toList());

    esValues.sort((a, b) => a.compareTo(b));
    ircValues.sort((a, b) => a.compareTo(b));

    return DataTable(columns: const [
      DataColumn(label: Text('Metric')),
      DataColumn(label: Text('EventSub')),
      DataColumn(label: Text('IRC')),
    ], rows: [
      DataRow(cells: [
        const DataCell(Text('Count')),
        DataCell(Text('${esValues.length}')),
        DataCell(Text('${ircValues.length}')),
      ]),
      DataRow(cells: [
        const DataCell(Text('Min')),
        DataCell(Text(esValues.isNotEmpty
            ? '${esValues.first.inMilliseconds}'
            : '—')),
        DataCell(Text(ircValues.isNotEmpty
            ? '${ircValues.first.inMilliseconds}'
            : '—')),
      ]),
      DataRow(cells: [
        const DataCell(Text('Max')),
        DataCell(Text(esValues.isNotEmpty
            ? '${esValues.last.inMilliseconds}'
            : '—')),
        DataCell(Text(ircValues.isNotEmpty
            ? '${ircValues.last.inMilliseconds}'
            : '—')),
      ]),
      DataRow(cells: [
        const DataCell(Text('Average')),
        DataCell(Text(esValues.isNotEmpty
            ? '${esValues.map((e) => e.inMilliseconds).reduce((a, b) => a + b) ~/ esValues.length}'
            : '—')),
        DataCell(Text(ircValues.isNotEmpty
            ? '${ircValues.map((e) => e.inMilliseconds).reduce((a, b) => a + b) ~/ ircValues.length}'
            : '—')),
      ]),
      DataRow(cells: [
        const DataCell(Text('Median')),
        DataCell(Text(esValues.isNotEmpty
            ? _median(esValues).toStringAsFixed(0)
            : '—')),
        DataCell(Text(ircValues.isNotEmpty
            ? _median(ircValues).toStringAsFixed(0)
            : '—')),
      ]),
    ]);
  }
}
