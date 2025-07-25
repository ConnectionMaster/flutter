// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:archive/archive.dart';
import 'package:file/memory.dart';
import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/android/android_sdk.dart';
import 'package:flutter_tools/src/android/android_studio.dart';
import 'package:flutter_tools/src/android/application_package.dart';
import 'package:flutter_tools/src/android/gradle.dart';
import 'package:flutter_tools/src/android/gradle_errors.dart';
import 'package:flutter_tools/src/android/gradle_utils.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/base/user_messages.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:test/fake.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_process_manager.dart';
import '../../src/fakes.dart';

const minimalV2EmbeddingManifest = r'''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:name="${applicationName}">
        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
    </application>
</manifest>
''';

void main() {
  group('gradle build', () {
    late BufferLogger logger;
    late FakeAnalytics fakeAnalytics;
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    setUp(() {
      processManager = FakeProcessManager.empty();
      logger = BufferLogger.test();
      fileSystem = MemoryFileSystem.test();
      Cache.flutterRoot = '';

      fakeAnalytics = getInitializedFakeAnalyticsInstance(
        fs: fileSystem,
        fakeFlutterVersion: FakeFlutterVersion(),
      );
    });

    testUsingContext(
      'Can immediately tool exit on recognized exit code/stderr',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
            exitCode: 1,
            stderr: '\nSome gradle message\n',
          ),
        );

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        var handlerCalled = false;
        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: <GradleHandledError>[
              GradleHandledError(
                test: (String line) {
                  return line.contains('Some gradle message');
                },
                handler: ({String? line, FlutterProject? project, bool? usesAndroidX}) async {
                  handlerCalled = true;
                  return GradleBuildStatus.exit;
                },
                eventLabel: 'random-event-label',
              ),
            ],
          );
        }, throwsToolExit(message: 'Gradle task assembleRelease failed with exit code 1'));

        expect(handlerCalled, isTrue);

        expect(
          fakeAnalytics.sentEvents,
          containsAll(<Event>[
            Event.flutterBuildInfo(
              label: 'app-not-using-android-x',
              buildType: 'gradle',
              settings: 'androidGradlePluginVersion: null',
            ),
            Event.flutterBuildInfo(
              label: 'gradle-random-event-label-failure',
              buildType: 'gradle',
              settings: 'androidGradlePluginVersion: null',
            ),
          ]),
        );

        expect(
          analyticsTimingEventExists(
            sentEvents: fakeAnalytics.sentEvents,
            workflow: 'build',
            variableName: 'gradle',
          ),
          true,
        );
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'Verbose mode for APKs includes Gradle stacktrace and sets debug log level',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: BufferLogger.test(verbose: true),
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '--full-stacktrace',
              '--info',
              '-Pverbose=true',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
          ),
        );

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        fileSystem
            .directory('build')
            .childDirectory('app')
            .childDirectory('outputs')
            .childDirectory('flutter-apk')
            .childFile('app-release.apk')
            .createSync(recursive: true);

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await builder.buildGradleApp(
          project: project,
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          target: 'lib/main.dart',
          isBuildingBundle: false,
          configOnly: false,
          localGradleErrors: <GradleHandledError>[],
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'Can retry build on recognized exit code/stderr',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );

        const fakeCmd = FakeCommand(
          command: <String>[
            'gradlew',
            '-q',
            '-Ptarget-platform=android-arm,android-arm64,android-x64',
            '-Ptarget=lib/main.dart',
            '-Pbase-application-name=android.app.Application',
            '-Pdart-obfuscation=false',
            '-Ptrack-widget-creation=false',
            '-Ptree-shake-icons=false',
            'assembleRelease',
          ],
          exitCode: 1,
          stderr: '\nSome gradle message\n',
        );

        processManager.addCommand(fakeCmd);

        const maxRetries = 2;
        for (var i = 0; i < maxRetries; i++) {
          processManager.addCommand(fakeCmd);
        }

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        var testFnCalled = 0;
        await expectLater(() async {
          await builder.buildGradleApp(
            maxRetries: maxRetries,
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: <GradleHandledError>[
              GradleHandledError(
                test: (String line) {
                  if (line.contains('Some gradle message')) {
                    testFnCalled++;
                    return true;
                  }
                  return false;
                },
                handler: ({String? line, FlutterProject? project, bool? usesAndroidX}) async {
                  return GradleBuildStatus.retry;
                },
                eventLabel: 'random-event-label',
              ),
            ],
          );
        }, throwsToolExit(message: 'Gradle task assembleRelease failed with exit code 1'));

        expect(logger.statusText, contains('Retrying Gradle Build: #1, wait time: 100ms'));
        expect(logger.statusText, contains('Retrying Gradle Build: #2, wait time: 200ms'));

        expect(testFnCalled, equals(maxRetries + 1));
        expect(fakeAnalytics.sentEvents, hasLength(9));
        expect(
          fakeAnalytics.sentEvents,
          contains(
            Event.flutterBuildInfo(
              label: 'gradle-random-event-label-failure',
              buildType: 'gradle',
              settings: 'androidGradlePluginVersion: null',
            ),
          ),
        );
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'Converts recognized ProcessExceptions into tools exits',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
            exitCode: 1,
            stderr: '\nSome gradle message\n',
          ),
        );

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        var handlerCalled = false;
        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: <GradleHandledError>[
              GradleHandledError(
                test: (String line) {
                  return line.contains('Some gradle message');
                },
                handler: ({String? line, FlutterProject? project, bool? usesAndroidX}) async {
                  handlerCalled = true;
                  return GradleBuildStatus.exit;
                },
                eventLabel: 'random-event-label',
              ),
            ],
          );
        }, throwsToolExit(message: 'Gradle task assembleRelease failed with exit code 1'));

        expect(handlerCalled, isTrue);

        expect(fakeAnalytics.sentEvents, hasLength(3));
        expect(
          fakeAnalytics.sentEvents,
          contains(
            Event.flutterBuildInfo(
              label: 'gradle-random-event-label-failure',
              buildType: 'gradle',
              settings: 'androidGradlePluginVersion: null',
            ),
          ),
        );
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'rethrows unrecognized ProcessException',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          FakeCommand(
            command: const <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
            exitCode: 1,
            onRun: (_) {
              throw const ProcessException('', <String>[], 'Unrecognized');
            },
          ),
        );

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: const <GradleHandledError>[],
          );
        }, throwsProcessException());
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'logs success event after a successful retry',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
            exitCode: 1,
            stderr: '\nnSome gradle message\n',
          ),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
          ),
        );

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        fileSystem
            .directory('build')
            .childDirectory('app')
            .childDirectory('outputs')
            .childDirectory('flutter-apk')
            .childFile('app-release.apk')
            .createSync(recursive: true);

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await builder.buildGradleApp(
          project: project,
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          target: 'lib/main.dart',
          isBuildingBundle: false,
          configOnly: false,
          localGradleErrors: <GradleHandledError>[
            GradleHandledError(
              test: (String line) {
                return line.contains('Some gradle message');
              },
              handler: ({String? line, FlutterProject? project, bool? usesAndroidX}) async {
                return GradleBuildStatus.retry;
              },
              eventLabel: 'random-event-label',
            ),
          ],
        );

        expect(
          fakeAnalytics.sentEvents,
          contains(
            Event.flutterBuildInfo(
              label: 'gradle-random-event-label-success',
              buildType: 'gradle',
              settings: 'androidGradlePluginVersion: null',
            ),
          ),
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'performs code size analysis and sends analytics',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(environment: <String, String>{'HOME': '/home'}),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Pcode-size-directory=foo',
              'assembleRelease',
            ],
          ),
        );

        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        final archive = Archive()
          ..addFile(ArchiveFile('AndroidManifest.xml', 100, List<int>.filled(100, 0)))
          ..addFile(ArchiveFile('META-INF/CERT.RSA', 10, List<int>.filled(10, 0)))
          ..addFile(ArchiveFile('META-INF/CERT.SF', 10, List<int>.filled(10, 0)))
          ..addFile(ArchiveFile('lib/arm64-v8a/libapp.so', 50, List<int>.filled(50, 0)))
          ..addFile(ArchiveFile('lib/arm64-v8a/libflutter.so', 50, List<int>.filled(50, 0)));

        fileSystem
            .directory('build')
            .childDirectory('app')
            .childDirectory('outputs')
            .childDirectory('flutter-apk')
            .childFile('app-release.apk')
          ..createSync(recursive: true)
          ..writeAsBytesSync(ZipEncoder().encode(archive)!);

        fileSystem.file('foo/snapshot.arm64-v8a.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(r'''
[
  {
    "l": "dart:_internal",
    "c": "SubListIterable",
    "n": "[Optimized] skip",
    "s": 2400
  }
]''');
        fileSystem.file('foo/trace.arm64-v8a.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await builder.buildGradleApp(
          project: project,
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              codeSizeDirectory: 'foo',
              packageConfigPath: '.dart_tool/package_config.json',
            ),
            targetArchs: <AndroidArch>[AndroidArch.arm64_v8a],
          ),
          target: 'lib/main.dart',
          isBuildingBundle: false,
          configOnly: false,
          localGradleErrors: <GradleHandledError>[],
        );

        expect(fakeAnalytics.sentEvents, contains(Event.codeSizeAnalysis(platform: 'apk')));
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    group('Appbundle debug symbol tests', () {
      final commonCommandPortion = <String>[
        'gradlew',
        '-q',
        '-Ptarget-platform=android-arm64,android-arm,android-x64',
        '-Ptarget=lib/main.dart',
        '-Pbase-application-name=android.app.Application',
        '-Pdart-obfuscation=false',
        '-Ptrack-widget-creation=false',
        '-Ptree-shake-icons=false',
      ];

      // Output from `<android_sdk_root>/tools/bin/apkanalyzer files list <aab>`
      // on an aab not containing debug symbols.
      const apkanalyzerOutputWithoutSymFiles = r'''
/
/META-INF/
/META-INF/MANIFEST.MF
/META-INF/ANDROIDD.RSA
/META-INF/ANDROIDD.SF
/base/
/base/root/
/base/root/kotlin/
/base/root/kotlin/reflect/
/base/root/kotlin/reflect/reflect.kotlin_builtins
/base/root/kotlin/ranges/
/base/root/kotlin/ranges/ranges.kotlin_builtins
/base/root/kotlin/kotlin.kotlin_builtins
/base/root/kotlin/internal/
/base/root/kotlin/internal/internal.kotlin_builtins
/base/root/kotlin/coroutines/
/base/root/kotlin/coroutines/coroutines.kotlin_builtins
/base/root/kotlin/collections/
/base/root/kotlin/collections/collections.kotlin_builtins
/base/root/kotlin/annotation/
/base/root/kotlin/annotation/annotation.kotlin_builtins
/base/root/kotlin-tooling-metadata.json
/base/root/META-INF/
/base/root/META-INF/version-control-info.textproto
/base/root/META-INF/services/
/base/root/META-INF/services/i0.b
/base/root/META-INF/services/i0.a
/base/root/META-INF/kotlinx_coroutines_core.version
/base/root/META-INF/kotlinx_coroutines_android.version
/base/root/META-INF/com/
/base/root/META-INF/com/android/
/base/root/META-INF/com/android/build/
/base/root/META-INF/com/android/build/gradle/
/base/root/META-INF/com/android/build/gradle/app-metadata.properties
/base/root/META-INF/androidx.window_window.version
/base/root/META-INF/androidx.window_window-java.version
/base/root/META-INF/androidx.window.extensions.core_core.version
/base/root/META-INF/androidx.viewpager_viewpager.version
/base/root/META-INF/androidx.versionedparcelable_versionedparcelable.version
/base/root/META-INF/androidx.tracing_tracing.version
/base/root/META-INF/androidx.startup_startup-runtime.version
/base/root/META-INF/androidx.savedstate_savedstate.version
/base/root/META-INF/androidx.profileinstaller_profileinstaller.version
/base/root/META-INF/androidx.loader_loader.version
/base/root/META-INF/androidx.lifecycle_lifecycle-viewmodel.version
/base/root/META-INF/androidx.lifecycle_lifecycle-viewmodel-savedstate.version
/base/root/META-INF/androidx.lifecycle_lifecycle-runtime.version
/base/root/META-INF/androidx.lifecycle_lifecycle-process.version
/base/root/META-INF/androidx.lifecycle_lifecycle-livedata.version
/base/root/META-INF/androidx.lifecycle_lifecycle-livedata-core.version
/base/root/META-INF/androidx.lifecycle_lifecycle-livedata-core-ktx.version
/base/root/META-INF/androidx.interpolator_interpolator.version
/base/root/META-INF/androidx.fragment_fragment.version
/base/root/META-INF/androidx.customview_customview.version
/base/root/META-INF/androidx.core_core.version
/base/root/META-INF/androidx.core_core-ktx.version
/base/root/META-INF/androidx.arch.core_core-runtime.version
/base/root/META-INF/androidx.annotation_annotation-experimental.version
/base/root/META-INF/androidx.activity_activity.version
/base/root/DebugProbesKt.bin
/base/resources.pb
/base/res/
/base/res/mipmap-xxxhdpi-v4/
/base/res/mipmap-xxxhdpi-v4/ic_launcher.png
/base/res/mipmap-xxhdpi-v4/
/base/res/mipmap-xxhdpi-v4/ic_launcher.png
/base/res/mipmap-xhdpi-v4/
/base/res/mipmap-xhdpi-v4/ic_launcher.png
/base/res/mipmap-mdpi-v4/
/base/res/mipmap-mdpi-v4/ic_launcher.png
/base/res/mipmap-hdpi-v4/
/base/res/mipmap-hdpi-v4/ic_launcher.png
/base/res/drawable-v21/
/base/res/drawable-v21/launch_background.xml
/base/native.pb
/base/manifest/
/base/manifest/AndroidManifest.xml
/base/lib/
/base/lib/x86_64/
/base/lib/x86_64/libflutter.so
/base/lib/x86_64/libapp.so
/base/lib/armeabi-v7a/
/base/lib/armeabi-v7a/libflutter.so
/base/lib/armeabi-v7a/libapp.so
/base/lib/arm64-v8a/
/base/lib/arm64-v8a/libflutter.so
/base/lib/arm64-v8a/libapp.so
/base/dex/
/base/dex/classes.dex
/base/assets/
/base/assets/flutter_assets/
/base/assets/flutter_assets/shaders/
/base/assets/flutter_assets/shaders/ink_sparkle.frag
/base/assets/flutter_assets/packages/
/base/assets/flutter_assets/packages/cupertino_icons/
/base/assets/flutter_assets/packages/cupertino_icons/assets/
/base/assets/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf
/base/assets/flutter_assets/fonts/
/base/assets/flutter_assets/fonts/MaterialIcons-Regular.otf
/base/assets/flutter_assets/NativeAssetsManifest.json
/base/assets/flutter_assets/NOTICES.Z
/base/assets/flutter_assets/FontManifest.json
/base/assets/flutter_assets/AssetManifest.bin
/base/assets.pb
/BundleConfig.pb
/BUNDLE-METADATA/
/BUNDLE-METADATA/com.android.tools.build.profiles/
/BUNDLE-METADATA/com.android.tools.build.profiles/baseline.profm
/BUNDLE-METADATA/com.android.tools.build.profiles/baseline.prof
/BUNDLE-METADATA/com.android.tools.build.obfuscation/
/BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map
/BUNDLE-METADATA/com.android.tools.build.libraries/
/BUNDLE-METADATA/com.android.tools.build.libraries/dependencies.pb
/BUNDLE-METADATA/com.android.tools.build.gradle/
/BUNDLE-METADATA/com.android.tools.build.gradle/app-metadata.properties
''';

      // Output from `<android_sdk_root>/tools/bin/apkanalyzer files list <aab>`
      // on an aab containing debug symbols.
      const String apkanalyzerOutputWithSymFiles =
          apkanalyzerOutputWithoutSymFiles +
          r'''
/BUNDLE-METADATA/com.android.tools.build.debugsymbols/
/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/
/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.sym
''';

      // Output from `<android_sdk_root>/tools/bin/apkanalyzer files list <aab>`
      // on an aab containing the debug info and symbol tables.
      const String apkanalyzerOutputWithDebugInfoAndSymFiles =
          apkanalyzerOutputWithoutSymFiles +
          r'''
/BUNDLE-METADATA/com.android.tools.build.debugsymbols/
/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/
/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.dbg
''';

      void createSharedGradleFiles() {
        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');
      }

      File createAabFile(BuildMode buildMode) {
        final File aabFile = fileSystem
            .directory('/build')
            .childDirectory('app')
            .childDirectory('outputs')
            .childDirectory('bundle')
            .childDirectory('$buildMode')
            .childFile('app-$buildMode.aab');

        aabFile.createSync(recursive: true);

        return aabFile;
      }

      testUsingContext(
        'build succeeds when debug symbols present for at least one architecture',
        () async {
          final builder = AndroidGradleBuilder(
            java: FakeJava(),
            logger: logger,
            processManager: processManager,
            fileSystem: fileSystem,
            artifacts: Artifacts.test(),
            analytics: fakeAnalytics,
            gradleUtils: FakeGradleUtils(),
            platform: FakePlatform(environment: <String, String>{'HOME': '/home'}),
            androidStudio: FakeAndroidStudio(),
          );
          processManager.addCommand(
            FakeCommand(command: List<String>.of(commonCommandPortion)..add('bundleRelease')),
          );

          createSharedGradleFiles();
          final File aabFile = createAabFile(BuildMode.release);
          final AndroidSdk sdk = AndroidSdk.locateAndroidSdk()!;

          processManager.addCommand(
            FakeCommand(
              command: <String>[
                sdk.getCmdlineToolsPath(apkAnalyzerBinaryName)!,
                'files',
                'list',
                aabFile.path,
              ],
              stdout: apkanalyzerOutputWithSymFiles,
            ),
          );

          final FlutterProject project = FlutterProject.fromDirectoryTest(
            fileSystem.currentDirectory,
          );
          project.android.appManifestFile
            ..createSync(recursive: true)
            ..writeAsStringSync(minimalV2EmbeddingManifest);

          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
              targetArchs: <AndroidArch>[
                AndroidArch.arm64_v8a,
                AndroidArch.armeabi_v7a,
                AndroidArch.x86_64,
              ],
            ),
            target: 'lib/main.dart',
            isBuildingBundle: true,
            configOnly: false,
            localGradleErrors: <GradleHandledError>[],
          );
        },
        overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
      );

      testUsingContext(
        'build succeeds when debug info and symbol tables present for at least one architecture',
        () async {
          final builder = AndroidGradleBuilder(
            java: FakeJava(),
            logger: logger,
            processManager: processManager,
            fileSystem: fileSystem,
            artifacts: Artifacts.test(),
            analytics: fakeAnalytics,
            gradleUtils: FakeGradleUtils(),
            platform: FakePlatform(environment: <String, String>{'HOME': '/home'}),
            androidStudio: FakeAndroidStudio(),
          );
          processManager.addCommand(
            FakeCommand(command: List<String>.of(commonCommandPortion)..add('bundleRelease')),
          );

          createSharedGradleFiles();
          final File aabFile = createAabFile(BuildMode.release);
          final AndroidSdk sdk = AndroidSdk.locateAndroidSdk()!;

          processManager.addCommand(
            FakeCommand(
              command: <String>[
                sdk.getCmdlineToolsPath(apkAnalyzerBinaryName)!,
                'files',
                'list',
                aabFile.path,
              ],
              stdout: apkanalyzerOutputWithDebugInfoAndSymFiles,
            ),
          );

          final FlutterProject project = FlutterProject.fromDirectoryTest(
            fileSystem.currentDirectory,
          );
          project.android.appManifestFile
            ..createSync(recursive: true)
            ..writeAsStringSync(minimalV2EmbeddingManifest);

          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
              targetArchs: <AndroidArch>[
                AndroidArch.arm64_v8a,
                AndroidArch.armeabi_v7a,
                AndroidArch.x86_64,
              ],
            ),
            target: 'lib/main.dart',
            isBuildingBundle: true,
            configOnly: false,
            localGradleErrors: <GradleHandledError>[],
          );
        },
        overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
      );

      testUsingContext(
        'building a debug aab does not invoke apkanalyzer',
        () async {
          final builder = AndroidGradleBuilder(
            java: FakeJava(),
            logger: logger,
            processManager: processManager,
            fileSystem: fileSystem,
            artifacts: Artifacts.test(),
            analytics: fakeAnalytics,
            gradleUtils: FakeGradleUtils(),
            platform: FakePlatform(environment: <String, String>{'HOME': '/home'}),
            androidStudio: FakeAndroidStudio(),
          );
          processManager.addCommand(
            FakeCommand(command: List<String>.of(commonCommandPortion)..add('bundleDebug')),
          );

          createSharedGradleFiles();
          createAabFile(BuildMode.debug);

          final FlutterProject project = FlutterProject.fromDirectoryTest(
            fileSystem.currentDirectory,
          );
          project.android.appManifestFile
            ..createSync(recursive: true)
            ..writeAsStringSync(minimalV2EmbeddingManifest);

          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.debug,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
              targetArchs: <AndroidArch>[
                AndroidArch.arm64_v8a,
                AndroidArch.armeabi_v7a,
                AndroidArch.x86_64,
              ],
            ),
            target: 'lib/main.dart',
            isBuildingBundle: true,
            configOnly: false,
            localGradleErrors: <GradleHandledError>[],
          );
        },
        overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
      );

      testUsingContext(
        'throws tool exit for missing debug symbols when building release app bundle',
        () async {
          final builder = AndroidGradleBuilder(
            java: FakeJava(),
            logger: logger,
            processManager: processManager,
            fileSystem: fileSystem,
            artifacts: Artifacts.test(),
            analytics: fakeAnalytics,
            gradleUtils: FakeGradleUtils(),
            platform: FakePlatform(environment: <String, String>{'HOME': '/home'}),
            androidStudio: FakeAndroidStudio(),
          );
          processManager.addCommand(
            FakeCommand(command: List<String>.of(commonCommandPortion)..add('bundleRelease')),
          );

          createSharedGradleFiles();
          final File aabFile = createAabFile(BuildMode.release);

          final AndroidSdk sdk = AndroidSdk.locateAndroidSdk()!;

          processManager.addCommand(
            FakeCommand(
              command: <String>[
                sdk.getCmdlineToolsPath(apkAnalyzerBinaryName)!,
                'files',
                'list',
                aabFile.path,
              ],
              stdout: apkanalyzerOutputWithoutSymFiles,
            ),
          );

          final FlutterProject project = FlutterProject.fromDirectoryTest(
            fileSystem.currentDirectory,
          );
          project.android.appManifestFile
            ..createSync(recursive: true)
            ..writeAsStringSync(minimalV2EmbeddingManifest);

          await expectLater(
            () async => builder.buildGradleApp(
              project: project,
              androidBuildInfo: const AndroidBuildInfo(
                BuildInfo(
                  BuildMode.release,
                  null,
                  treeShakeIcons: false,
                  packageConfigPath: '.dart_tool/package_config.json',
                ),
                targetArchs: <AndroidArch>[
                  AndroidArch.arm64_v8a,
                  AndroidArch.armeabi_v7a,
                  AndroidArch.x86_64,
                ],
              ),
              target: 'lib/main.dart',
              isBuildingBundle: true,
              configOnly: false,
              localGradleErrors: <GradleHandledError>[],
            ),
            throwsToolExit(message: failedToStripDebugSymbolsErrorMessage),
          );
        },
        overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
      );

      testUsingContext(
        'build aab in release mode fails when apkanalyzer exit code is non zero',
        () async {
          final builder = AndroidGradleBuilder(
            java: FakeJava(),
            logger: logger,
            processManager: processManager,
            fileSystem: fileSystem,
            artifacts: Artifacts.test(),
            analytics: fakeAnalytics,
            gradleUtils: FakeGradleUtils(),
            platform: FakePlatform(environment: <String, String>{'HOME': '/home'}),
            androidStudio: FakeAndroidStudio(),
          );
          processManager.addCommand(
            FakeCommand(command: List<String>.of(commonCommandPortion)..add('bundleRelease')),
          );

          createSharedGradleFiles();
          final File aabFile = createAabFile(BuildMode.release);

          final AndroidSdk sdk = AndroidSdk.locateAndroidSdk()!;

          processManager.addCommand(
            FakeCommand(
              command: <String>[
                sdk.getCmdlineToolsPath(apkAnalyzerBinaryName)!,
                'files',
                'list',
                aabFile.path,
              ],
              exitCode: 1,
              stdout: apkanalyzerOutputWithSymFiles,
            ),
          );

          final FlutterProject project = FlutterProject.fromDirectoryTest(
            fileSystem.currentDirectory,
          );
          project.android.appManifestFile
            ..createSync(recursive: true)
            ..writeAsStringSync(minimalV2EmbeddingManifest);

          await expectLater(
            () async => builder.buildGradleApp(
              project: project,
              androidBuildInfo: const AndroidBuildInfo(
                BuildInfo(
                  BuildMode.release,
                  null,
                  treeShakeIcons: false,
                  packageConfigPath: '.dart_tool/package_config.json',
                ),
                targetArchs: <AndroidArch>[
                  AndroidArch.arm64_v8a,
                  AndroidArch.armeabi_v7a,
                  AndroidArch.x86_64,
                ],
              ),
              target: 'lib/main.dart',
              isBuildingBundle: true,
              configOnly: false,
              localGradleErrors: <GradleHandledError>[],
            ),
            throwsToolExit(message: failedToStripDebugSymbolsErrorMessage),
          );
        },
        overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
      );
    });

    testUsingContext(
      'indicates that an APK has been built successfully',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
          ),
        );
        fileSystem.directory('android').childFile('build.gradle').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);

        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');

        fileSystem
            .directory('build')
            .childDirectory('app')
            .childDirectory('outputs')
            .childDirectory('flutter-apk')
            .childFile('app-release.apk')
            .createSync(recursive: true);

        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await builder.buildGradleApp(
          project: project,
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          target: 'lib/main.dart',
          isBuildingBundle: false,
          configOnly: false,
          localGradleErrors: const <GradleHandledError>[],
        );

        expect(
          logger.statusText,
          contains('Built build/app/outputs/flutter-apk/app-release.apk (0.0MB)'),
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext('Uses namespace attribute if manifest lacks a package attribute', () async {
      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.currentDirectory);
      final AndroidSdk sdk = FakeAndroidSdk();

      fileSystem
          .directory(project.android.hostAppGradleRoot)
          .childFile('build.gradle')
          .createSync(recursive: true);

      fileSystem
          .directory(project.android.hostAppGradleRoot)
          .childDirectory('app')
          .childFile('build.gradle')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
apply from: irrelevant/flutter.gradle

android {
    namespace 'com.example.foo'
}
''');

      fileSystem
          .directory(project.android.hostAppGradleRoot)
          .childDirectory('app')
          .childDirectory('src')
          .childDirectory('main')
          .childFile('AndroidManifest.xml')
        ..createSync(recursive: true)
        ..writeAsStringSync(r'''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="namespacetest"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
''');

      final AndroidApk? androidApk = await AndroidApk.fromAndroidProject(
        project.android,
        androidSdk: sdk,
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        processUtils: ProcessUtils(processManager: processManager, logger: logger),
        userMessages: UserMessages(),
        buildInfo: const BuildInfo(
          BuildMode.debug,
          null,
          treeShakeIcons: false,
          packageConfigPath: '.dart_tool/package_config.json',
        ),
      );

      expect(androidApk?.id, 'com.example.foo');
    });

    testUsingContext(
      'can call custom gradle task getBuildOptions and parse the result',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>['gradlew', '-q', 'printBuildVariants'],
            stdout: '''
BuildVariant: freeDebug
BuildVariant: paidDebug
BuildVariant: freeRelease
BuildVariant: paidRelease
BuildVariant: freeProfile
BuildVariant: paidProfile
        ''',
          ),
        );
        final List<String> actual = await builder.getBuildVariants(
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        );
        expect(actual, <String>[
          'freeDebug',
          'paidDebug',
          'freeRelease',
          'paidRelease',
          'freeProfile',
          'paidProfile',
        ]);

        expect(
          analyticsTimingEventExists(
            sentEvents: fakeAnalytics.sentEvents,
            workflow: 'print',
            variableName: 'android build variants',
          ),
          true,
        );
      },
      overrides: <Type, Generator>{
        AndroidStudio: () => FakeAndroidStudio(),
        Analytics: () => fakeAnalytics,
      },
    );

    testUsingContext(
      'getBuildOptions returns empty list if gradle returns error',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>['gradlew', '-q', 'printBuildVariants'],
            stderr: '''
Gradle Crashed
        ''',
            exitCode: 1,
          ),
        );
        final List<String> actual = await builder.getBuildVariants(
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        );
        expect(actual, const <String>[]);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'can call custom gradle task outputFreeDebugAppLinkSettings and parse the result',
      () async {
        final String expectedOutputPath;
        expectedOutputPath = fileSystem.path.join(
          '/build/deeplink_data',
          'app-link-settings-freeDebug.json',
        );
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-PoutputPath=$expectedOutputPath',
              'outputFreeDebugAppLinkSettings',
            ],
          ),
        );
        await builder.outputsAppLinkSettings(
          'freeDebug',
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        );

        expect(
          analyticsTimingEventExists(
            sentEvents: fakeAnalytics.sentEvents,
            workflow: 'outputs',
            variableName: 'app link settings',
          ),
          true,
        );
      },
      overrides: <Type, Generator>{
        AndroidStudio: () => FakeAndroidStudio(),
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Analytics: () => fakeAnalytics,
      },
    );

    testUsingContext(
      "doesn't indicate how to consume an AAR when printHowToConsumeAar is false",
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
              '-Pflutter-root=/',
              '-Poutput-dir=build/',
              '-Pis-plugin=false',
              '-PbuildNumber=1.0',
              '-q',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              'assembleAarRelease',
            ],
          ),
        );

        final File manifestFile = fileSystem.file('pubspec.yaml');
        manifestFile.createSync(recursive: true);
        manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

        fileSystem.file('.android/gradlew').createSync(recursive: true);
        fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
        fileSystem.file('.android/build.gradle').createSync(recursive: true);
        fileSystem.directory('build/outputs/repo').createSync(recursive: true);

        await builder.buildGradleAar(
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          outputDirectory: fileSystem.directory('build/'),
          target: '',
          buildNumber: '1.0',
        );

        expect(logger.statusText, contains('Built build/outputs/repo'));
        expect(logger.statusText.contains('Consuming the Module'), isFalse);
        expect(processManager, hasNoRemainingExpectations);

        expect(
          analyticsTimingEventExists(
            sentEvents: fakeAnalytics.sentEvents,
            workflow: 'build',
            variableName: 'gradle-aar',
          ),
          true,
        );
      },
      overrides: <Type, Generator>{
        AndroidStudio: () => FakeAndroidStudio(),
        Analytics: () => fakeAnalytics,
      },
    );

    // Regression test for https://github.com/flutter/flutter/issues/162649.
    testUsingContext('buildAar generates tooling for each sub-build for AARs', () async {
      addTearDown(() {
        printOnFailure(logger.statusText);
        printOnFailure(logger.errorText);
      });
      final builder = AndroidGradleBuilder(
        java: FakeJava(),
        logger: logger,
        processManager: processManager,
        fileSystem: fileSystem,
        artifacts: Artifacts.test(),
        analytics: fakeAnalytics,
        gradleUtils: FakeGradleUtils(),
        platform: FakePlatform(),
        androidStudio: FakeAndroidStudio(),
      );
      processManager.addCommands(const <FakeCommand>[
        FakeCommand(
          command: <String>[
            'gradlew',
            '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
            '-Pflutter-root=/',
            '-Poutput-dir=/build/host',
            '-Pis-plugin=false',
            '-PbuildNumber=1.0',
            '-q',
            '-Pdart-obfuscation=false',
            '-Ptrack-widget-creation=false',
            '-Ptree-shake-icons=false',
            '-Ptarget-platform=android-arm,android-arm64,android-x64',
            'assembleAarDebug',
          ],
        ),
        FakeCommand(
          command: <String>[
            'gradlew',
            '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
            '-Pflutter-root=/',
            '-Poutput-dir=/build/host',
            '-Pis-plugin=false',
            '-PbuildNumber=1.0',
            '-q',
            '-Pdart-obfuscation=false',
            '-Ptrack-widget-creation=false',
            '-Ptree-shake-icons=false',
            '-Ptarget-platform=android-arm,android-arm64,android-x64',
            'assembleAarProfile',
          ],
        ),
        FakeCommand(
          command: <String>[
            'gradlew',
            '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
            '-Pflutter-root=/',
            '-Poutput-dir=/build/host',
            '-Pis-plugin=false',
            '-PbuildNumber=1.0',
            '-q',
            '-Pdart-obfuscation=false',
            '-Ptrack-widget-creation=false',
            '-Ptree-shake-icons=false',
            '-Ptarget-platform=android-arm,android-arm64,android-x64',
            'assembleAarRelease',
          ],
        ),
      ]);

      final File manifestFile = fileSystem.file('pubspec.yaml');
      manifestFile.createSync(recursive: true);
      manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

      fileSystem.file('.android/gradlew').createSync(recursive: true);
      fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
      fileSystem.file('.android/build.gradle').createSync(recursive: true);
      fileSystem.directory('build/host/outputs/repo').createSync(recursive: true);

      final generateToolingCalls = <(FlutterProject, bool)>[];
      await builder.buildAar(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        androidBuildInfo: const <AndroidBuildInfo>{
          AndroidBuildInfo(
            BuildInfo(
              BuildMode.debug,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          AndroidBuildInfo(
            BuildInfo(
              BuildMode.profile,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
        },
        target: '',
        buildNumber: '1.0',
        generateTooling: (FlutterProject project, {required bool releaseMode}) async {
          generateToolingCalls.add((project, releaseMode));
        },
      );
      expect(processManager, hasNoRemainingExpectations);

      // Ideally, this should be checked before each invocation to the process,
      // but instead we'll assume it was invoked in the same order as the calls
      // to gradle to keep the scope of this test light.
      expect(generateToolingCalls, hasLength(3));
      expect(
        generateToolingCalls.map(((FlutterProject, bool) call) {
          return call.$2;
        }),
        <bool>[false, false, true],
        reason: 'generateTooling should omit debug metadata for release builds',
      );
    });

    testUsingContext(
      'Verbose mode for AARs includes Gradle stacktrace and sets debug log level',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: BufferLogger.test(verbose: true),
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
              '-Pflutter-root=/',
              '-Poutput-dir=build/',
              '-Pis-plugin=false',
              '-PbuildNumber=1.0',
              '--full-stacktrace',
              '--info',
              '-Pverbose=true',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              'assembleAarRelease',
            ],
          ),
        );

        final File manifestFile = fileSystem.file('pubspec.yaml');
        manifestFile.createSync(recursive: true);
        manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

        fileSystem.file('.android/gradlew').createSync(recursive: true);
        fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
        fileSystem.file('.android/build.gradle').createSync(recursive: true);
        fileSystem.directory('build/outputs/repo').createSync(recursive: true);

        await builder.buildGradleAar(
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          outputDirectory: fileSystem.directory('build/'),
          target: '',
          buildNumber: '1.0',
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'gradle exit code and stderr is forwarded to tool exit',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
              '-Pflutter-root=/',
              '-Poutput-dir=build/',
              '-Pis-plugin=false',
              '-PbuildNumber=1.0',
              '-q',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              'assembleAarRelease',
            ],
            exitCode: 108,
            stderr: 'Gradle task assembleAarRelease failed with exit code 108.',
          ),
        );

        final File manifestFile = fileSystem.file('pubspec.yaml');
        manifestFile.createSync(recursive: true);
        manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

        fileSystem.file('.android/gradlew').createSync(recursive: true);
        fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
        fileSystem.file('.android/build.gradle').createSync(recursive: true);
        fileSystem.directory('build/outputs/repo').createSync(recursive: true);

        await expectLater(
          () async => builder.buildGradleAar(
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
            outputDirectory: fileSystem.directory('build/'),
            target: '',
            buildNumber: '1.0',
          ),
          throwsToolExit(
            exitCode: 108,
            message: 'Gradle task assembleAarRelease failed with exit code 108.',
          ),
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'build apk uses selected local engine with arm32 ABI',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.testLocalEngine(
            localEngine: 'out/android_arm',
            localEngineHost: 'out/host_release',
          ),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Plocal-engine-repo=/.tmp_rand0/flutter_tool_local_engine_repo.rand0',
              '-Plocal-engine-build-mode=release',
              '-Plocal-engine-out=out/android_arm',
              '-Plocal-engine-host-out=out/host_release',
              '-Ptarget-platform=android-arm',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
          ),
        );

        fileSystem.file('out/android_arm/flutter_embedding_release.pom')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <version>1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b</version>
  <dependencies>
  </dependencies>
</project>
''');
        fileSystem.file('out/android_arm/armeabi_v7a_release.pom').createSync(recursive: true);
        fileSystem.file('out/android_arm/armeabi_v7a_release.jar').createSync(recursive: true);
        fileSystem
            .file('out/android_arm/armeabi_v7a_release.maven-metadata.xml')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm/flutter_embedding_release.jar')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm/flutter_embedding_release.pom')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm/flutter_embedding_release.maven-metadata.xml')
            .createSync(recursive: true);

        fileSystem.file('android/gradlew').createSync(recursive: true);
        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);
        fileSystem.file('android/build.gradle').createSync(recursive: true);
        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');
        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: const <GradleHandledError>[],
          );
        }, throwsToolExit());
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'build apk uses selected local engine with arm64 ABI',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.testLocalEngine(
            localEngine: 'out/android_arm64',
            localEngineHost: 'out/host_release',
          ),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Plocal-engine-repo=/.tmp_rand0/flutter_tool_local_engine_repo.rand0',
              '-Plocal-engine-build-mode=release',
              '-Plocal-engine-out=out/android_arm64',
              '-Plocal-engine-host-out=out/host_release',
              '-Ptarget-platform=android-arm64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
          ),
        );

        fileSystem.file('out/android_arm64/flutter_embedding_release.pom')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <version>1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b</version>
  <dependencies>
  </dependencies>
</project>
''');
        fileSystem.file('out/android_arm64/arm64_v8a_release.pom').createSync(recursive: true);
        fileSystem.file('out/android_arm64/arm64_v8a_release.jar').createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/arm64_v8a_release.maven-metadata.xml')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/flutter_embedding_release.jar')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/flutter_embedding_release.pom')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/flutter_embedding_release.maven-metadata.xml')
            .createSync(recursive: true);

        fileSystem.file('android/gradlew').createSync(recursive: true);
        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);
        fileSystem.file('android/build.gradle').createSync(recursive: true);
        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');
        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: const <GradleHandledError>[],
          );
        }, throwsToolExit());
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'build apk uses selected local engine with x64 ABI',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.testLocalEngine(
            localEngine: 'out/android_x64',
            localEngineHost: 'out/host_release',
          ),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Plocal-engine-repo=/.tmp_rand0/flutter_tool_local_engine_repo.rand0',
              '-Plocal-engine-build-mode=release',
              '-Plocal-engine-out=out/android_x64',
              '-Plocal-engine-host-out=out/host_release',
              '-Ptarget-platform=android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
            exitCode: 1,
          ),
        );

        fileSystem.file('out/android_x64/flutter_embedding_release.pom')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <version>1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b</version>
  <dependencies>
  </dependencies>
</project>
''');
        fileSystem.file('out/android_x64/x86_64_release.pom').createSync(recursive: true);
        fileSystem.file('out/android_x64/x86_64_release.jar').createSync(recursive: true);
        fileSystem
            .file('out/android_x64/x86_64_release.maven-metadata.xml')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_x64/flutter_embedding_release.jar')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_x64/flutter_embedding_release.pom')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_x64/flutter_embedding_release.maven-metadata.xml')
            .createSync(recursive: true);

        fileSystem.file('android/gradlew').createSync(recursive: true);
        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);
        fileSystem.file('android/build.gradle').createSync(recursive: true);
        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');
        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: const <GradleHandledError>[],
          );
        }, throwsToolExit());
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'honors --no-android-gradle-daemon setting',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '--no-daemon',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              'assembleRelease',
            ],
          ),
        );
        fileSystem.file('android/gradlew').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);
        fileSystem.file('android/build.gradle').createSync(recursive: true);
        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');
        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                androidGradleDaemon: false,
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: const <GradleHandledError>[],
          );
        }, throwsToolExit());
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'honors --android-project-cache-dir setting',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.test(),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-q',
              '-Ptarget-platform=android-arm,android-arm64,android-x64',
              '-Ptarget=lib/main.dart',
              '-Pbase-application-name=android.app.Application',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '--project-cache-dir=/made/up/dir',
              'assembleRelease',
            ],
          ),
        );
        fileSystem.file('android/gradlew').createSync(recursive: true);

        fileSystem.directory('android').childFile('gradle.properties').createSync(recursive: true);
        fileSystem.file('android/build.gradle').createSync(recursive: true);
        fileSystem.directory('android').childDirectory('app').childFile('build.gradle')
          ..createSync(recursive: true)
          ..writeAsStringSync('apply from: irrelevant/flutter.gradle');
        final FlutterProject project = FlutterProject.fromDirectoryTest(
          fileSystem.currentDirectory,
        );
        project.android.appManifestFile
          ..createSync(recursive: true)
          ..writeAsStringSync(minimalV2EmbeddingManifest);

        await expectLater(() async {
          await builder.buildGradleApp(
            project: project,
            androidBuildInfo: const AndroidBuildInfo(
              BuildInfo(
                BuildMode.release,
                null,
                treeShakeIcons: false,
                androidGradleProjectCacheDir: '/made/up/dir',
                packageConfigPath: '.dart_tool/package_config.json',
              ),
            ),
            target: 'lib/main.dart',
            isBuildingBundle: false,
            configOnly: false,
            localGradleErrors: const <GradleHandledError>[],
          );
        }, throwsToolExit());
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'build aar uses selected local engine with arm32 ABI',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.testLocalEngine(
            localEngine: 'out/android_arm',
            localEngineHost: 'out/host_release',
          ),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
              '-Pflutter-root=/',
              '-Poutput-dir=build/',
              '-Pis-plugin=false',
              '-PbuildNumber=2.0',
              '-q',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Plocal-engine-repo=/.tmp_rand0/flutter_tool_local_engine_repo.rand0',
              '-Plocal-engine-build-mode=release',
              '-Plocal-engine-out=out/android_arm',
              '-Plocal-engine-host-out=out/host_release',
              '-Ptarget-platform=android-arm',
              'assembleAarRelease',
            ],
          ),
        );

        fileSystem.file('out/android_arm/flutter_embedding_release.pom')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <version>1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b</version>
  <dependencies>
  </dependencies>
</project>
''');
        fileSystem.file('out/android_arm/armeabi_v7a_release.pom').createSync(recursive: true);
        fileSystem.file('out/android_arm/armeabi_v7a_release.jar').createSync(recursive: true);
        fileSystem
            .file('out/android_arm/armeabi_v7a_release.maven-metadata.xml')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm/flutter_embedding_release.jar')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm/flutter_embedding_release.pom')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm/flutter_embedding_release.maven-metadata.xml')
            .createSync(recursive: true);

        final File manifestFile = fileSystem.file('pubspec.yaml');
        manifestFile.createSync(recursive: true);
        manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

        fileSystem.directory('.android/gradle').createSync(recursive: true);
        fileSystem.directory('.android/gradle/wrapper').createSync(recursive: true);
        fileSystem.file('.android/gradlew').createSync(recursive: true);
        fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
        fileSystem.file('.android/build.gradle').createSync(recursive: true);

        fileSystem.directory('build/outputs/repo').createSync(recursive: true);

        await builder.buildGradleAar(
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          outputDirectory: fileSystem.directory('build/'),
          target: '',
          buildNumber: '2.0',
        );

        expect(
          fileSystem.link(
            'build/outputs/repo/io/flutter/flutter_embedding_release/'
            '1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b/'
            'flutter_embedding_release-1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b.pom',
          ),
          exists,
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'build aar uses selected local engine with x64 ABI',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.testLocalEngine(
            localEngine: 'out/android_arm64',
            localEngineHost: 'out/host_release',
          ),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
              '-Pflutter-root=/',
              '-Poutput-dir=build/',
              '-Pis-plugin=false',
              '-PbuildNumber=2.0',
              '-q',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Plocal-engine-repo=/.tmp_rand0/flutter_tool_local_engine_repo.rand0',
              '-Plocal-engine-build-mode=release',
              '-Plocal-engine-out=out/android_arm64',
              '-Plocal-engine-host-out=out/host_release',
              '-Ptarget-platform=android-arm64',
              'assembleAarRelease',
            ],
          ),
        );

        fileSystem.file('out/android_arm64/flutter_embedding_release.pom')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <version>1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b</version>
  <dependencies>
  </dependencies>
</project>
''');
        fileSystem.file('out/android_arm64/arm64_v8a_release.pom').createSync(recursive: true);
        fileSystem.file('out/android_arm64/arm64_v8a_release.jar').createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/arm64_v8a_release.maven-metadata.xml')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/flutter_embedding_release.jar')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/flutter_embedding_release.pom')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_arm64/flutter_embedding_release.maven-metadata.xml')
            .createSync(recursive: true);

        final File manifestFile = fileSystem.file('pubspec.yaml');
        manifestFile.createSync(recursive: true);
        manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

        fileSystem.directory('.android/gradle').createSync(recursive: true);
        fileSystem.directory('.android/gradle/wrapper').createSync(recursive: true);
        fileSystem.file('.android/gradlew').createSync(recursive: true);
        fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
        fileSystem.file('.android/build.gradle').createSync(recursive: true);
        fileSystem.directory('build/outputs/repo').createSync(recursive: true);

        await builder.buildGradleAar(
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          outputDirectory: fileSystem.directory('build/'),
          target: '',
          buildNumber: '2.0',
        );

        expect(
          fileSystem.link(
            'build/outputs/repo/io/flutter/flutter_embedding_release/'
            '1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b/'
            'flutter_embedding_release-1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b.pom',
          ),
          exists,
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );

    testUsingContext(
      'build aar uses selected local engine on x64 ABI',
      () async {
        final builder = AndroidGradleBuilder(
          java: FakeJava(),
          logger: logger,
          processManager: processManager,
          fileSystem: fileSystem,
          artifacts: Artifacts.testLocalEngine(
            localEngine: 'out/android_x64',
            localEngineHost: 'out/host_release',
          ),
          analytics: fakeAnalytics,
          gradleUtils: FakeGradleUtils(),
          platform: FakePlatform(),
          androidStudio: FakeAndroidStudio(),
        );
        processManager.addCommand(
          const FakeCommand(
            command: <String>[
              'gradlew',
              '-I=/packages/flutter_tools/gradle/aar_init_script.gradle',
              '-Pflutter-root=/',
              '-Poutput-dir=build/',
              '-Pis-plugin=false',
              '-PbuildNumber=2.0',
              '-q',
              '-Pdart-obfuscation=false',
              '-Ptrack-widget-creation=false',
              '-Ptree-shake-icons=false',
              '-Plocal-engine-repo=/.tmp_rand0/flutter_tool_local_engine_repo.rand0',
              '-Plocal-engine-build-mode=release',
              '-Plocal-engine-out=out/android_x64',
              '-Plocal-engine-host-out=out/host_release',
              '-Ptarget-platform=android-x64',
              'assembleAarRelease',
            ],
          ),
        );

        fileSystem.file('out/android_x64/flutter_embedding_release.pom')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <version>1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b</version>
  <dependencies>
  </dependencies>
</project>
''');
        fileSystem.file('out/android_x64/x86_64_release.pom').createSync(recursive: true);
        fileSystem.file('out/android_x64/x86_64_release.jar').createSync(recursive: true);
        fileSystem
            .file('out/android_x64/x86_64_release.maven-metadata.xml')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_x64/flutter_embedding_release.jar')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_x64/flutter_embedding_release.pom')
            .createSync(recursive: true);
        fileSystem
            .file('out/android_x64/flutter_embedding_release.maven-metadata.xml')
            .createSync(recursive: true);

        final File manifestFile = fileSystem.file('pubspec.yaml');
        manifestFile.createSync(recursive: true);
        manifestFile.writeAsStringSync('''
        flutter:
          module:
            androidPackage: com.example.test
        ''');

        fileSystem.directory('.android/gradle').createSync(recursive: true);
        fileSystem.directory('.android/gradle/wrapper').createSync(recursive: true);
        fileSystem.file('.android/gradlew').createSync(recursive: true);
        fileSystem.file('.android/gradle.properties').writeAsStringSync('irrelevant');
        fileSystem.file('.android/build.gradle').createSync(recursive: true);
        fileSystem.directory('build/outputs/repo').createSync(recursive: true);

        await builder.buildGradleAar(
          androidBuildInfo: const AndroidBuildInfo(
            BuildInfo(
              BuildMode.release,
              null,
              treeShakeIcons: false,
              packageConfigPath: '.dart_tool/package_config.json',
            ),
          ),
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          outputDirectory: fileSystem.directory('build/'),
          target: '',
          buildNumber: '2.0',
        );

        expect(
          fileSystem.link(
            'build/outputs/repo/io/flutter/flutter_embedding_release/'
            '1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b/'
            'flutter_embedding_release-1.0.0-73fd6b049a80bcea2db1f26c7cee434907cd188b.pom',
          ),
          exists,
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{AndroidStudio: () => FakeAndroidStudio()},
    );
  });
}

class FakeGradleUtils extends Fake implements GradleUtils {
  @override
  String getExecutable(FlutterProject project) {
    return 'gradlew';
  }
}

class FakeAndroidStudio extends Fake implements AndroidStudio {
  @override
  String get javaPath => '/android-studio/jbr';
}
