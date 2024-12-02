# frozen_string_literal: true

require 'simplecov'
require 'simplecov-lcov'

SimpleCov::Formatter::LcovFormatter.config do |config|
  config.report_with_single_file = true
  config.output_directory = 'coverage'
  config.lcov_file_name = 'lcov.info'
end

SimpleCov.configure do
  enable_coverage :line
  enable_coverage :branch
  primary_coverage :line

  # NOTE: temporary percents which are based on non-refactored tests
  minimum_coverage line: 93, branch: 69 # TODO: { line: 100, branch: 100 }

  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::LcovFormatter
  ])
  add_filter '/spec/'
end
