import 'dart:math';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  group('W3C Trace Context', () {
    const propagator = W3CTraceContextPropagator();
    const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
    const spanId = '00f067aa0ba902b7';

    test('accepts future versions with opaque trailing fields', () {
      final context = propagator.extract({
        'traceparent': '01-$traceId-$spanId-09-extra',
      });

      expect(context?.traceId, traceId);
      expect(context?.spanId, spanId);
      expect(context?.sampled, isTrue);
    });

    test('rejects forbidden version, uppercase IDs, and short headers', () {
      for (final value in [
        'ff-$traceId-$spanId-01',
        '00-${traceId.toUpperCase()}-$spanId-01',
        '01-$traceId-$spanId',
        '00-$traceId-$spanId-01-extra',
      ]) {
        expect(propagator.extract({'traceparent': value}), isNull);
      }
    });

    test('keeps valid tracestate and drops invalid tracestate only', () {
      final valid = propagator.extract({
        'traceparent': '00-$traceId-$spanId-01',
        'tracestate': 'rojo=00f067aa0ba902b7,congo=t61rcWkgMzE',
      });
      final invalid = propagator.extract({
        'traceparent': '00-$traceId-$spanId-01',
        'tracestate': 'duplicate=one,duplicate=two',
      });

      expect(valid?.traceState, 'rojo=00f067aa0ba902b7,congo=t61rcWkgMzE');
      expect(invalid?.isValid, isTrue);
      expect(invalid?.traceState, isNull);
    });

    test('does not inject invalid tracestate', () {
      final carrier = <String, String>{};
      propagator.inject(
        const SpanContext(
          traceId: traceId,
          spanId: spanId,
          sampled: true,
          traceState: 'bad=value\nheader=injection',
        ),
        carrier,
      );

      expect(carrier['traceparent'], isNotNull);
      expect(carrier.containsKey('tracestate'), isFalse);
    });

    test('never throws for 10000 arbitrary byte strings', () {
      final random = Random(82731);
      for (var sample = 0; sample < 10000; sample++) {
        final value = String.fromCharCodes(
          List.generate(random.nextInt(256), (_) => random.nextInt(256)),
        );
        expect(
          () => propagator.extract({'traceparent': value, 'tracestate': value}),
          returnsNormally,
        );
      }
    });
  });

  group('W3C Baggage', () {
    test('round-trips unicode values and structured properties', () {
      const propagator = W3CBaggagePropagator();
      final carrier = <String, String>{};
      final baggage = Baggage.empty.set(
        'userId',
        'Amélie 東京',
        metadata: 'source=edge;secure',
      );

      propagator.inject(baggage, carrier);
      final extracted = propagator.extract(carrier);

      expect(extracted.value('userId'), 'Amélie 東京');
      expect(extracted['userId']?.metadata, 'source=edge;secure');
      expect(carrier['baggage'], isNot(contains('東京')));
    });

    test('invalid keys and properties are not injected', () {
      const propagator = W3CBaggagePropagator();
      final carrier = <String, String>{};
      final baggage = Baggage({
        'bad key': const BaggageEntry('one'),
        'valid': const BaggageEntry('two', metadata: 'bad,property'),
      });

      propagator.inject(baggage, carrier);

      expect(carrier.containsKey('baggage'), isFalse);
    });

    test('invalid received properties and non-ASCII headers are dropped', () {
      const propagator = W3CBaggagePropagator();
      expect(
        propagator.extract({'baggage': 'valid=one;bad key=x'}).entries,
        isEmpty,
      );
      expect(propagator.extract({'baggage': 'valid=東京'}).entries, isEmpty);
    });

    test('configured limits are enforced without partial members', () {
      const propagator = W3CBaggagePropagator(
        maxEntries: 2,
        maxHeaderLength: 20,
        maxEntryLength: 12,
      );
      final carrier = <String, String>{};
      propagator.inject(
        Baggage.empty
            .set('first', '1')
            .set('oversized', '123456789')
            .set('third', '3'),
        carrier,
      );

      expect(carrier['baggage'], 'first=1');
      expect(
        propagator.extract({'baggage': 'a=1,b=2,c=3'}).entries,
        hasLength(2),
      );
    });

    test('invalid limit configurations fail deterministically', () {
      expect(
        () => const W3CBaggagePropagator(maxEntries: 0).extract(const {}),
        throwsArgumentError,
      );
      expect(
        () => const W3CBaggagePropagator(
          maxHeaderLength: 2,
          maxEntryLength: 3,
        ).inject(Baggage.empty, {}),
        throwsArgumentError,
      );
    });

    test('never throws for 10000 arbitrary byte strings', () {
      const propagator = W3CBaggagePropagator();
      final random = Random(9172);
      for (var sample = 0; sample < 10000; sample++) {
        final value = String.fromCharCodes(
          List.generate(random.nextInt(256), (_) => random.nextInt(256)),
        );
        expect(() => propagator.extract({'baggage': value}), returnsNormally);
      }
    });
  });
}
