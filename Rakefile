# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop'
require 'rubocop/rake_task'
require 'rubocop-performance'
require 'rubocop-rspec'
require 'rubocop-rake'
require 'rubocop-on-rbs'
require 'rubocop-thread_safety'

RuboCop::RakeTask.new(:rubocop) do |t|
  config_path = File.expand_path(File.join('.rubocop.yml'), __dir__)
  t.options = [
    '--config', config_path,
    '--plugin', 'rubocop-rspec',
    '--plugin', 'rubocop-performance',
    '--plugin', 'rubocop-rake',
    '--plugin', 'rubocop-on-rbs',
    '--plugin', 'rubocop-thread_safety'
  ]
end

RSpec::Core::RakeTask.new(:rspec)

task default: :rspec
