import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:obsi/obsi.dart';

/// Defines the obsi route name resolver type.
typedef ObsiRouteNameResolver = String? Function(Route<dynamic> route);

/// Defines the obsi route predicate type.
typedef ObsiRoutePredicate = bool Function(Route<dynamic> route);

/// Defines the obsi navigation attribute builder type.
typedef ObsiNavigationAttributeBuilder =
    Map<String, Object?> Function(
      String operation,
      Route<dynamic>? route,
      Route<dynamic>? previousRoute,
    );

/// Represents obsi navigation attributes.
abstract final class ObsiNavigationAttributes {
  /// The operation.
  static const operation = 'navigation.operation';

  /// The navigator name.
  static const navigatorName = 'navigation.navigator.name';

  /// The route type.
  static const routeType = 'navigation.route.type';

  /// The previous route name.
  static const previousRouteName = 'navigation.previous_route.name';

  /// The app screen name.
  static const appScreenName = 'app.screen.name';
}

/// Represents obsi navigation metrics.
abstract final class ObsiNavigationMetrics {
  /// The transition count.
  static const transitionCount = 'navigation.transition.count';

  /// The screen visible duration.
  static const screenVisibleDuration = 'navigation.screen.visible.duration';
}

/// Represents obsi navigator observer options.
final class ObsiNavigatorObserverOptions {
  /// Creates a instance.
  const ObsiNavigatorObserverOptions({
    this.routeNameResolver,
    this.shouldInstrument,
    this.attributes,
    this.includeUnnamedRoutes = false,
    this.recordBreadcrumbs = true,
    this.emitLogs = false,
    this.traceUserGestures = true,
    this.onInstrumentationError,
  });

  /// Defaults to [RouteSettings.name]. No route `toString()` fallback is used,
  /// because it can expose arguments or other user data.
  final ObsiRouteNameResolver? routeNameResolver;

  /// The should instrument.
  final ObsiRoutePredicate? shouldInstrument;

  /// The attributes.
  final ObsiNavigationAttributeBuilder? attributes;

  /// The include unnamed routes.
  final bool includeUnnamedRoutes;

  /// The record breadcrumbs.
  final bool recordBreadcrumbs;

  /// Logs also become generic `log` breadcrumbs with Obsi's default logger.
  /// Keep this disabled when navigation-category breadcrumbs are preferred.
  final bool emitLogs;

  /// The trace user gestures.
  final bool traceUserGestures;

  /// The on instrumentation error.
  final TelemetryErrorHandler? onInstrumentationError;
}

/// Observes any Flutter [Navigator], including those managed by go_router.
///
/// Install one observer per navigator and give nested navigators distinct
/// [navigatorName] values.
final class ObsiNavigatorObserver extends NavigatorObserver {
  /// Creates a instance.
  ObsiNavigatorObserver({
    Tracer? tracer,
    Meter? meter,
    Logger? logger,
    this.navigatorName = 'root',
    this.options = const ObsiNavigatorObserverOptions(),
  }) : tracer = tracer ?? Trace.tracer,
       logger = logger ?? Logs.getLogger('obsi.flutter.navigation'),
       _transitionCount = (meter ?? Metrics.getMeter('obsi.flutter.navigation'))
           ?.createCounter<int>(ObsiNavigationMetrics.transitionCount),
       _visibleDuration = (meter ?? Metrics.getMeter('obsi.flutter.navigation'))
           ?.createHistogram<double>(
             ObsiNavigationMetrics.screenVisibleDuration,
             unit: 's',
           );

  /// The tracer.
  final Tracer tracer;

  /// The logger.
  final Logger logger;

  /// The navigator name.
  final String navigatorName;

  /// The options.
  final ObsiNavigatorObserverOptions options;
  final Counter<int>? _transitionCount;
  final Histogram<double>? _visibleDuration;
  final HashMap<Route<dynamic>, _Visibility> _visible = HashMap.identity();
  Route<dynamic>? _topRoute;

  /// Performs did push.
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _transition('push', route, previousRoute);
    super.didPush(route, previousRoute);
  }

  /// Performs did pop.
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _transition('pop', previousRoute, route);
    _deactivate(route);
    super.didPop(route, previousRoute);
  }

  /// Performs did remove.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _transition('remove', previousRoute, route);
    _deactivate(route);
    super.didRemove(route, previousRoute);
  }

  /// Performs did replace.
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _transition('replace', newRoute, oldRoute);
    if (identical(_topRoute, oldRoute)) {
      _deactivate(oldRoute);
      _activate(newRoute);
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  /// Performs did change top.
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _deactivate(previousTopRoute);
    _activate(topRoute);
    super.didChangeTop(topRoute, previousTopRoute);
  }

  /// Performs did start user gesture.
  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    if (options.traceUserGestures) {
      _transition('gesture.start', route, previousRoute);
    }
    super.didStartUserGesture(route, previousRoute);
  }

  /// Performs did stop user gesture.
  @override
  void didStopUserGesture() {
    if (options.traceUserGestures) {
      _transition('gesture.stop', _topRoute, null);
    }
    super.didStopUserGesture();
  }

  void _transition(
    String operation,
    Route<dynamic>? route,
    Route<dynamic>? previousRoute,
  ) {
    try {
      if (route != null && !_shouldInstrument(route)) return;
      final routeName = _routeName(route);
      if (route != null && routeName == null && !options.includeUnnamedRoutes) {
        return;
      }
      final previousName = _routeName(previousRoute);
      final attributes = <String, Object?>{
        ObsiNavigationAttributes.operation: operation,
        ObsiNavigationAttributes.navigatorName: navigatorName,
        ObsiNavigationAttributes.appScreenName: ?routeName,
        ObsiNavigationAttributes.previousRouteName: ?previousName,
        if (route != null)
          ObsiNavigationAttributes.routeType: route.runtimeType.toString(),
        ..._customAttributes(operation, route, previousRoute),
      };
      final span = tracer.startSpan(
        'navigation $operation',
        attributes: attributes,
      );
      span.end();
      _transitionCount?.add(
        1,
        attributes: {
          ObsiNavigationAttributes.operation: operation,
          ObsiNavigationAttributes.navigatorName: navigatorName,
          ObsiNavigationAttributes.appScreenName: ?routeName,
        },
      );
      if (options.emitLogs) {
        logger.info('Navigation $operation', attributes: attributes);
      }
      if (options.recordBreadcrumbs) {
        Errors.addBreadcrumb(
          ErrorBreadcrumb(
            timestamp: DateTime.now(),
            category: 'navigation',
            message: routeName == null ? operation : '$operation $routeName',
            data: attributes,
          ),
        );
      }
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  void _activate(Route<dynamic>? route) {
    if (route == null || identical(_topRoute, route)) return;
    _topRoute = route;
    if (!_shouldInstrument(route)) return;
    final name = _routeName(route);
    if (name == null && !options.includeUnnamedRoutes) return;
    _visible[route] = _Visibility(name, Stopwatch()..start());
  }

  void _deactivate(Route<dynamic>? route) {
    if (route == null) return;
    if (identical(_topRoute, route)) _topRoute = null;
    final visibility = _visible.remove(route);
    if (visibility == null) return;
    visibility.stopwatch.stop();
    _visibleDuration?.record(
      visibility.stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
      attributes: {
        ObsiNavigationAttributes.navigatorName: navigatorName,
        ObsiNavigationAttributes.appScreenName: ?visibility.name,
      },
    );
  }

  bool _shouldInstrument(Route<dynamic> route) {
    try {
      return options.shouldInstrument?.call(route) ?? true;
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return true;
    }
  }

  String? _routeName(Route<dynamic>? route) {
    if (route == null) return null;
    try {
      final value =
          options.routeNameResolver?.call(route) ?? route.settings.name;
      final name = value?.trim();
      return name == null || name.isEmpty ? null : name;
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return null;
    }
  }

  Map<String, Object?> _customAttributes(
    String operation,
    Route<dynamic>? route,
    Route<dynamic>? previousRoute,
  ) {
    try {
      return options.attributes?.call(operation, route, previousRoute) ??
          const {};
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return const {};
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    try {
      options.onInstrumentationError?.call(error, stackTrace);
    } catch (_) {
      // Observer diagnostics must never break navigation.
    }
  }
}

final class _Visibility {
  const _Visibility(this.name, this.stopwatch);

  final String? name;
  final Stopwatch stopwatch;
}
