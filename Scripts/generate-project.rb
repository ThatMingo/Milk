#!/usr/bin/env ruby
require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Milk.xcodeproj'))
project.build_configurations.each { |c| c.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '26.0'; c.build_settings['ARCHS'] = 'arm64' }
config = project.main_group.new_group('Configuration')
debug = config.new_file('Configuration/Debug.xcconfig')
release = config.new_file('Configuration/Release.xcconfig')
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
project.root_object.package_references << package
def link_package(project, target, package, name)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package; dependency.product_name = name
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end
app = project.new_target(:application, 'Milk', :osx, '26.0')
host = project.new_target(:xpc_service, 'MilkExtensionHost', :osx, '26.0')
[[app, 'MilkKit', 'App/MilkApp.swift', 'Configuration/Milk-Info.plist', 'dev.thatmingo.Milk'],
 [host, 'MilkCore', 'Sources/MilkExtensionHost/main.swift', 'Configuration/ExtensionHost-Info.plist', 'dev.thatmingo.Milk.ExtensionHost']].each do |target, product, source, info, identifier|
  target.source_build_phase.add_file_reference(project.main_group.new_file(source))
  link_package(project, target, package, product)
  target.build_configurations.each do |c|
    c.base_configuration_reference = c.name == 'Release' ? release : debug
    c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = identifier
    c.build_settings['INFOPLIST_FILE'] = info
    c.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks'
    c.build_settings['SKIP_INSTALL'] = target == host ? 'YES' : 'NO'
  end
end
host.build_configurations.each { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Configuration/ExtensionHost.entitlements'; c.build_settings['ENABLE_APP_SANDBOX'] = 'YES' }
app.add_dependency(host)
copy = app.new_copy_files_build_phase('Embed Extension Host')
copy.dst_subfolder_spec = '16'
copy.dst_path = '$(CONTENTS_FOLDER_PATH)/XPCServices'
copy.add_file_reference(host.product_reference).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
resources = project.main_group.new_file('Resources/Extensions')
resources.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(resources)
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app); scheme.set_launch_target(app)
scheme.save_as(project.path, 'Milk', true)
project.save
puts project.path
