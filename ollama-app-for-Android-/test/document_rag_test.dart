import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/document_rag.dart';

void main() {
  test('retrieves the document fragment related to the question', () {
    final context = buildDocumentRagContext(
      '¿Qué micrófono se recomienda?',
      const [
        RagDocument(
          name: 'Microfono.pdf',
          text: 'La cámara utiliza un sensor CMOS.\n\n'
              'Para grabar voz se recomienda un micrófono MEMS digital.\n\n'
              'La pantalla tiene resolución Full HD.',
        ),
      ],
      chunkSize: 90,
      overlap: 0,
      maxChunks: 1,
    );

    expect(context, contains('micrófono MEMS digital'));
    expect(context, contains('Microfono.pdf'));
  });

  test('large documents are bounded before entering model context', () {
    final context = buildDocumentRagContext(
      'needle',
      [
        RagDocument(
            name: 'large.txt',
            text: '${List.filled(5000, 'filler').join(' ')} needle')
      ],
      maxContextCharacters: 3000,
    );

    expect(context.length, lessThanOrEqualTo(3000));
    expect(context, contains('needle'));
  });

  test('small model context can cap prefill independently of chunk count', () {
    final context = buildDocumentRagContext(
      'target',
      [
        RagDocument(
          name: 'notes.txt',
          text: List.generate(
            20,
            (index) => 'Section $index target ${'detail ' * 180}',
          ).join('\n\n'),
        ),
      ],
      maxChunks: 12,
      maxContextCharacters: 4096,
    );

    expect(context.length, lessThanOrEqualTo(4096));
    expect(context, contains('target'));
  });

  test('retrieval tolerates omitted accents from keyboards and STT', () {
    final context = buildDocumentRagContext(
      'Que ocurrio durante el cumpleanos',
      const [
        RagDocument(
          name: 'diary.txt',
          text: 'Un bloque sin relación.\n\nDurante el cumpleaños ocurrió el dato buscado.',
        ),
      ],
      chunkSize: 70,
      overlap: 0,
      maxChunks: 1,
    );

    expect(context, contains('dato buscado'));
  });

  test('optional real-device long document remains retrievable', () {
    final path = Platform.environment['RAG_TEST_FILE'];
    if (path == null || !File(path).existsSync()) return;
    final context = buildDocumentRagContext(
      'Que distribucion estaba instalando durante el cumpleanos',
      [RagDocument(name: 'device-test.txt', text: File(path).readAsStringSync())],
      maxContextCharacters: 2048,
    );

    expect(context.length, lessThanOrEqualTo(2048));
    expect(context.toLowerCase(), contains('gentoo'));
  });
}
