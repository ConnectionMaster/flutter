// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import 'base/io.dart' as io;
import 'base/logger.dart';
import 'base/platform.dart';
import 'convert.dart';
import 'persistent_tool_state.dart';
import 'resident_runner.dart';

/// An implementation of the devtools launcher that uses the server package.
///
/// This is implemented in `isolated/` to prevent the flutter_tool from needing
/// a devtools dependency in google3.
class DevtoolsServerLauncher extends DevtoolsLauncher {
  DevtoolsServerLauncher({
    @required Platform platform,
    @required ProcessManager processManager,
    @required String pubExecutable,
    @required Logger logger,
    @required PersistentToolState persistentToolState,
    @visibleForTesting io.HttpClient httpClient,
  })  : _processManager = processManager,
        _pubExecutable = pubExecutable,
        _logger = logger,
        _platform = platform,
        _persistentToolState = persistentToolState,
        _httpClient = httpClient ?? io.HttpClient();

  final ProcessManager _processManager;
  final String _pubExecutable;
  final Logger _logger;
  final Platform _platform;
  final PersistentToolState _persistentToolState;
  final io.HttpClient _httpClient;

  io.Process _devToolsProcess;

  static final RegExp _serveDevToolsPattern =
      RegExp(r'Serving DevTools at ((http|//)[a-zA-Z0-9:/=_\-\.\[\]]+)');
  static const String _pubHostedUrlKey = 'PUB_HOSTED_URL';

  @override
  Future<void> launch(Uri vmServiceUri) async {
    // Place this entire method in a try/catch that swallows exceptions because
    // this method is guaranteed not to return a Future that throws.
    try {
      bool offline = false;
      bool useOverrideUrl = false;
      try {
        Uri uri;
        if (_platform.environment.containsKey(_pubHostedUrlKey)) {
          useOverrideUrl = true;
          uri = Uri.parse(_platform.environment[_pubHostedUrlKey]);
        } else {
          uri = Uri.https('pub.dev', '');
        }
        final io.HttpClientRequest request = await _httpClient.headUrl(uri);
        final io.HttpClientResponse response = await request.close();
        await response.drain<void>();
        if (response.statusCode != io.HttpStatus.ok) {
          offline = true;
        }
      } on Exception {
        offline = true;
      } on ArgumentError {
        if (!useOverrideUrl) {
          rethrow;
        }
        // The user supplied a custom pub URL that was invalid, pretend to be offline
        // and inform them that the URL was invalid.
        offline = true;
        _logger.printError(
          'PUB_HOSTED_URL was set to an invalid URL: "${_platform.environment[_pubHostedUrlKey]}".'
        );
      }

      if (offline) {
        // TODO(kenz): we should launch an already activated version of DevTools
        // here, if available, once DevTools has offline support. DevTools does
        // not work without internet currently due to the failed request of a
        // couple scripts. See https://github.com/flutter/devtools/issues/2420.
        return;
      } else {
        bool devToolsActive = await _checkForActiveDevTools();
        await _activateDevTools(throttleUpdates: devToolsActive);
        if (!devToolsActive) {
          devToolsActive = await _checkForActiveDevTools();
        }
        if (!devToolsActive) {
          // We don't have devtools installed and installing it failed;
          // _activateDevTools will have reported the error already.
          return;
        }
      }

      _devToolsProcess = await _processManager.start(<String>[
        _pubExecutable,
        'global',
        'run',
        'devtools',
        '--no-launch-browser',
        if (vmServiceUri != null) '--vm-uri=$vmServiceUri',
      ]);
      final Completer<Uri> completer = Completer<Uri>();
      _devToolsProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) {
            final Match match = _serveDevToolsPattern.firstMatch(line);
            if (match != null) {
              // We are trying to pull "http://127.0.0.1:9101" from "Serving
              // DevTools at http://127.0.0.1:9101.". `match[1]` will return
              // "http://127.0.0.1:9101.", and we need to trim the trailing period
              // so that we don't throw an exception from `Uri.parse`.
              String uri = match[1];
              if (uri.endsWith('.')) {
                uri = uri.substring(0, uri.length - 1);
              }
              completer.complete(Uri.parse(uri));
            }
         });
      _devToolsProcess.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_logger.printError);
      devToolsUrl = await completer.future;
    } on Exception catch (e, st) {
      _logger.printError('Failed to launch DevTools: $e', stackTrace: st);
    }
  }

  static final RegExp _devToolsInstalledPattern = RegExp(r'^devtools ', multiLine: true);

  /// Check if the DevTools package is already active by running "pub global list".
  Future<bool> _checkForActiveDevTools() async {
    final io.ProcessResult _pubGlobalListProcess = await _processManager.run(
      <String>[ _pubExecutable, 'global', 'list' ],
    );
    return _pubGlobalListProcess.stdout.toString().contains(_devToolsInstalledPattern);
  }

  /// Helper method to activate the DevTools pub package.
  ///
  /// If throttleUpdates is true, then this is a no-op if it was run in
  /// the last twelve hours. It should be set to true if devtools is known
  /// to already be installed.
  ///
  /// Return value indicates if DevTools was installed or updated.
  Future<bool> _activateDevTools({@required bool throttleUpdates}) async {
    assert(throttleUpdates != null);
    const Duration _throttleDuration = Duration(hours: 12);
    if (throttleUpdates) {
      if (_persistentToolState.lastDevToolsActivationTime != null &&
          DateTime.now().difference(_persistentToolState.lastDevToolsActivationTime) < _throttleDuration) {
        _logger.printTrace('DevTools activation throttled until ${_persistentToolState.lastDevToolsActivationTime.add(_throttleDuration).toLocal()}.');
        return false; // Throttled.
      }
    }
    final Status status = _logger.startProgress('Activating Dart DevTools...');
    try {
      final io.ProcessResult _devToolsActivateProcess = await _processManager
          .run(<String>[
        _pubExecutable,
        'global',
        'activate',
        'devtools',
      ]);
      if (_devToolsActivateProcess.exitCode != 0) {
        _logger.printError(
          'Error running `pub global activate devtools`:\n'
          '${_devToolsActivateProcess.stderr}'
        );
        return false; // Failed to activate.
      }
      _persistentToolState.lastDevToolsActivation = DateTime.now();
      return true; // Activation succeeded!
    } on Exception catch (e, _) {
      _logger.printError('Error running `pub global activate devtools`: $e');
      return false;
    } finally {
      status.stop();
    }
  }

  @override
  Future<DevToolsServerAddress> serve() async {
    if (activeDevToolsServer == null) {
      await launch(null);
    }
    return activeDevToolsServer;
  }

  @override
  Future<void> close() async {
    if (devToolsUrl != null) {
      devToolsUrl = null;
    }
    if (_devToolsProcess != null) {
      _devToolsProcess.kill();
      await _devToolsProcess.exitCode;
    }
  }
}
