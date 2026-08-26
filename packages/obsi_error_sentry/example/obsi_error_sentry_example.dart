import 'package:obsi/obsi.dart';
import 'package:obsi_error_sentry/obsi_error_sentry.dart';

void main() {
  Errors.configure(ErrorManager(exporter: SentryErrorExporter()));
}
