#!/usr/bin/env ruby
# frozen_string_literal: true

# 生成 PDFReader.xcodeproj。
#
# 为什么用脚本生成而不是手工维护 pbxproj：
#   pbxproj 是 Xcode 的私有格式，手工编辑极易出错；用脚本生成则可以随时重跑，
#   新增/删除源文件后只要重新执行本脚本即可，不需要在 Xcode 里手动拖文件。
#
# 用法：
#   source ~/.rvm/scripts/rvm && rvm use 3.0.0
#   ruby tools/generate_xcodeproj.rb
#
# 依赖：xcodeproj gem（CocoaPods 自带，rvm ruby-3.0.0 下已装 1.27.0）

require 'xcodeproj'
require 'fileutils'

PROJECT_NAME        = 'PDFReader'
BUNDLE_ID           = 'com.jiejie.pdfreader'   # TODO: 发布前改成你自己的域名反写
DEPLOYMENT_TARGET   = '14.0'
SWIFT_VERSION       = '5.0'
SOURCE_DIR          = 'Sources/PDFReaderApp'

# 脚本位于 <项目根>/tools/ 下，所以项目根是上一级目录
ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, "#{PROJECT_NAME}.xcodeproj")

# 每次全量重新生成，避免残留已删除文件的引用
FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2700'
project.root_object.attributes['LastSwiftUpdateCheck'] = '2700'

target = project.new_target(:application, PROJECT_NAME, :osx, DEPLOYMENT_TARGET)

# ---------------------------------------------------------------- 源文件
# 复刻目录结构建 group，group 的 path 相对父 group
app_group  = project.main_group.new_group('PDFReaderApp', SOURCE_DIR)
sub_groups = {
  app_group => Dir.glob(File.join(ROOT, SOURCE_DIR, '*.swift')),
  app_group.new_group('Models', 'Models') => Dir.glob(File.join(ROOT, SOURCE_DIR, 'Models', '*.swift')),
  app_group.new_group('Views', 'Views')   => Dir.glob(File.join(ROOT, SOURCE_DIR, 'Views', '*.swift')),
  app_group.new_group('Utils', 'Utils')   => Dir.glob(File.join(ROOT, SOURCE_DIR, 'Utils', '*.swift'))
}

file_count = 0
sub_groups.each do |group, files|
  files.sort.each do |path|
    ref = group.new_file(File.basename(path))
    target.add_file_references([ref])
    file_count += 1
  end
end

# ---------------------------------------------------------------- 系统框架
# Swift 的自动链接通常够用，显式声明更稳妥，也方便日后排查
%w[PDFKit Vision AVFoundation AppKit].each do |framework|
  ref = project.frameworks_group.new_file("System/Library/Frameworks/#{framework}.framework")
  ref.source_tree = 'SDKROOT'
  target.frameworks_build_phase.add_file_reference(ref)
end

# ---------------------------------------------------------------- 构建配置
COMMON_SETTINGS = {
  'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
  # ⚠️ 产物名 = 用户看到的那个名字（v1.3.54 改成 PDF Free）。
  #
  # 为什么不能只改 Info.plist 里的两个键：Dock 的悬停提示、Spotlight 搜出来的结果，
  # 用的是 **`.app` 文件名 / 可执行文件名**（`PDFReader.app` / `Contents/MacOS/PDFReader`），
  # 不是 CFBundleName。只改 Info.plist 的话，图标换了、名字照旧 —— 实测就是这样。
  # 这里改掉之后三处一起对上：文件名 `PDF Free.app`、可执行 `PDF Free`、菜单栏 `PDF Free`。
  #
  # 注意**不动**的：bundle id 仍是 com.jiejie.pdfreader（沙盒容器路径由它决定 ——
  # 改了等于把"最近打开""阅读位置"全部丢掉），target/scheme/工程名仍是 PDFReader。
  'PRODUCT_NAME' => 'PDF Free',
  'INFOPLIST_FILE' => 'Info.plist',
  'CODE_SIGN_ENTITLEMENTS' => "#{PROJECT_NAME}.entitlements",
  'MACOSX_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'SWIFT_VERSION' => SWIFT_VERSION,
  # 本机没有开发者账号，用 ad-hoc 签名（等价于 Xcode 的 "Sign to Run Locally"）
  'CODE_SIGN_STYLE' => 'Manual',
  'CODE_SIGN_IDENTITY' => '-',
  'DEVELOPMENT_TEAM' => '',
  'PROVISIONING_PROFILE_SPECIFIER' => '',
  # 加固运行时留到准备分发时再开，本地 ad-hoc 签名下开启会带来额外的库验证麻烦
  'ENABLE_HARDENED_RUNTIME' => 'NO',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'COMBINE_HIDPI_IMAGES' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'CLANG_ENABLE_MODULES' => 'YES',
  'CLANG_ENABLE_OBJC_ARC' => 'YES'
}.freeze

target.build_configurations.each do |config|
  config.build_settings.merge!(COMMON_SETTINGS)
  config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] =
    config.name == 'Debug' ? '-Onone' : '-O'
  config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
    config.name == 'Debug' ? 'DEBUG' : ''
  config.build_settings['ONLY_ACTIVE_ARCH'] = config.name == 'Debug' ? 'YES' : 'NO'
  config.build_settings['DEBUG_INFORMATION_FORMAT'] =
    config.name == 'Debug' ? 'dwarf' : 'dwarf-with-dsym'
end

# ---------------------------------------------------------------- 资源
# app 图标（v1.3.54）。`Info.plist` 里 `CFBundleIconFile = AppIcon` 指的就是它，
# 所以**文件名必须是 AppIcon.icns**、且要真的拷进 app 包（走 resources build phase）。
# 图标本身由 `tools/make_app_icon.py` 生成（1024 画布 + 824 内容 + 185 圆角，符合 macOS 规范）。
icon = File.join(ROOT, 'Resources', 'AppIcon.icns')
if File.exist?(icon)
  resources_group = project.main_group.new_group('Resources', 'Resources')
  target.add_resources([resources_group.new_file('AppIcon.icns')])
  puts "  图标：Resources/AppIcon.icns"
else
  warn "  ⚠️ 没找到 Resources/AppIcon.icns —— 先跑 tools/make_app_icon.py"
end

project.save

# ---------------------------------------------------------------- 工作区文件
# Xcode 把 `.xcodeproj` 当 workspace 打开，靠的就是这份 `contents.xcworkspacedata`。
# xcodeproj gem **不生成它**，而脚本开头是 `rm -rf` 全量重建 —— 所以以前每重生成一次，
# 这个文件就"消失"一次（git 里表现为一次删除，v1.3.54 这次终于逮到）。
# 内容就是"指向自己"，照抄 Xcode 自己写出来的格式。
workspace_dir = File.join(PROJECT_PATH, 'project.xcworkspace')
FileUtils.mkdir_p(workspace_dir)
File.write(File.join(workspace_dir, 'contents.xcworkspacedata'), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Workspace
     version = "1.0">
     <FileRef
        location = "self:">
     </FileRef>
  </Workspace>
XML

# ---------------------------------------------------------------- 共享 Scheme
# 必须是 shared，否则 xcodebuild -scheme 找不到，别人 clone 下来也没有
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, PROJECT_NAME, true)

# 顺手把「Metal API Validation」关掉（v1.3.53）。
#
# Xcode 的 Run → Diagnostics 里那个开关**默认是开的**，而它会杀掉我们的 app：
# PDFKit 画页面线条走 CoreAnimation → Metal 时，校验层误报后直接 abort，
# 大文件（合集2.3.pdf）滚一下就整进程没了。app 自己在 `App.init()` 里也摘了
# `MTL_DEBUG_LAYER`（那一步更根本），这里再显式设 0 是双保险、也省掉校验层开销。
#
# ⚠️ 必须写在这里：上面 `save_as` 每次都重写 scheme 文件 ——
# 手工改 scheme 的改动**下次重跑本脚本就没了**（这次就踩到了）。
# xcodeproj gem 的 API 会随版本变，直接改 XML 更稳。
scheme_path = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes', "#{PROJECT_NAME}.xcscheme")
scheme_xml = File.read(scheme_path)
unless scheme_xml.include?('MTL_DEBUG_LAYER')
  scheme_xml = scheme_xml.sub(
    '   </LaunchAction>',
    <<~XML.chomp + "\n   </LaunchAction>"
          <EnvironmentVariables>
             <EnvironmentVariable
                key = "MTL_DEBUG_LAYER"
                value = "0"
                isEnabled = "YES">
             </EnvironmentVariable>
          </EnvironmentVariables>
    XML
  )
  File.write(scheme_path, scheme_xml)
end

puts "已生成 #{PROJECT_PATH}"
puts "  源文件 #{file_count} 个  target=#{PROJECT_NAME}  bundle=#{BUNDLE_ID}  macOS #{DEPLOYMENT_TARGET}+"
puts "  Scheme 已注入 MTL_DEBUG_LAYER=0（关掉 Metal API Validation）"
puts "  校验：xcodebuild -project #{PROJECT_NAME}.xcodeproj -scheme #{PROJECT_NAME} build"
