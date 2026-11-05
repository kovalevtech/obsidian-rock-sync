require 'bundler'
Bundler.require

require_relative 'config'

require "zeitwerk"
$loader = Zeitwerk::Loader.new
$loader.push_dir(File.join(__dir__, "lib"))
$loader.push_dir(File.join(__dir__, "services"))
$loader.inflector.inflect('db' => 'DB')
$loader.enable_reloading if Config.zeitwerk_reload?
$loader.setup
