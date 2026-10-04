# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'steep/rake_task'
require 'rubocop'
require 'rubocop/rake_task'
require 'rubocop-performance'
require 'rubocop-rspec'
require 'rubocop-rake'
require 'rubocop-on-rbs'
require 'rubocop-thread_safety'

# NOTE: Ruby sources and RBS signatures are linted by separate runs with separate configs:
#   Ruby cops (and the project index they use) must not see RBS signatures;
desc 'Run RuboCop for Ruby sources'
RuboCop::RakeTask.new('rubocop:ruby') do |t|
  # NOTE: replace the default "Running RuboCop..." message (printed when verbose);
  t.verbose = false
  puts 'Running RuboCop (Ruby sources)...'
  config_path = File.expand_path(File.join('.rubocop.yml'), __dir__)
  t.options = [
    '--config', config_path,
    '--plugin', 'rubocop-rspec',
    '--plugin', 'rubocop-performance',
    '--plugin', 'rubocop-rake',
    '--plugin', 'rubocop-thread_safety'
  ]
end

desc 'Run RuboCop for RBS signatures and inline RBS annotations'
RuboCop::RakeTask.new('rubocop:rbs') do |t|
  # NOTE: replace the default "Running RuboCop..." message (printed when verbose);
  t.verbose = false
  puts 'Running RuboCop (RBS signatures and inline RBS annotations)...'
  config_path = File.expand_path(File.join('.rubocop.rbs.yml'), __dir__)
  t.options = [
    '--config', config_path,
    '--plugin', 'rubocop-on-rbs'
  ]
end

desc 'Run RuboCop for Ruby sources and RBS signatures'
task :rubocop do
  # NOTE: run both linters even if the first one fails (a failed RuboCop task aborts);
  failed = %w[rubocop:ruby rubocop:rbs].reject do |task_name|
    Rake::Task[task_name].invoke
    true
  rescue SystemExit
    false
  end
  abort("RuboCop failed: #{failed.join(', ')}") if failed.any?
end

RSpec::Core::RakeTask.new(:rspec)
Steep::RakeTask.new(:steep)

task default: :rspec
