Pod::Spec.new do |s|
  s.name             = 'health_workout_sync'
  s.version          = '0.1.1'
  s.summary          = 'Sync workouts from Apple Health into your app, in the background, without loss or duplicates.'
  s.description      = <<-DESC
Imports workouts from Apple Health via anchored queries, with HKObserverQuery background delivery into a headless Flutter engine.
                       DESC
  s.homepage         = 'https://github.com/usaman9040/health_workout_sync'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Level Up Fitness' => 'support@levelup-fitness.com' }
  s.source           = { :path => '.' }
  s.source_files = 'health_workout_sync/Sources/health_workout_sync/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'
  s.frameworks = 'HealthKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'health_workout_sync_privacy' => ['health_workout_sync/Sources/health_workout_sync/PrivacyInfo.xcprivacy']}
end
