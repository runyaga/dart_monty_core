import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MontyReplApp());
}

class MontyReplApp extends StatelessWidget {
  const MontyReplApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monty REPL',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4EC9B0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: const MontyReplPage(),
    );
  }
}

class MontyReplPage extends StatefulWidget {
  const MontyReplPage({super.key});

  @override
  State<MontyReplPage> createState() => _MontyReplPageState();
}

class _MontyReplPageState extends State<MontyReplPage> {
  final MontyRepl _repl = MontyRepl();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final List<_ReplLine> _lines = [
    const _ReplLine('Monty REPL initialized.', _LineKind.system),
  ];

  @override
  void dispose() {
    _repl.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _execute() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;

    _controller.clear();
    setState(() {
      _lines.add(_ReplLine('>>> $code', _LineKind.input));
    });

    try {
      final result = await _repl.feed(code);

      setState(() {
        if (result.printOutput != null && result.printOutput!.isNotEmpty) {
          _lines.add(_ReplLine(result.printOutput!, _LineKind.print));
        }
        if (result.error != null) {
          _lines.add(_ReplLine(result.error!.message, _LineKind.error));
        } else if (result.value is! MontyNone) {
          _lines.add(_ReplLine('=> ${result.value}', _LineKind.output));
        }
      });
    } on Object catch (e) {
      setState(() {
        _lines.add(_ReplLine('Error: $e', _LineKind.error));
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
      _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF333333),
        title: const Text(
          'Monty Python REPL',
          style: TextStyle(
            color: Color(0xFF4EC9B0),
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Chip(
              label: const Text(
                'Flutter',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              backgroundColor: const Color(0xFF007ACC),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                final line = _lines[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    line.text,
                    style: TextStyle(
                      color: line.kind.color,
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            color: const Color(0xFF252526),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    style: const TextStyle(
                      color: Color(0xFFCCCCCC),
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type Python code...',
                      hintStyle: TextStyle(
                        color: cs.onSurface.withOpacity(0.4),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF3C3C3C),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF555555)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF555555)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF007ACC)),
                      ),
                    ),
                    onSubmitted: (_) => _execute(),
                    autofocus: true,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _execute,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0E639C),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: const Text(
                    'Run',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _LineKind {
  input,
  output,
  print,
  error,
  system
  ;

  Color get color => switch (this) {
    _LineKind.input => const Color(0xFF9CDCFE),
    _LineKind.output => const Color(0xFFDCDCAA),
    _LineKind.print => const Color(0xFFB5CEA8),
    _LineKind.error => const Color(0xFFF44747),
    _LineKind.system => const Color(0xFF6A9955),
  };
}

class _ReplLine {
  const _ReplLine(this.text, this.kind);
  final String text;
  final _LineKind kind;
}
