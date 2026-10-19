require 'xcodeproj'
root = File.dirname(__FILE__)
project = Xcodeproj::Project.new(File.join(root, 'OnboardingFixture.xcodeproj'))
app = project.new_target(:application, 'OnboardingFixture', :ios, '18.0')
tests = project.new_target(:ui_test_bundle, 'FixtureUITests', :ios, '18.0')
app.add_file_references([project.main_group.new_file('FixtureApp.swift')])
tests.add_file_references([project.main_group.new_file('FixtureUITests.swift')])
tests.add_file_references([project.main_group.new_file('../../Sources/RunnerCore/Domain.swift')])
tests.add_file_references(['CompanionServiceTests.swift', '../../Sources/RunnerCore/RunnerProtocols.swift', '../../Sources/RunnerCore/CompanionProtocol.swift', '../../Sources/RunnerCore/SecureInputCrypto.swift'].map { |path| project.main_group.new_file(path) })
tests.add_dependency(app)
[app, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({'SWIFT_VERSION'=>'5.0', 'GENERATE_INFOPLIST_FILE'=>'YES',
      'CODE_SIGNING_ALLOWED'=>'NO', 'PRODUCT_BUNDLE_IDENTIFIER'=>"dev.agentic.#{target.name}",
      'TARGETED_DEVICE_FAMILY'=>'1,2'})
    config.build_settings['TEST_TARGET_NAME'] = app.name if target == tests
    config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES' if target == app
  end
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project.path, app.name, true)

companion = Xcodeproj::XCScheme.new
companion.add_build_target(app)
companion.add_test_target(tests)
companion.set_launch_target(app)
companion.test_action.should_use_launch_scheme_args_env = false
companion.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { :key => 'COMPANION_SERVICE_ENABLED', :value => '1' },
  { :key => 'COMPANION_TARGET_BUNDLE_ID', :value => 'dev.agentic.OnboardingFixture' }
])
companion.save_as(project.path, 'CompanionService', true)
