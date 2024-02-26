# frozen_string_literal: true

require_relative 'lib/redis_queued_locks/version'

Gem::Specification.new do |spec|
  spec.required_ruby_version = '>= 3.1'

  spec.name    = 'redis_queued_locks'
  spec.version = RedisQueuedLocks::VERSION
  spec.authors = ['Rustam Ibragimov']
  spec.email   = ['iamdaiver@gmail.com']

  spec.summary     = 'Queued distributed locks based on Redis.'
  spec.description = 'Distributed locks with "lock acquisition queue" ' \
                     'capabilities based on the Redis Database.'
  spec.homepage    = 'https://github.com/0exp/redis_queued_locks'
  spec.license     = 'MIT'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/blob/master"
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end

  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'redis-client', '~> 0.20'
  spec.add_dependency 'qonfig', '~> 0.28'
end
