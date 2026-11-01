import 'dart:io';
import 'package:path/path.dart' as p;

void main() {
  final projectRoot = Directory.current.path;
  final libDir = p.join(projectRoot, 'lib');
  final binDir = p.join(projectRoot, 'bin');

  final files = <String>[];

  void collectDartFiles(Directory dir) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        files.add(p.normalize(entity.path));
      }
    }
  }

  collectDartFiles(Directory(libDir));
  collectDartFiles(Directory(binDir));

  stdout.writeln('Collected ${files.length} Dart files in lib/ and bin/.');

  final importRegex = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''');
  final graph = <String, Set<String>>{};

  for (final file in files) {
    graph[file] = <String>{};
    final content = File(file).readAsStringSync();
    for (final match in importRegex.allMatches(content)) {
      final uri = match.group(1)!;
      if (uri.startsWith('dart:') || uri.startsWith('package:flutter')) {
        continue;
      }
      String? targetPath;
      if (uri.startsWith('package:side_assistant/')) {
        final rel = uri.substring('package:side_assistant/'.length);
        targetPath = p.normalize(p.join(libDir, rel));
      } else if (!uri.startsWith('package:')) {
        // Relative path
        targetPath = p.normalize(p.join(p.dirname(file), uri));
      }

      if (targetPath != null && File(targetPath).existsSync()) {
        graph[file]!.add(targetPath);
      }
    }
  }

  // Tarjan's strongly connected components algorithm
  int index = 0;
  final indices = <String, int>{};
  final lowlink = <String, int>{};
  final onStack = <String, bool>{};
  final stack = <String>[];
  final sccs = <List<String>>[];

  void strongConnect(String v) {
    indices[v] = index;
    lowlink[v] = index;
    index++;
    stack.add(v);
    onStack[v] = true;

    for (final w in graph[v] ?? <String>{}) {
      if (!indices.containsKey(w)) {
        strongConnect(w);
        if (lowlink[w]! < lowlink[v]!) {
          lowlink[v] = lowlink[w]!;
        }
      } else if (onStack[w] == true) {
        if (indices[w]! < lowlink[v]!) {
          lowlink[v] = indices[w]!;
        }
      }
    }

    if (lowlink[v] == indices[v]) {
      final scc = <String>[];
      while (true) {
        final w = stack.removeLast();
        onStack[w] = false;
        scc.add(w);
        if (w == v) break;
      }
      if (scc.length > 1) {
        sccs.add(scc);
      } else if (scc.length == 1) {
        // Check self-loop
        if (graph[v]?.contains(v) == true) {
          sccs.add(scc);
        }
      }
    }
  }

  for (final node in graph.keys) {
    if (!indices.containsKey(node)) {
      strongConnect(node);
    }
  }

  if (sccs.isEmpty) {
    stdout.writeln(
      'SUCCESS: Zero circular dependencies detected across lib/ and bin/! '
      '(0 cycles found across ${files.length} files)',
    );
    exit(0);
  } else {
    stderr.writeln('FAILURE: Found ${sccs.length} circular dependency cycle(s):');
    for (int i = 0; i < sccs.length; i++) {
      stderr.writeln('\nCycle #${i + 1} (${sccs[i].length} files):');
      for (final f in sccs[i]) {
        stderr.writeln('  - ${p.relative(f, from: projectRoot)}');
      }
    }
    exit(1);
  }
}
