# frozen_string_literal: true

require 'simplecov'

SimpleCov.configure do
  enable_coverage :line
  enable_coverage :branch
  primary_coverage :line
  # TODO: minimum_coverage 100 # (temporary disabled for non-refactored tests)

  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter
  ])

  skip '/spec/'
end
